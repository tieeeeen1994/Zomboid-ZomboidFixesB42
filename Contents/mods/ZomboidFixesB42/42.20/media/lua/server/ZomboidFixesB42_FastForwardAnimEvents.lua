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
    Their packets, SyncHandWeaponFieldsPacket and SyncItemFieldsPacket, carry a
    snapshot of the whole item and are RakNet RELIABLE (reliability 2), not ordered:
    each one arrives, but not necessarily in the order sent, and the client keeps
    whichever lands last. At normal speed they leave half a second apart and land in
    order; at fast forward several leave in a tick, and an older one can land last --
    a revolver loaded to 6 on the server shows 4, a magazine shows rounds missing.
    The client never works the count out itself: vanilla's and Gunworks' loading code
    both run only on the server (if not isClient()), and the client's copy of the
    action only plays the animation. So it keeps the stale number until the item is
    sent again, and the server only sends an item when it changes.

    A stale client copy is not just a wrong display. Both packets are handlingType 3,
    and processServer takes the client's whole copy -- ammo count and, for
    SyncItemFields, all of its modData, which it wipes and replaces. The client sends
    one from vanilla's ISAttachItemHotbar and ISDetachItemHotbar perform() (a
    magazine clipped to a vest slot or taken off, a gun holstered),
    ISRackFirearm:start (ejectSpentRounds), ISReloadWeaponAction.onShoot, and
    CombatManager when a shot costs the gun condition (item:syncItemFields); and from
    Gunworks' reload animation code in the client's perform() and stop()
    (ReloadAnim.resetWeaponModel -> setWeaponAttachmentState -> syncHandWeaponFields),
    which decides the gun's look from the client's own isContainsClip(). Whatever the
    client holds then becomes the server's truth. (Moving an item does not send it:
    ItemTransactionPacket carries only item IDs.)

    The Gunworks gang framework (SWMG, which Guns of Marz requires) also floods the
    connection. Its InsertBullet, RemoveBullet and bullet-by-bullet reload hooks
    follow every round with

        sendServerCommand(character, "SWMG", "syncAmmoList",
            { itemId = item:getID(), ammoList = item:getModData().AmmoList })

    the item's whole per-round list, which its client handler stores as it arrives.
    A 150 round drum sends 150 of them, the last ones 150 entries long: at fast
    forward several hundred KB in a couple of seconds, enough to hold packets back
    well past half a second.

    So no older snapshot of an item is left in flight after a fast forwarded action.
    While the speed is above 1, every sync and item state command
    (ITEM_STATE_COMMANDS) asked for by an event of a tracked action -- whether this
    file or Java fired it; hookCurrent notes whose event is running -- is held, the
    last one per item and command winning. They go out as soon as the action reaches
    its end -- its last event sets the progress to 1, before the server completes it
    and sends the client its Done, which is when the client's perform() writes back
    -- and from its complete and serverStop in any case; when fast forward ends; and
    every FLUSH_EVERY_MS while a long action runs, so its progress still shows.
    Loading a magazine at fast forward is then one snapshot at the end instead of one
    per round.

    Each item sent that way is synced again RESYNC_DELAYS_MS later, so the last word
    is the server's even if something from before arrives late. The field packets
    carry the modData, so the list is resent with the count. A resync is only sent
    while nothing else has changed the item: every send of it (the next action's
    flush when it is reloaded again straight away, an event at normal speed) starts
    the delays again, so the resync waits until the item has settled, and a change
    that arrived from the client (a shot, the hotbar) ends them, since resending the
    older view would then fight the client. A shot whose sync is on its way when a
    resync leaves can be undone by it, one round, as by any sync the server sends;
    that window is one round trip at each delay.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- Most extra events fired for one action in one tick (a 100 ms event at 40x needs 39).
local MAX_PER_TICK = 60
-- AnimEventEmulator.getDurationMax: the emulator forgets events after 30 minutes.
local MAX_AGE_MS = 1800000

-- After a burst of events an item is synced again at each of these delays, counted
-- from the last time the server sent it.
local RESYNC_DELAYS_MS = { 500, 2000 }

