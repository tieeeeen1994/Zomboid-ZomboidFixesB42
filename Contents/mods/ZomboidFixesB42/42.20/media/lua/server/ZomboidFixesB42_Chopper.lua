--[[
    Zomboid Fixes B42.20 -- server, admin chopper controls

    The debug menu's Game panel has Add Chopper and Remove Chopper buttons. They
    call the Lua globals testHelicopter() and endHelicopter(), which on a client
    only send the server's own chat commands, /chopper start and /chopper stop
    (LuaManager.GlobalObject). The server then runs IsoWorld.helicopter
    .pickRandomTarget() or .deactivate() (ChopperCommand, which needs the
    MakeEventsAlarmGunshot capability). On the server the same two globals call
    those methods directly.

    The chopper only exists on the server (zombie.iso.Helicopter). While it is up,
    every server update moves it and sends its position to every connection in a
    Helicopter packet with active = true, and deactivate() sends one last packet
    with active = false. A client only plays the sound where the packets say
    (Helicopter.clientSync), and turns the chopper on or off as each packet says.

    That packet is RakNet RELIABLE, which is not ordered (HelicopterPacket,
    reliability = 2). A position packet that is lost and sent again can arrive after
    the final "gone" packet. The client then turns the chopper back on and hears it
    hovering until they relog, because nothing else is ever sent. Stopping it again
    does not help: deactivate() only sends anything while the server's own chopper
    is still up. This hits the natural chopper event too, whenever it leaves.

    The natural chopper event comes straight back after a stop, too. On the event
    day (GameTime.helicopterDay1 == nightsSurvived), for as long as the time of day
    is between helicopterTime1Start and helicopterTime1End (1 to 4 game hours),
    GameTime.update launches it again (pickRandomTarget) with a 1 in
    800 / multiplier chance per update whenever it is not up. On a server running at
    10 updates a second that is about 80 seconds, and a minute later it is overhead
    again. Vanilla meant to push the start of the window back by half an hour each
    time, but does it as (int)(start + 0.5F), which never changes an int. The same
    relaunch also brings the chopper back each time it leaves on its own during the
    window.

    So stopping here does more than /chopper stop:
      - endHelicopter() stops the chopper if it is up, as vanilla does;
      - if today's event is running, it is ended: the end hour is set to the start
        hour (GameTime.setHelicopterEndHour, saved with the world), so the window
        is empty for the rest of the day. With the sandbox's Helicopter set to
        "Sometimes" or "Often", GameTime schedules the next event day by itself
        once this day is over;
      - testHelicopter() then endHelicopter() puts it up and takes it down again
        within the same update. That sends a fresh "gone" packet to every client
        even when the server's chopper was already down. No position packet goes
        out in between, because only update() sends those;
      - that is repeated a few times over the next seconds, after any late position
        packet still in flight has arrived.

    Starting is vanilla's pickRandomTarget: the chopper picks a random online
    player, appears 1000 tiles east and 1000 south of them and flies in at about 22
    tiles a second, so it takes a minute or so to be heard. It cannot be aimed at
    anyone from Lua. The Helicopter class is not exposed, IsoWorld.helicopter is a
    field with no getter, and pickRandomTarget and deactivate are only reachable
    through these two globals.

    Only roles with MakeEventsAlarmGunshot (admin and moderator by default), the
    same as /chopper. Each use is written to the admin log, as /chopper does.
--]]

if not isServer() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- After a stop, the "gone" packet is sent again this long after it, in ms. A lost
-- packet is sent again once RakNet notices, which takes longer the worse the
-- player's connection is.
local RESEND_AFTER_MS = { 1000, 3000, 10000 }

-- When (getTimestampMs) the "gone" packet is still to be sent again.
local resends = {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ChopperControls == true
end

--- Tell every client the chopper is gone, whether or not it is up. Brings down a
-- chopper that is up, too.
local function sendGone()
    testHelicopter()
    endHelicopter()
end

--- Ends today's chopper event if it is running now, so GameTime.update does not
-- launch the chopper again. Returns true if there was one to end.
local function endTodaysEvent()
    local gameTime = getGameTime()
    if gameTime:getNightsSurvived() ~= gameTime:getHelicopterDay() then return false end

    local startHour = gameTime:getHelicopterStartHour()
    local hour = gameTime:getTimeOfDay()
    if hour <= startHour or hour >= gameTime:getHelicopterEndHour() then return false end

    gameTime:setHelicopterEndHour(startHour)
    return true
end

--- Returns true if today's chopper event was ended as well.
local function stop()
    endHelicopter()
    local endedEvent = endTodaysEvent()
    sendGone()
    local now = getTimestampMs()
    resends = {}
    for _, delay in ipairs(RESEND_AFTER_MS) do
        table.insert(resends, now + delay)
    end
    return endedEvent
end

local function start()
    -- Resends still due from an earlier stop would take this one straight down.
    resends = {}
    testHelicopter()
end

local function onTick()
    if #resends == 0 then return end

    local now = getTimestampMs()
    local still = {}
    local due = false
    for _, time in ipairs(resends) do
        if now >= time then
            due = true
        else
            table.insert(still, time)
        end
    end
    resends = still
    if due then sendGone() end
end

--- result is "sent", "stopped", "stoppedEvent", "denied" or "disabled".
local function reply(player, result)
    sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_CHOPPER_RESULT, { result = result })
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_CHOPPER then return end
    if not player or type(args) ~= "table" then return end

    if not isEnabled() then
        return reply(player, "disabled")
    end

    local role = player:getRole()
    if not role or not role:hasCapability(Capability.MakeEventsAlarmGunshot) then
        print("ZomboidFixesB42.chopper The player's access level is not sufficient to perform this action")
        return reply(player, "denied")
    end

    if args.action == "start" then
        start()
        writeLog("admin", tostring(player:getUsername()) .. " sent the chopper")
        reply(player, "sent")
    elseif args.action == "stop" then
        if stop() then
            writeLog("admin", tostring(player:getUsername()) .. " stopped the chopper and ended today's chopper event")
            reply(player, "stoppedEvent")
        else
            writeLog("admin", tostring(player:getUsername()) .. " stopped the chopper")
            reply(player, "stopped")
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(onTick)
