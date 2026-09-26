--[[
    Zomboid Fixes B42.20 -- server, fast forward in multiplayer

    Multiplayer has no speed controls. UIManager only puts zombie.ui.SpeedControls
    on screen when !GameClient.client, SpeedControlsHandler.onKeyPressed returns
    straight away on a client, and SpeedControls.getCurrentGameSpeed() always
    answers 1 in multiplayer.

    The engine can still run faster, though. The debug /setTimeSpeed command
    (SetTimeSpeedCommand) does it in two lines:

        GameTime.getInstance().setMultiplier(newSpeed);
        INetworkPacket.sendToAll(PacketType.SetMultiplier);   -- clients setMultiplier too

    and that is what this does, with a vote in front of it. Every living player
    picks one of the single player speeds; the game only runs faster when all of
    them have picked it, and then at the slowest speed anyone picked. A player
    going back to normal speed (by hand, by moving or by finishing an action) takes
    back only their own vote: the game drops to normal at once, since it needs
    every vote, and the others keep theirs, so it runs fast again as soon as that
    player votes again. Only the server's own stop -- a zombie close to anyone, or
    vanilla dropping the speed -- clears every vote.

    Deliberately not GameServer.fastForward, the flag vanilla raises when every
    player is asleep. That path is built for nobody watching: clients delete every
    zombie they can see (IsoZombie.update, GameClient.fastForward) and the packet
    anti-cheat is switched off (PacketValidator.update).

    Single player keeps its own speed controls, so none of this runs there.

    Timed actions do not follow the multiplier by themselves. In B42 multiplayer the
    server runs them (zombie.core.NetTimedAction, ActionManager): when one starts,
    Action.setTimeData fixes endTime = start + getDuration() in real server
    milliseconds, and ActionManager.update completes it once GameTime.getServerTimeMills()
    passes endTime. NetTimedAction.getDuration is the Lua action's getDuration()
    (maxTime) passed through its adjustMaxTime (server only), times 20 ms, with no
    GameTime multiplier anywhere, so reading or crafting took the same real time at
    40x. The server's Lua rawget falls back to the metatable, so the one
    ISBaseTimedAction.adjustMaxTime serves every action (no action overrides it).
    It is wrapped here to divide by the running speed, and each started action is
    remembered, so when the speed changes mid-action (the usual order: start the
    action, then fast forward) its end is moved with Action.setDuration, keeping the
    work already done. The server's Done packet ends the action on the client
    (ActionManager.setStateFromPacket), whatever its own progress bar shows.
--]]

if not isServer() then return end

require "TimedActions/ISBaseTimedAction"

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- onlineID -> chosen speed. Only speeds above 1 are kept: no entry is normal speed.
local votes = {}
-- The multiplier this file last gave GameTime.
local applied = 1
local started = false
-- What the clients were last told, so they are only told again when it changes.
local lastSignature = nil

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MultiplayerFastForward == true
end

local function livingPlayers()
    local result = {}
    local online = getOnlinePlayers()
    if not online then return result end
    for i = 0, online:size() - 1 do
        local player = online:get(i)
        if player and not player:isDead() then
            table.insert(result, player)
        end
    end
    return result
end