-- While fast forward runs, what a long action holds still goes out this often, so
-- its progress shows.
local FLUSH_EVERY_MS = 1000

-- Server commands that carry one item's whole state, so a burst only needs its last:
-- module -> command -> true. The item must be named by args.itemId.
local ITEM_STATE_COMMANDS = {
    -- Gunworks gang framework (Guns of Marz): the item's whole per-round AmmoList.
    SWMG = { syncAmmoList = true },
}

-- Every event kept pace with, shortest period or delay first.
local events = {}

-- The tracked action whose event is running right now, whether Java or this file
-- fired it (hookCurrent), or nil.
local current = nil
-- action -> { items = item -> { sends, character }, commands, sinceMs }: what the
-- action's events asked to send while fast forward ran, not sent yet. sends is the
-- set of sync functions asked for (a gun can take both). commands is
-- { byKey = player -> key -> entry, order = { entry } }, entry = { player, module,
-- command, args }, the latest args winning. And how many actions hold something.
local pending = {}
local pendingCount = 0
-- item -> { sends, character, fromMs, step, state }: the resyncs still to come, and
-- how many items have them.
local resyncs = {}
local resyncCount = 0

--- What a resync checks is still the same: the fields reloading changes.
local function snapshot(item)
    local state = tostring(item:getCurrentAmmoCount())
    if instanceof(item, "HandWeapon") then
        if item:isRoundChambered() then state = state .. "+1" end
        if item:isContainsClip() then state = state .. "c" end
    end
    return state
end

--- Whether what is asked for now is held: inside an event of a tracked action,
-- while fast forward runs.
local function holding()
    return current ~= nil and (ZomboidFixesB42.fastForwardSpeed or 1) > 1
end

local function pendingFor(action)
    local p = pending[action]
    if not p then
        p = { items = {}, commands = { byKey = {}, order = {} }, sinceMs = getTimestampMs() }
        pending[action] = p
        pendingCount = pendingCount + 1
    end
    return p
end

--- Hold an item sync a tracked action's event asks for at fast forward; send it
-- straight away otherwise.
local function holdable(send)
    if not send then return nil end
    return function(character, item, ...)
        if item and holding() then
            local items = pendingFor(current).items
            local sync = items[item]
            if not sync then
                sync = { sends = {} }
                items[item] = sync
            end
            sync.sends[send] = true
            sync.character = character
            return
        end
        -- Sent at once by the server (an event at normal speed, anything else): the
        -- item moved on here, so its resyncs follow the new state and start over.
        local resync = item and resyncs[item]
        if resync then
            resync.state = snapshot(item)
            resync.fromMs = getTimestampMs()
            resync.step = 1
        end
        return send(character, item, ...)
    end
end

local vanillaSyncHandWeaponFields = syncHandWeaponFields
local vanillaSyncItemFields = syncItemFields
syncHandWeaponFields = holdable(vanillaSyncHandWeaponFields)
syncItemFields = holdable(vanillaSyncItemFields)

--- Hold an item state command a tracked action's event sends at fast forward.
-- Anything else, and the broadcast form (no player), goes straight through with
-- its arguments untouched.
local vanillaSendServerCommand = sendServerCommand
sendServerCommand = function(...)
    if holding() and select("#", ...) == 4 then
        local player, module, command, args = ...
        local commands = type(module) == "string" and ITEM_STATE_COMMANDS[module] or nil
        if player and commands and commands[command] and type(args) == "table" and args.itemId ~= nil then
            local held = pendingFor(current).commands
            local key = module .. "|" .. command .. "|" .. tostring(args.itemId)
            local byKey = held.byKey[player]
            if not byKey then
                byKey = {}
                held.byKey[player] = byKey
            end
            local entry = byKey[key]
            if entry then
                entry.args = args
            else
                entry = { player = player, module = module, command = command, args = args }
                byKey[key] = entry
                table.insert(held.order, entry)
            end
            return
        end
    end
    return vanillaSendServerCommand(...)
end

--- Send an item's syncs, each once, unless it has since left every container (the
-- packets address it by container) or its owner has left.
local function sendSync(item, sync)
    if not item:getContainer() or not sync.character:isExistInTheWorld() then return end
    for send in pairs(sync.sends) do
        pcall(send, sync.character, item)
    end
