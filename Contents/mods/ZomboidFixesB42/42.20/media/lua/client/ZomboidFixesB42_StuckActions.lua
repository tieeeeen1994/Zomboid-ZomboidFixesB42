--[[
    Zomboid Fixes B42.20 -- client, timed actions stuck at 100%

    In multiplayer every timed action whose class has a complete() runs on the
    server (LuaTimedActionNew: useCustomRemoteTimedActionSync is false). Its start
    sends a NetTimedAction Request and sets waitForFinished, so the client's copy can
    only end when the server answers: Done -> forceComplete, Reject -> forceStop
    (LuaTimedActionNew.update). BaseAction.finished() needs !waitForFinished, and
    hasStalled() needs a negative time, so a request the server never answers leaves
    the bar at 100%, the animation looping and, because ISTimedActionQueue runs one
    action at a time, every queued action behind it waiting until the game is
    restarted. Forum 94615 and 100905 (with a full analysis).

    How a request goes unanswered (42.21):

      * NetTimedAction.parse rebuilds the action's arguments with
        PZNetKahluaTableImpl.load, and some loaders throw instead of returning nil:
        loadComponent (a crafting station's CraftBench, by entity net ID) and
        loadResource call getComponent on a null GameEntity, a vehicle window part on
        a vehicle that is gone. The exception escapes parse, GameServer's packet loop
        swallows it, and neither Accept nor Reject is sent. This is the forge, kiln
        and furnace case (NullPointerException at PZNetKahluaTableImpl.loadComponent
        in the server log); server/ZomboidFixesB42_EntityNetIDs.lua removes its most
        likely cause.
      * The client's ActionManager forgets a request after 30 minutes
        (AnimEventEmulator.getDurationMax), and isDone / isRejected both start with
        !actions.isEmpty(), so once its list is empty neither ever turns true.

    (42.20's other two causes are gone in 42.21: a Lua error in the action's new is
    caught, and the Reject reply carries the right state.)

    None of that is reachable from Lua, so this file watches each local player's
    current action instead. One that waits on the server and has sat at 100% for the
    sandbox time (StuckActionTimeout, seconds) plus as long again as it took to get
    there is stopped with forceStop, the same path as a server Reject: the client
    tells the server it cancelled, the queue is cleared, and the player can act
    again. The extra "as long again" leaves room for actions the server legitimately
    times longer than the client (ISWashClothing adjusts its time twice there) and
    for a lagging server, since stopping an action the server was about to finish
    would throw away its work.

    Not covered: an action whose client time is -1 (no end of its own, reloading for
    example) shows an endless bar rather than 100%, and cannot be told apart from one
    the server is running.
--]]

if not isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function timeoutMs()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    local seconds = vars and tonumber(vars.StuckActionTimeout) or 0
    if seconds <= 0 then return nil end
    return seconds * 1000
end

-- [player number] = { action = Lua action table, startMs, fullMs }
local watched = {}

--- True for an action whose end only the server can bring (LuaTimedActionNew ~78).
local function waitsOnServer(action)
    return action ~= nil and action.action ~= nil and action.complete ~= nil
end

local function check(player, limit, now)
    local num = player:getPlayerNum()
    local queue = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player]
    local current = queue and queue.queue and queue.queue[1]
    if not waitsOnServer(current) then
        watched[num] = nil
        return
    end

    local entry = watched[num]
    if not entry or entry.action ~= current then
        entry = { action = current, startMs = now }
        watched[num] = entry
    end

    local javaAction = current.action
    -- Still walking up or turning (waitToStart): the request is not sent yet.
    if not javaAction:isStarted() then
        entry.startMs = now
        entry.fullMs = nil
        return
    end

    if javaAction:getTime() <= 0 or javaAction:getJobDelta() < 1 then
        entry.fullMs = nil
        return
    end

    entry.fullMs = entry.fullMs or now
    local took = entry.fullMs - entry.startMs
    if now - entry.fullMs < limit + took then return end

    watched[num] = nil
    print("[ZomboidFixesB42] " .. tostring(current.Type) .. " of " .. tostring(player:getUsername())
        .. " waited " .. string.format("%d", math.floor((now - entry.fullMs) / 1000))
        .. " s at 100% for the server, stopped so the queue can go on")
    HaloTextHelper.addBadText(player, getText("IGUI_ZomboidFixesB42_ActionStuck"))
    current:forceStop()
end

local function onTick()
    local limit = timeoutMs()
    if not limit then return end
    local now = getTimestampMs()
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and player:isLocalPlayer() and not player:isDead() then
            check(player, limit, now)
        end
    end
end

Events.OnTick.Add(onTick)
