--[[
    Zomboid Fixes B42.20 -- server, actions driven by animation events keep pace
    with fast forward

    Many timed actions do their work on animation events rather than at their end:
    milking (a litre per "update"), shearing, reading (a page per "ReadAPage"),
    exercising, resting, drinking, filling and emptying water and fuel, lighting a
    fire, chopping a tree, loading and unloading bullets. On a server there is no
    animation, so the action's serverStart asks for the events to be emulated:

        emulateAnimEvent(self.netAction, periodMs, "update", nil)

    and zombie.network.server.AnimEventEmulator calls netAction.animEvent(event,
    parameter) every periodMs of real time (GameTime.getServerTimeMills), with no game
    speed anywhere. So at 40x a cow is milked a litre per 0.8 s as at 1x, and a book
    read at fast forward -- whose length ISBaseTimedAction:adjustMaxTime already
    shortens -- ends with pages unread.

    The emulator is not exposed to Lua and keeps each event's period fixed, but
    NetTimedAction.animEvent is public. So while fast forward runs, every repeating
    event also fires (speed - 1) more times per period from here, through the same
    call, and its own Java timer is left alone. The extra firings stop the moment the
    action ends:

      * completed: ActionManager.update calls NetTimedAction.perform -> the table's
        complete; stopped (cancelled, walked away, logged out): ActionManager.stop ->
        serverStop. Both are looked up with rawget on the action's own table, so
        each action gets its own wrappers that mark it ended;
      * about to complete: forceComplete sets endTime to now, which getProgress()
        reports as 1 until the next update runs complete.

    Which action an event belongs to comes from NetTimedAction.start: setTimeData
    calls the action's getDuration and then adjustMaxTime (wrapped in
    ZomboidFixesB42_FastForward.lua, which remembers the table), and serverStart,
    which asks for the events, runs straight after.

    emulateAnimEventOnce (a single event after a delay) is left as it is: its Java
    copy cannot be cancelled, so firing it early would fire it twice.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- Most extra events fired for one action in one tick (a 100 ms event at 40x needs 39).
local MAX_PER_TICK = 60
-- AnimEventEmulator.getDurationMax: the emulator forgets events after 30 minutes.
local MAX_AGE_MS = 1800000

local events = {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MultiplayerFastForward == true
end

--- Mark the action ended when the server completes or stops it.
local function hookEnd(action)
    if action.zfixEndHooked then return end
    action.zfixEndHooked = true
    local complete = action.complete
    local serverStop = action.serverStop
    action.complete = function(self, ...)
        self.zfixEnded = true
        if complete then return complete(self, ...) end
        return true
    end
    action.serverStop = function(self, ...)
        self.zfixEnded = true
        if serverStop then return serverStop(self, ...) end
    end
end

local vanillaEmulate = emulateAnimEvent

function emulateAnimEvent(netAction, duration, event, parameter)
    vanillaEmulate(netAction, duration, event, parameter)
    if not isEnabled() or not netAction then return end
    local action = ZomboidFixesB42.fastForwardLastAdjusted
    local period = tonumber(duration)
    if not action or action.netAction ~= netAction or not period or period <= 0 then return end
    hookEnd(action)
    local now = getTimestampMs()
    table.insert(events, {
        net = netAction, action = action, period = period, event = event, parameter = parameter,
        owed = 0, startMs = now, lastMs = now,
    })
end

local function onTick()
    if #events == 0 then return end
    local now = getTimestampMs()
    local speed = ZomboidFixesB42.fastForwardSpeed or 1
    for i = #events, 1, -1 do
        local e = events[i]
        if e.action.zfixEnded or now - e.startMs > MAX_AGE_MS then
            table.remove(events, i)
        else
            if speed > 1 then
                e.owed = e.owed + (now - e.lastMs) * (speed - 1) / e.period
            end
            e.lastMs = now
            local fired = 0
            while e.owed >= 1 and fired < MAX_PER_TICK and not e.action.zfixEnded and e.net:getProgress() < 1 do
                e.owed = e.owed - 1
                fired = fired + 1
                e.net:animEvent(e.event, e.parameter)
            end
        end
    end
end

Events.OnTick.Add(onTick)