end

--- Send what an action held, once per item and command, and line up the resyncs.
local function flushAction(action)
    local p = pending[action]
    if not p then return end
    pending[action] = nil
    pendingCount = pendingCount - 1
    local now = getTimestampMs()
    for item, sync in pairs(p.items) do
        sendSync(item, sync)
        if not resyncs[item] then resyncCount = resyncCount + 1 end
        resyncs[item] = {
            sends = sync.sends, character = sync.character,
            fromMs = now, step = 1, state = snapshot(item),
        }
    end
    for _, entry in ipairs(p.commands.order) do
        pcall(vanillaSendServerCommand, entry.player, entry.module, entry.command, entry.args)
    end
end

--- Send what each action is done holding: fast forward has ended, the action has
-- reached its end (its last event, before the server completes it and sends the
-- client its Done), it has no events left, or it has held for FLUSH_EVERY_MS.
local function flushDue(now)
    if pendingCount == 0 then return end
    local slow = (ZomboidFixesB42.fastForwardSpeed or 1) <= 1
    local live = {}
    for _, e in ipairs(events) do live[e.action] = true end
    local due = {}
    for action, p in pairs(pending) do
        local net = action.netAction
        local finished = action.zfixEnded or not live[action] or (net ~= nil and net:getProgress() >= 1)
        if slow or finished or now - p.sinceMs >= FLUSH_EVERY_MS then
            table.insert(due, action)
        end
    end
    for _, action in ipairs(due) do flushAction(action) end
end

local function sendDueResyncs(now)
    local due = {}
    for item, sync in pairs(resyncs) do
        if now >= sync.fromMs + RESYNC_DELAYS_MS[sync.step] then table.insert(due, item) end
    end
    for _, item in ipairs(due) do
        local sync = resyncs[item]
        -- Changed without passing through here: the client sent its own copy (a
        -- shot, the hotbar), so it already has what the server has now; or an action
        -- is holding its changes to the item, and its flush starts the resyncs again.
        local unchanged = snapshot(item) == sync.state
        if unchanged then sendSync(item, sync) end
        sync.step = sync.step + 1
        if not unchanged or RESYNC_DELAYS_MS[sync.step] == nil then
            resyncs[item] = nil
            resyncCount = resyncCount - 1
        end
    end
end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MultiplayerFastForward == true
end

--- Mark the action ended when the server completes or stops it, and send what it
-- still holds before the server tells the client it is done.
local function hookEnd(action)
    if action.zfixEndHooked then return end
    action.zfixEndHooked = true
    local complete = action.complete
    local serverStop = action.serverStop
    action.complete = function(self, ...)
        self.zfixEnded = true
        local result = true
        if complete then result = complete(self, ...) end
        flushAction(self)
        return result
    end
    action.serverStop = function(self, ...)
        self.zfixEnded = true
        local result = nil
        if serverStop then result = serverStop(self, ...) end
        flushAction(self)
        return result
    end
end

--- Note whose event is running while it runs, so what it sends can be held, whether
-- Java or this file fired it: NetTimedAction.animEvent looks animEvent up on the
-- action's own table.
local function hookCurrent(action)
    if action.zfixCurrentHooked then return end
    local animEvent = action.animEvent
    if not animEvent then return end
    action.zfixCurrentHooked = true
    action.animEvent = function(self, ...)
        local previous = current
        current = self
        local ok, err = pcall(animEvent, self, ...)
        current = previous
        if not ok then error(err, 0) end
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
    hookCurrent(action)
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
    hookCurrent(action)
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
    if #events == 0 and pendingCount == 0 and resyncCount == 0 then return end
    local now = getTimestampMs()
    local ok, err = true, nil
    if #events > 0 then
        ok, err = pcall(fireAll, now, ZomboidFixesB42.fastForwardSpeed or 1)
        for i = #events, 1, -1 do
            if events[i].over then table.remove(events, i) end
        end
    end
    -- Whatever happened above, what is due goes out.
    flushDue(now)
    if resyncCount > 0 then sendDueResyncs(now) end
    if not ok then error(err) end
end

Events.OnTick.Add(onTick)
