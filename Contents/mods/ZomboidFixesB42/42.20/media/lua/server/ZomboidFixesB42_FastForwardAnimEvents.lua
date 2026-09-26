--[[
    Zomboid Fixes B42.20 -- server, actions driven by animation events keep pace
    with fast forward

    Many timed actions do their work on animation events rather than at their end:
    milking (a litre per "update"), shearing, reading (a page per "ReadAPage"),
    exercising, resting, drinking, filling and emptying water and fuel, lighting a
    fire, chopping a tree, reloading. On a server there is no animation, so the
    action's serverStart asks for the events to be emulated, repeating or once:

        emulateAnimEvent(self.netAction, periodMs, "update", nil)
        emulateAnimEventOnce(self.netAction, delayMs, "loadFinished", nil)

    and zombie.network.server.AnimEventEmulator calls netAction.animEvent(event,
    parameter) every periodMs (or once, after delayMs) of real time
    (GameTime.getServerTimeMills), with no game speed anywhere. So at 40x a cow is
    milked a litre per 0.8 s as at 1x, and a book read at fast forward -- whose
    length ISBaseTimedAction:adjustMaxTime already shortens -- ends with pages
    unread.

    Reloading is all events. Every reloading action's getDuration() is -1 (no end of
    its own), so adjustMaxTime cannot shorten it: it ends only when its events say
    so. Loading rounds one at a time (ISReloadWeaponAction, ISLoadBulletsInMagazine
    and the two unload actions) repeats an event per round; swapping a magazine and
    racking (ISEjectMagazine, ISInsertMagazine, ISRackFirearm) wait for once events
    of 1.2 s, 1.5 s and 0.6-1.2 s. All are divided by the ReloadSpeed variable
    (ISReloadWeaponAction.getReloadTime), never by the game speed.

    The emulator is not exposed to Lua and keeps each event's timing fixed, but
    NetTimedAction.animEvent is public, so the events are fired from here as well,
    and their Java timers are left alone:

      * a repeating event also fires (speed - 1) more times per period;
      * a once event fires as soon as its delay has passed on the game clock (real
        time times the speed). Its Java copy cannot be cancelled and still fires
        at the real delay, so the action gets its own animEvent wrapper, which
        swallows that second firing -- or, when Java's copy comes first (fast
        forward started late), keeps this one from firing.

    Events due in the same tick fire shortest period or delay first, as they would
    at normal speed: a rack's rackBullet (100 ms) chambers a round before its
    rackingFinished (1200 ms) ends the action, and a magazine's InsertBullet
    (500 ms) comes before the loadFinished (550 ms) that checks it is full.

    The extra firings stop the moment the action ends:

      * completed: ActionManager.update calls NetTimedAction.perform -> the table's
        complete; stopped (cancelled, walked away, logged out): ActionManager.stop ->
        serverStop. Both are looked up with rawget on the action's own table, so
        each action gets its own wrappers that mark it ended. Either way
        ActionManager also drops the action's Java events (AnimEventEmulator.remove);
      * about to complete: forceComplete sets endTime to now, which getProgress()
        reports as 1 until the next update runs complete.

    Which action an event belongs to comes from NetTimedAction.start: setTimeData
    calls the action's getDuration and then adjustMaxTime (also for -1; wrapped in
    ZomboidFixesB42_FastForward.lua, which remembers the table), and serverStart,
    which asks for the events, runs straight after. Events asked for while the
    action ends (ISFitnessAction's FitnessFinished, from complete and serverStop)
    are left to Java.

    Each event that changes an item tells its owner with syncHandWeaponFields or
    syncItemFields (a loaded round: the gun's or the magazine's whole ammo count).
    Their packets, SyncHandWeaponFieldsPacket and SyncItemFieldsPacket, are RakNet
    RELIABLE (reliability 2), not ordered: at normal speed they leave half a second
    apart and land in order, but several sent in one tick can land in any order, and
    the client keeps whichever came last -- a revolver loaded to 6 on the server
    shows 4. Worse, the client sends its copy back: firing
    (ISReloadWeaponAction.onShoot) calls syncHandWeaponFields on the client, whose
    SyncHandWeaponFieldsPacket.processServer writes that stale count over the
    server's, so the rounds are really gone. So while this file fires events, their
    syncs are held and each item is synced once afterwards, and once more
    RESYNC_MS later, after anything still in flight (Java's own copy of an event,
    in the same tick) has landed.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- Most extra events fired for one action in one tick (a 100 ms event at 40x needs 39).
local MAX_PER_TICK = 60
-- AnimEventEmulator.getDurationMax: the emulator forgets events after 30 minutes.
local MAX_AGE_MS = 1800000

-- The last sync of an item goes out again this long after a burst of events.
local RESYNC_MS = 500

-- Every event kept pace with, shortest period or delay first.
local events = {}

-- While this file fires events: item -> { send, character }, the syncs held back.
local held = nil
-- item -> { send, character, dueMs }: the second sync, and how many are waiting.
local resyncs = {}
local resyncCount = 0

--- Hold an item sync while this file fires events; send it straight away otherwise.
local function holdable(send)
    if not send then return nil end
    return function(character, item, ...)
        if held and item then
            held[item] = { send = send, character = character }
            return
        end
        return send(character, item, ...)
    end
end

local vanillaSyncHandWeaponFields = syncHandWeaponFields
local vanillaSyncItemFields = syncItemFields
syncHandWeaponFields = holdable(vanillaSyncHandWeaponFields)
syncItemFields = holdable(vanillaSyncItemFields)

--- Send one sync, unless the item has since left every container (the packets
-- address it by container) or its owner has left.
local function sendSync(item, sync)
    if not item:getContainer() or not sync.character:isExistInTheWorld() then return end
    pcall(sync.send, sync.character, item)
end

--- Send what was held, once per item, and have it sent again RESYNC_MS later.
local function flushHeld(now)
    local list = held
    held = nil
    if not list then return end
    for item, sync in pairs(list) do
        sendSync(item, sync)
        if not resyncs[item] then resyncCount = resyncCount + 1 end
        resyncs[item] = { send = sync.send, character = sync.character, dueMs = now + RESYNC_MS }
    end
end

local function sendDueResyncs(now)
    local due = {}
    for item, sync in pairs(resyncs) do
        if now >= sync.dueMs then table.insert(due, item) end
    end
    for _, item in ipairs(due) do
        local sync = resyncs[item]
        resyncs[item] = nil
        resyncCount = resyncCount - 1
        sendSync(item, sync)
    end
end

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

--- Each once event fires only once: the one of the two copies (Java's, this file's)
-- that comes second is dropped here.
local function hookOnce(action)
    if action.zfixOnce then return end
    action.zfixOnce = {}
    local animEvent = action.animEvent
    action.animEvent = function(self, event, parameter, ...)
        if not self.zfixFiring then
            -- From Java: its own copy of a once event, or any other event.
            for _, e in ipairs(self.zfixOnce) do
                if not e.javaFired and e.event == event and e.parameter == parameter then
                    e.javaFired = true
                    if e.fired then return end
                    e.fired = true
                    break
                end
            end
        end
        if animEvent then return animEvent(self, event, parameter, ...) end
    end
end

--- The action an event asked for right now belongs to, or nil to leave it to Java.
local function ownerOf(netAction)
    if not isEnabled() or not netAction then return nil end
    local action = ZomboidFixesB42.fastForwardLastAdjusted
    if not action or action.netAction ~= netAction or action.zfixEnded then return nil end
    return action
end

--- Keep events sorted by period or delay; equal ones stay in the order asked.
local function add(e)
    local at = #events + 1
    for i, other in ipairs(events) do
        if other.order > e.order then
            at = i
            break
        end
    end
    table.insert(events, at, e)
end

local vanillaEmulate = emulateAnimEvent

function emulateAnimEvent(netAction, duration, event, parameter)
    vanillaEmulate(netAction, duration, event, parameter)
    local action = ownerOf(netAction)
    local period = tonumber(duration)
    if not action or not period or period <= 0 then return end
    hookEnd(action)
    local now = getTimestampMs()
    add({
        net = netAction, action = action, event = event, parameter = parameter,
        order = period, period = period, owed = 0, startMs = now, lastMs = now,
    })
end

local vanillaEmulateOnce = emulateAnimEventOnce

function emulateAnimEventOnce(netAction, duration, event, parameter)
    vanillaEmulateOnce(netAction, duration, event, parameter)
    local action = ownerOf(netAction)
    local delay = tonumber(duration)
    if not action or not delay or delay < 0 then return end
    hookEnd(action)
    hookOnce(action)
    local now = getTimestampMs()
    local e = {
        net = netAction, action = action, event = event, parameter = parameter,
        order = delay, once = true, delay = delay, doneMs = 0, startMs = now, lastMs = now,
    }
    table.insert(action.zfixOnce, e)
    add(e)
end

--- A repeating event: (speed - 1) extra firings per period.
local function fireRepeating(e, now, speed)
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

--- A once event: fired when its delay has passed on the game clock. Returns true
-- once it has fired, from here or from Java.
local function fireOnce(e, now, speed)
    e.doneMs = e.doneMs + (now - e.lastMs) * math.max(speed, 1)
    e.lastMs = now
    if e.fired then return true end
    -- Only while ahead of the Java timer: at normal speed Java fires it, as vanilla.
    if e.doneMs < e.delay or e.doneMs <= now - e.startMs then return false end
    e.fired = true
    e.action.zfixFiring = true
    e.net:animEvent(e.event, e.parameter)
    e.action.zfixFiring = false
    return true
end

local function fireAll(now, speed)
    -- A copy, since firing runs the action's Lua, which could ask for more events.
    local list = {}
    for i, e in ipairs(events) do list[i] = e end
    for _, e in ipairs(list) do
        if e.action.zfixEnded or now - e.startMs > MAX_AGE_MS or e.net:getProgress() >= 1 then
            e.over = true
        elseif e.once then
            e.over = fireOnce(e, now, speed)
        else
            fireRepeating(e, now, speed)
        end
    end
end

local function onTick()
    if #events == 0 and resyncCount == 0 then return end
    local now = getTimestampMs()
    if resyncCount > 0 then sendDueResyncs(now) end
    if #events == 0 then return end
    local speed = ZomboidFixesB42.fastForwardSpeed or 1
    held = {}
    -- Whatever happens, the held syncs go out and holding stops.
    local ok, err = pcall(fireAll, now, speed)
    flushHeld(now)
    for i = #events, 1, -1 do
        if events[i].over then table.remove(events, i) end
    end
    if not ok then error(err) end
end

Events.OnTick.Add(onTick)