--- Count the votes. Returns the speed the game should run at, and the state the
-- clients need to draw the speed controls.
local function tally()
    local players = livingPlayers()
    local state = { total = #players, votes = {} }
    local speed = nil
    local asleep = 0
    -- Only the living keep a vote. Online IDs are reused, so a vote left behind by
    -- someone who logged out would otherwise be handed to whoever joins next.
    local kept = {}

    for _, player in ipairs(players) do
        local id = player:getOnlineID()
        local vote = votes[id] or 1
        if vote > 1 then kept[id] = vote end
        state.votes[tostring(id)] = vote
        if not speed or vote < speed then speed = vote end
        if player:isAsleep() then asleep = asleep + 1 end
    end
    votes = kept

    -- Everyone asleep is vanilla's own fast forward, and GameTime.getMultiplier()
    -- multiplies the two together. Stand aside rather than run sleep at forty times
    -- its own speed; the votes stay for when they wake.
    if not speed or asleep == #players then speed = 1 end

    state.speed = speed
    return speed, state
end

local function signatureOf(state)
    local parts = { state.speed, state.total }
    for id, vote in pairs(state.votes) do
        table.insert(parts, id .. "=" .. vote)
    end
    table.sort(parts, function(a, b) return tostring(a) < tostring(b) end)
    return table.concat(parts, ",")
end

local function broadcast(state)
    lastSignature = signatureOf(state)
    sendServerCommand(ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FAST_FORWARD_STATE, state)
end

-- Timed actions ----------------------------------------------------------------

-- NetTimedAction.getDuration: a Lua duration unit is 20 ms of real time.
local MS_PER_UNIT = 20
-- Lua action table -> { startMs, lastMs, doneMs, totalMs, speed }: doneMs is how much
-- of the action's normal-speed length (totalMs) is done, counted at the speed it ran.
local running = {}

--- Move every running action's end to match a new speed.
local function retimeActions(speed)
    local now = getTimestampMs()
    local over = {}
    for action, run in pairs(running) do
        run.doneMs = run.doneMs + (now - run.lastMs) * run.speed
        run.lastMs = now
        run.speed = speed
        local net = action.netAction
        if run.doneMs >= run.totalMs or not net then
            table.insert(over, action)
        else
            local lengthMs = math.floor((now - run.startMs) + (run.totalMs - run.doneMs) / speed)
            -- An action that has already ended may refuse; it is forgotten either way.
            if not pcall(function() net:setDuration(lengthMs) end) then
                table.insert(over, action)
            end
        end
    end
    for _, action in ipairs(over) do running[action] = nil end
end

--- Forget actions that must have ended by now, finished or cancelled.
local function pruneActions()
    local now = getTimestampMs()
    local over = {}
    for action, run in pairs(running) do
        local done = run.doneMs + (now - run.lastMs) * run.speed
        if done >= run.totalMs + 5000 then table.insert(over, action) end
    end
    for _, action in ipairs(over) do running[action] = nil end
end

local originalAdjustMaxTime = ISBaseTimedAction.adjustMaxTime

--- On the server this is only reached from NetTimedAction.getDuration, when an
-- action starts (the client's create() runs its own copy).
function ISBaseTimedAction:adjustMaxTime(maxTime)
    local adjusted = originalAdjustMaxTime(self, maxTime)
    -- -1 (or less) is an action without an end.
    if not isEnabled() or type(adjusted) ~= "number" or adjusted <= 0 or not self.netAction then
        return adjusted
    end
    local now = getTimestampMs()
    running[self] = { startMs = now, lastMs = now, doneMs = 0, totalMs = adjusted * MS_PER_UNIT, speed = applied }
    if applied > 1 then return adjusted / applied end
    return adjusted
end

local function apply(speed)
    getGameTime():setMultiplier(speed)
    -- Read by ZomboidFixesB42_FastForwardCooking.lua.
    ZomboidFixesB42.fastForwardSpeed = speed
    if speed ~= applied then
        applied = speed
        retimeActions(speed)
    end
end

--- Clear every vote and bring the game back to normal speed at once.
local function stopAll()
    votes = {}
    apply(1)
    local _, state = tally()
    broadcast(state)
end

-- A zombie close to anyone stops fast forward for everyone, as in single player,
-- where IsoPlayer's line of sight update drops the speed to 1 for a zombie within
-- 4 tiles (7 with a crowd in view).
local function anyZombieNear()
    for _, player in ipairs(livingPlayers()) do
        if ZomboidFixesB42.isZombieNear(player) then return true end
    end
    return false
end

local lastPrune = 0

local function onTick()
    if not isEnabled() then return end

    local now = getTimestampMs()
    if now - lastPrune > 5000 then
        lastPrune = now
        pruneActions()
    end

    if not started then
        -- GameTime saves its multiplier into the world, so a server stopped while
        -- fast forwarding would come back up still fast forwarding.
        started = true
        apply(1)
    end

    if applied > 1 then
        -- Anything in vanilla that drops the speed back to normal -- IsoPlayer's own
        -- zombie check also runs on the server -- counts as stopping it for everyone.
        if anyZombieNear() or getGameTime():getTrueMultiplier() < applied - 0.01 then
            stopAll()
            return
        end
    end

    local speed, state = tally()
    if speed ~= applied then
        apply(speed)
    end
    if signatureOf(state) ~= lastSignature then
        broadcast(state)
    end
end

local function onVote(player, args)
    if player:isDead() then return end

    local speed = tonumber(args.speed)
    if not ZomboidFixesB42.isFastForwardSpeed(speed) then return end

    if speed == 1 then
        -- Only this player's vote goes; everyone else's stay. The game still
        -- drops to normal speed, since it needs every player's vote.
        votes[player:getOnlineID()] = nil
    else
        votes[player:getOnlineID()] = speed
    end
    onTick()
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or not player then return end
    if not isEnabled() then return end

    if command == ZomboidFixesB42.CMD_FAST_FORWARD_VOTE then
        onVote(player, args or {})
    elseif command == ZomboidFixesB42.CMD_FAST_FORWARD_HELLO then
        -- A player who has just joined has no vote, which is normal speed, so the
        -- tally will already have changed; this makes sure they hear it regardless.
        local _, state = tally()
        sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FAST_FORWARD_STATE, state)
    end
end

Events.OnTick.Add(onTick)
Events.OnClientCommand.Add(onClientCommand)
