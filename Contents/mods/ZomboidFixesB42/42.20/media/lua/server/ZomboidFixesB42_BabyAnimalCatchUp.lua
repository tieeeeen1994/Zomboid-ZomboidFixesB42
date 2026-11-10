--[[
    Zomboid Fixes B42.20 -- server and single player, baby animals are caught up once

    Coming back to an animal pen, the game makes up the hours it was out of range.
    DesignationZone.update (IsoWorld.update, every 2.5 s of real time, for every
    zone) runs checkStreamed then check() per zone; checkStreamed marks a zone away
    (streamed = false, hourLastSeen = world age hours) as soon as either corner
    square (x, y / x + w - 1, y + h - 1) is unloaded, and the first run that finds
    both loaded again calls doMeta((int) worldAgeHours - hourLastSeen). In 42.22
    DesignationZoneAnimal keeps its animals in a HashSet instead of an ArrayList, and
    doMeta's baby loop was converted from an indexed loop by wrapping a for-each in
    the old counting loop:

        Set<IsoAnimal> isoAnimals = this.getAnimalsInZone();   // after check()
        for (IsoAnimal animal : isoAnimals)
           if (!animal.isBaby()) animal.updateStatsAway(hours);
        for (int i = 0; i < isoAnimals.size(); i++)
           for (IsoAnimal animalx : isoAnimals)
              if (animalx.isBaby()) animalx.updateStatsAway(hours);

    So every baby is made up once per animal in the zone. updateStatsAway(hours)
    (IsoAnimal ~1701) adds hours / 24 days of age and runs hourGrow(true) per hour:
    hunger, thirst, health, weight, eating and drinking from the zone's food and
    troughs (eatAndDrinkAfterMeta, real items on the server), feathers, growUp at
    each midnight (a baby can turn adult), the meta predator roll. In a pen of 20,
    each chick, calf, lamb or piglet lives the time away 20 times over. 42.21 ran it
    once in doMeta (plus once more at load in AnimalManagerMain, which 42.22 dropped
    for fromMeta, below).

    Nothing of that can be undone afterwards, so the babies must be kept out of the
    vanilla pass and made up once by this file. doMeta works on the set check()
    builds from IsoGridSquare.getAnimals(list) over the zone's squares, which skips
    animals with isOnHook(). IsoAnimal.setOnHook(boolean) is a plain public flag, and
    for the few frames it is set nothing else is changed by it: IsoAnimal.update
    takes the hook branch (reattachBackToHook does nothing without saved hook
    coordinates, ensureCorrectSkin nothing without modData skinned, so it only skips
    the animal's own update for that frame), save writes the hook only when
    getHook() is set (a hooked flag with no hook saves as not hooked), no packet
    carries it (only ObjectModDataPacket reads it, for animals with a real hook), and
    the rest only skip the animal (CombatManager targets, vocals, the debug map).

    The window. Every update the server runs ServerMap.preupdate (chunks are put in
    the world there), then IngameState.updateInternal: OnTickEvenPaused, then
    IsoWorld.update (the cell, CollisionManager.ResolveContacts, where animals coming
    out of the animal worker are put in the world, then DesignationZone.update),
    then OnTick. So babies are flagged in OnTickEvenPaused and the flag is taken off
    again in OnTick: any doMeta of that update ran without them.

    Which babies may be flagged. A baby that vanilla already made up must not be made
    up again here. check() calls setDZone(this) on every animal of the zone's squares,
    so doMeta (check() first) leaves each animal it touched with getDZone() set, and
    the only other writer, IsoAnimal.checkZone, runs from the animal's own update,
    which does nothing at all while the animal waits for its catch-up: an animal the
    worker puts back into an animal zone gets fromMeta = true (AnimalManagerMain
    ~97), IsoAnimal.updateInternal returns at once while it is set, and only
    updateStatsAway clears it. So a baby with no zone has not been through any
    check() since it came back, and is safe. Babies that never left (a big pen whose
    far corner went out of range) have a zone from before; they are safe only when
    no check() of the zone has run since it came back. On a dedicated server that
    is known: chunks come in preupdate, so a zone seen fully loaded in
    OnTickEvenPaused and not at the end of the update before came back before any
    IsoWorld.update. In single player chunks load after OnTickEvenPaused
    (IsoChunkMap.ProcessChunkPos, the cell's own chunk map update), inside the same
    update that may run the check. So while a zone is away, a few of its animals
    that stayed on its squares carry a probe: the zone is appended to their
    getConnectedDZone() list (the live ArrayList), which check() clears and refills
    for every animal on the zone's squares. If the zone came back during the update,
    a probe still there with its animal still on the zone means no check() ran, and
    the babies that stayed are safe; a refilled list means it did (or the animal's
    own checkZone did, every ~2000 multiplier units, which only costs the
    protection), and they are left to vanilla. A probe still there is taken out
    again; the extra entry is the zone it already lists, for one update.

    When vanilla ran. The flagged babies are also given the zone with setDZone, which
    puts them in the zone's set; check() empties the set with setDZone(null) on
    every member before refilling it from the squares (without the flagged babies),
    so a flagged baby with no zone in OnTick means check() ran in that update. The
    first check() of a zone that is back is the one doMeta starts with (checkStreamed
    runs just before check() for each zone), so the flagged babies are then made up
    once, with forceWanderNow after, as doMeta does. A check() that ran without a
    doMeta (vanilla had already done it, or never saw the zone leave) still finds
    only babies vanilla did not make up, which is the same answer.

    How long. The zone's hourLastSeen has no getter, so the hours are counted here by
    the same rule, sampled every update instead of every 2.5 s: the hour the zone was
    first seen not fully loaded. Vanilla's own sample is up to 2.5 s later, so the
    count is one hour long only when an hour turned in those seconds. Vanilla starts
    every zone as streamed and overwrites hourLastSeen when it first sees one away
    (the saved value is never used), as this file does at the start of a session. A
    zone first seen away after the option was off this session is left to vanilla,
    because its hour is unknown.

    Not covered: a baby put in the world in the very update that runs the zone's
    first check() (it arrives inside IsoWorld.update, after OnTickEvenPaused) is
    made up by vanilla, so the game's multiplied run stands for it; with a check
    every 2.5 s that is roughly one return in 25 on a server for babies in the last
    chunks to load. In single player the same goes for babies that stayed loaded
    when the check runs in the very update the far corner loads, or when no animal
    that stayed was left on the zone to carry a probe. Clients run doMeta on their
    own copies too; their babies'
    stats come from the server (AnimalPacket), and the items their copies eat or drop
    are Animal Pens Resync's business, so this runs on the server and in single
    player only.
--]]

if isClient() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.BabyAnimalCatchUp == true
end

-- A zone back in range with no baby to flag is let go after this long. Vanilla's
-- check runs every 2.5 s, so by then it has made up the zone; babies coming back
-- after that get no catch-up from vanilla at all, and nothing from here either.
local PENDING_WITHOUT_BABIES_MS = 5000

-- Never hold babies longer than this. Vanilla's check comes within 2.5 s of a zone
-- being back; if it has not shown up by then something is off, and a flagged baby
-- that never left skips its own update while it is flagged.
local PENDING_GIVE_UP_MS = 15000

-- zone ID -> { state = "streamed" | "away" | "unknown", lastSeen, endFull, pending }
-- pending = { zone, clean, eligible = { [animalID] = true }, ineligible, started, flaggedAny }
local zones = {}

-- What this file flagged in the current update: { animal, rec }.
local flagged = {}

-- Probes planted in the current update: { animal, list, size, zone, rec }.
local probes = {}
local MAX_PROBES_PER_ZONE = 3

-- The option was off at some point this session, so zones already away when it
-- came on have an hourLastSeen this file never saw.
local everDisabled = false

local function hourNow()
    return math.floor(getGameTime():getWorldAgeHours())
end

local function describeZone(zone)
    return zone:getX() .. "," .. zone:getY() .. "," .. zone:getZ()
        .. " (" .. zone:getW() .. "x" .. zone:getH() .. ")"
end

--- Take every flag off, and make up the babies of each zone whose check ran.
local function unflag()
    if #flagged == 0 then return end

    local ran = {}
    for i = 1, #flagged do
        local entry = flagged[i]
        entry.animal:setOnHook(false)
        if entry.animal:getDZone() == nil then ran[entry.rec] = true end
    end

    local done = {}
    for i = 1, #flagged do
        local entry = flagged[i]
        local rec = entry.rec
        if ran[rec] then
            local animal = entry.animal
            local stats = done[rec]
            if not stats then
                stats = { count = 0, hours = math.max(0, hourNow() - rec.lastSeen) }
                done[rec] = stats
            end
            if stats.hours > 0 and animal:isExistInTheWorld() and not animal:isDead() then
                animal:updateStatsAway(stats.hours)
                animal:forceWanderNow()
                stats.count = stats.count + 1
            end
        end
    end
    flagged = {}

    for rec, stats in pairs(done) do
        local zone = rec.pending and rec.pending.zone
        if zone and stats.count > 0 then
            print("[ZomboidFixesB42] BabyAnimalCatchUp: made up " .. stats.count .. " baby animal(s) once for "
                .. stats.hours .. " hour(s) away in the animal zone at " .. describeZone(zone))
        end
        rec.pending = nil
        rec.state = "streamed"
    end
end

local function onZone(zone, animal)
    local square = animal:isExistInTheWorld() and animal:getSquare()
    if not square then return false end
    local x, y = square:getX(), square:getY()
    return square:getZ() == zone:getZ() and x >= zone:getX() and x < zone:getX() + zone:getW()
        and y >= zone:getY() and y < zone:getY() + zone:getH()
end

--- While a zone is away, mark a few animals that stayed on it (see the header).
-- The zone's own set is not rebuilt while it is away, so it still lists them.
local function plantProbes(rec, zone)
    local members = ArrayList.new()
    members:addAll(zone:getAnimalsInZone())
    local planted = 0
    for i = 0, members:size() - 1 do
        local animal = members:get(i)
        if not animal:isOnHook() and not animal:isDead() and onZone(zone, animal) then
            local list = animal:getConnectedDZone()
            local size = list:size()
            list:add(zone)
            table.insert(probes, { animal = animal, list = list, size = size, zone = zone, rec = rec })
            planted = planted + 1
            if planted >= MAX_PROBES_PER_ZONE then return end
        end
    end
end

--- Take the probes back out and note, for each zone that came back in this update,
-- whether a check() of it ran.
local function collectProbes()
    if #probes == 0 then return end
    local verdict = {}
    for i = 1, #probes do
        local probe = probes[i]
        if probe.list:size() ~= probe.size + 1 then
            verdict[probe.rec] = "checked"
        else
            probe.list:remove(probe.zone)
            if verdict[probe.rec] == nil and onZone(probe.zone, probe.animal) then
                verdict[probe.rec] = "unchecked"
            end
        end
    end
    probes = {}
    for rec, result in pairs(verdict) do
        if rec.state == "away" and rec.zone:isFullyStreamed() then
            rec.cameBackUnchecked = result == "unchecked"
        end
    end
end

local function zoneAt(pendingList, x, y, z)
    for i = 1, #pendingList do
        local rec = pendingList[i]
        local zone = rec.pending.zone
        if z == zone:getZ() and x >= zone:getX() and x < zone:getX() + zone:getW()
                and y >= zone:getY() and y < zone:getY() + zone:getH() then
            return rec
        end
    end
    return nil
end

--- Flag the babies of the zones that are back but not made up yet.
local function flagBabies(pendingList)
    local cell = getCell()
    if not cell then return end
    -- IsoCell.getAnimals builds a LinkedList of every animal in the cell; copied into
    -- an ArrayList (as vanilla does) so each get(i) is not a walk down the list.
    local animals = ArrayList.new()
    animals:addAll(cell:getAnimals())

    for i = 0, animals:size() - 1 do
        local animal = animals:get(i)
        local square = animal:getSquare()
        if square and animal:isBaby() and not animal:isOnHook() and not animal:isDead() then
            local rec = zoneAt(pendingList, square:getX(), square:getY(), square:getZ())
            if rec then
                local pending = rec.pending
                local id = animal:getAnimalID()
                if not pending.eligible[id] and not pending.ineligible[id] then
                    -- Seen before any update since the zone came back, or with no zone
                    -- yet: no check() has counted it (see the header).
                    if (pending.clean and not pending.scanned) or animal:getDZone() == nil then
                        pending.eligible[id] = true
                    else
                        pending.ineligible[id] = true
                    end
                end
                if pending.eligible[id] then
                    animal:setOnHook(true)
                    animal:setDZone(pending.zone)
                    pending.flaggedAny = true
                    table.insert(flagged, { animal = animal, rec = rec })
                end
            end
        end
    end

    for i = 1, #pendingList do
        pendingList[i].pending.scanned = true
    end
end

local function onTickEvenPaused()
    -- OnTick did not come (an error in the update, or the game paused): never leave
    -- a baby flagged or a probe planted.
    unflag()
    collectProbes()

    if not isEnabled() then
        everDisabled = true
        return
    end
    if isGamePaused() then return end

    local list = DesignationZoneAnimal.getAllZones()
    if not list then return end

    local now = getTimestampMs()
    local seen = {}
    local pendingList = {}

    for i = 0, list:size() - 1 do
        local zone = list:get(i)
        local key = zone and zone:getId()
        if key then
            seen[key] = true
            local full = zone:isFullyStreamed()
            local rec = zones[key]
            if not rec then
                rec = {}
                zones[key] = rec
                if full then
                    rec.state = "streamed"
                elseif everDisabled then
                    rec.state = "unknown"
                else
                    rec.state = "away"
                    rec.lastSeen = hourNow()
                end
            end
            rec.zone = zone

            if not full then
                rec.pending = nil
                if rec.state == "streamed" then
                    rec.state = "away"
                    rec.lastSeen = hourNow()
                end
                rec.cameBackUnchecked = nil
                -- Single player loads chunks inside the update (see the header); a
                -- server never does, so it needs no probes.
                if rec.state == "away" and not isServer() then plantProbes(rec, zone) end
            elseif rec.state == "unknown" then
                rec.state = "streamed"
            elseif rec.state == "away" then
                if not rec.pending then
                    rec.pending = {
                        zone = zone,
                        -- Not fully loaded at the end of the last update, so it came
                        -- back in the server's preupdate, before any check could run;
                        -- or it came back during that update and the probes say no
                        -- check ran.
                        clean = rec.endFull == false or rec.cameBackUnchecked == true,
                        eligible = {},
                        ineligible = {},
                        started = now,
                    }
                end
                rec.pending.zone = zone
                local age = now - rec.pending.started
                if age > PENDING_GIVE_UP_MS or (not rec.pending.flaggedAny and age > PENDING_WITHOUT_BABIES_MS) then
                    if rec.pending.flaggedAny then
                        print("[ZomboidFixesB42] BabyAnimalCatchUp: no zone check seen in "
                            .. PENDING_GIVE_UP_MS .. " ms for the animal zone at " .. describeZone(zone)
                            .. "; its babies are left to the game")
                    end
                    rec.pending = nil
                    rec.state = "streamed"
                else
                    table.insert(pendingList, rec)
                end
            end
        end
    end

    for key in pairs(zones) do
        if not seen[key] then zones[key] = nil end
    end

    if #pendingList > 0 then flagBabies(pendingList) end
end

local function onTick()
    unflag()
    collectProbes()
    if not isEnabled() then return end

    -- Where each away zone stood at the end of this update, for the next one's
    -- "came back before any check" test.
    for _, rec in pairs(zones) do
        if rec.state == "away" and rec.zone then
            rec.endFull = rec.zone:isFullyStreamed()
        else
            rec.endFull = nil
        end
    end
end

Events.OnTickEvenPaused.Add(onTickEvenPaused)
Events.OnTick.Add(onTick)
