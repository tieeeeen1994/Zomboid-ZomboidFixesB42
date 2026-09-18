--[[
    Zomboid Fixes B42.20 -- server, animals lost in hutch nest boxes

    A hen inside a hutch does not lay where she stands. IsoAnimal.addEgg() sends her
    into a nest box:

        public boolean addEgg(boolean meta) {
            ...
            } else if (this.hutch != null) {
                return this.hutch.addAnimalInNestBox(this);

    and IsoHutch.addAnimalInNestBox() moves her out of the hutch's animalInside map
    while she sits there:

            nestBox.animal = animal;
            animal.hutch = this;
            animal.nestBox = i;
            ...
            this.animalInside.remove(animal.getData().getHutchPosition());
            animal.getData().setHutchPosition(-1);

    So while she is laying she holds no slot in animalInside. That matters, because
    the only thing stopping another bird walking in is BaseAnimalBehavior.canGoToHutch:

        if (hutch.getAnimalInside().size() < hutch.getMaxAnimals()) {

    A hen hutch is maxAnimals = 20 with four nest boxes, so up to four birds can be
    out laying at once, and up to four more can take the slots they vacated. Manual
    placement through ISHutchMenu uses the same size test, so a player can do it too.

    When her egg timer runs out IsoHutch.update() calls addEgg(animal), which lays
    the egg and then hands her back:

        private void removeAnimalFromNestBox(NestBox nestBox) {
            IsoAnimal animal = nestBox.animal;
            nestBox.animal.nestBox = -1;
            ...
            nestBox.animal = null;
            this.addAnimalInside(animal);      // return value ignored
        }

    addAnimalInside() looks for a free position, gives up after a hundred tries, and
    returns false when every one is taken:

            if (this.animalInside.get(animal.getData().getPreferredHutchPosition()) == null) {
                ... return true;
            } else {
                return false;
            }

    Nobody checks that false. By then nestBox.animal is already null and her
    nestBox index is already -1, so nothing in the hutch, in the world, or in any
    save file refers to her any more. The bird is gone, silently and permanently,
    and the player sees a chicken that vanished for no reason. The same ignored
    return sits in the nest box branch of IsoHutch.update(), for a hen who dies
    while laying, so her body disappears too.

    None of that is reachable from Lua -- addAnimalInside is Java, and so is every
    caller. What is reachable is the wreckage: for the instant between the nest box
    releasing her and the save file forgetting her, the IsoAnimal object is still
    alive in memory. So this file watches every nest box, and the moment a bird
    leaves one without arriving anywhere, it grabs the object and puts her back.
    Holding a reference is what makes that safe -- the animal cannot be collected
    while this table points at her, so there is no race to win.

    Where she goes, in order:

      * back into her own hutch, which is what vanilla meant to do;
      * into another hutch in the same animal zone;
      * back into a nest box, if the hutch really is full. She will lay again and
        try again, and the moment a slot frees up she lands in it. Her eggs pile up
        in the meantime, which is a fair signal to the player that the coop is over
        capacity;
      * failing all of that she is held here and retried every pass, so she at least
        survives until something frees up. This is the only outcome that a server
        restart would still lose, and it needs a hutch that is full and has every
        nest box occupied or stacked with ten eggs.

    Only birds seen sitting in a nest box are ever touched, and one is only put back
    when she is in no hutch, in no nest box, not standing in the world and not inside
    an inventory item. Every other way out of a nest box therefore passes straight
    through: there is no vanilla path that takes a bird out of a nest box and into a
    player's hands, and ISHutchNestBox:onButtonGrab refuses outright ("don't wanna
    grab animal that is in his nest box").

    Runs on the server in multiplayer and on the game itself in single player, which
    is where hutch state is authoritative. addAnimalInside and addAnimalInNestBox
    both send their own animal update and hutch sync, so clients follow along.

    On a tick rather than a timer, because the loss is tied to the frame loop and not
    to anyone watching. Three things say it cannot happen while the area is unloaded:

      * every line of IsoHutch.update() sits inside
        `if (!this.isSlave() && this.isExistInTheWorld())`, so a hutch with no live
        square does not tick at all;
      * the hutch's own offscreen catch-up, IsoHutch.doMeta(hours), only accumulates
        hutchDirt and nestBoxDirt. It never touches animalInside or a nest box;
      * the offscreen laying path, AnimalData.checkEggs(cal, true), is gated on
        `this.parent.hutch == null` and lays through addMetaEgg(), which puts an egg
        in a box without moving the bird. Its only caller is IsoAnimal.updateStatsAway,
        which is never reached by a hutched animal: all three call sites
        (AnimalManagerMain.fromWorker, DesignationZoneAnimal.doMeta and IsoAnimal
        itself) work from animals that live on squares, and BaseAnimalBehavior.enterHutch
        takes a bird off its square on the way in.

    Loaded is not the same as watched, though. HutchManager.updateAll() runs every
    frame from IsoWorld.updateInternal(), for every hutch whose square is loaded --
    on a server, any coop in streaming range of any player. So the hens lay, and the
    bird is lost, while the owner is across the farm, indoors, or logged out with
    someone else online. Events.OnTick is the same clock, so this sees it happen.

    One gap worth knowing about: hutches are found through
    DesignationZoneAnimal.getAllZones(), because HutchManager is not on the Lua
    exposer's list and there is no other way to enumerate them. A hutch outside every
    animal zone is therefore not watched -- but it also gets no automatic traffic,
    since AnimalData.getRegionHutch() only ever picks from a zone's hutch list. Only
    a bird put into such a hutch by hand can reach a nest box in one, and lose.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- How often, in ticks, the nest boxes are sampled. A hen sits in a box for
-- eggTimerInHutch = Rand.Next(350, 600), counted down by the game speed multiplier
-- once per hutch update, so a few seconds of real time at normal speed. Sampling
-- several times a second leaves plenty of room to catch her there first.
local PASS_TICKS = 20

-- Birds held over for a later pass, per hutch. Only reached when a hutch is full
-- and all its nest boxes are too, so anything approaching this number means
-- something else has gone wrong and it is not worth growing the table for.
local MAX_HELD = 64

-- IsoHutch.NestBox.maxEggs. The field is a static on an inner class, so mirror the
-- constant rather than reaching for it.
local MAX_EGGS_PER_NEST_BOX = 10

-- hutch key -> { hutch, siblings, nest = { [animalID] = animal }, held, heldCount, logged }
local watched = {}

local tickCounter = 0

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars and vars.RescueHutchAnimals == true
end

--- A stable name for a hutch. Only the master object of a multi-tile hutch is ever
-- seen here, because DesignationZoneAnimal skips slaves when it builds its list.
local function hutchKey(hutch)
    return math.floor(hutch:getX()) .. "," .. math.floor(hutch:getY()) .. "," .. math.floor(hutch:getZ())
end

local function isInsideHutch(hutch, animal)
    local inside = hutch:getAnimalInside()
    return inside ~= nil and inside:containsValue(animal)
end

local function isInNestBox(hutch, animal)
    for i = 0, hutch:getMaxNestBox() do
        if hutch:getAnimalInNestBox(i) == animal then return true end
    end
    return false
end

--- Is something still holding on to this bird?
-- Deliberately generous. Anything that can still be pointed at is left alone, and
-- only an animal that nothing at all refers to is treated as lost.
local function isAccountedFor(entry, animal)
    -- Carried as an inventory item. AnimalInventoryItem.setAnimal stamps the item's
    -- ID onto the animal, and both hutch entry points clear it again, so this is an
    -- exact test rather than a guess.
    if animal:getItemID() ~= 0 then return true end

    -- Standing on a square: IsoAnimal.isExistInTheWorld checks the square's moving
    -- objects, so this is true only once she is really back in play.
    if animal:isExistInTheWorld() then return true end

    -- A trailer or a butcher hook. Neither is reachable from a nest box in vanilla
    -- -- both start from a bird you are already holding, which the item check above
    -- catches -- but they are two calls, and being wrong here would mean two copies
    -- of the same animal.
    if animal:getVehicle() ~= nil then return true end
    if animal:isOnHook() then return true end

    -- In a hutch. Her own hutch field survives the failed hand-back, so check what
    -- it points at as well as the hutch we were watching.
    local hutch = animal:getHutch()
    if hutch and (isInsideHutch(hutch, animal) or isInNestBox(hutch, animal)) then return true end

    return isInsideHutch(entry.hutch, animal)
end

--- Is there a nest box standing empty, with room for one more egg?
-- IsoHutch.addAnimalInNestBox walks nestBoxes.get(i).animal for every index without
-- a null check, so a hutch missing one of its boxes would throw. Vanilla creates
-- them all up front and only ever reads them the same way, but this is called from
-- a state vanilla does not reach, so look first.
local function hasFreeNestBox(hutch)
    local free = false
    for i = 0, hutch:getMaxNestBox() do
        local nestBox = hutch:getNestBox(i)
        if not nestBox then return false end
        if hutch:getAnimalInNestBox(i) == nil and nestBox:getEggsNb() < MAX_EGGS_PER_NEST_BOX then
            free = true
        end
    end
    return free
end

--- Put a bird back somewhere real. Returns a word for the log, or nil.
local function rehome(entry, animal)
    if entry.hutch:addAnimalInside(animal) then return "its own hutch" end

    -- The sibling list is whatever the zone held when this hutch was last seen in
    -- it, and a zone rebuilds that list from loaded squares only. So check each one
    -- is still really there: putting a bird into a hutch that has left the world
    -- would drop her again at the next save.
    local siblings = entry.siblings
    if siblings then
        for i = 1, #siblings do
            local sibling = siblings[i]
            if sibling ~= entry.hutch and sibling:isExistInTheWorld() and sibling:addAnimalInside(animal) then
                return "a hutch nearby"
            end
        end
    end

    -- The hutch is full. A nest box still beats nothing: she stays in the hutch, she
    -- keeps laying, and each lay is another attempt at a slot. Not for a dead bird,
    -- who would only sit there blocking a box no live hen could then use.
    if not animal:isDead() and hasFreeNestBox(entry.hutch) and entry.hutch:addAnimalInNestBox(animal) then
        return "a nest box, because the hutch is full"
    end

    return nil
end

--- Name a bird for the log, the same way ISAnimalUI titles its window.
local function describe(animal)
    local name = animal:getCustomName()
    if not name or name == "" then name = animal:getFullName() end
    if not name or name == "" then name = animal:getAnimalType() end
    return tostring(name) .. " (" .. tostring(animal:getAnimalID()) .. ")"
end

local function hold(entry, key, id, animal)
    if entry.held[id] then return end

    if entry.heldCount >= MAX_HELD then
        if not entry.loggedFull then
            entry.loggedFull = true
            print("ZomboidFixesB42.HutchNestBox already holding " .. MAX_HELD
                .. " animals for the hutch at " .. key .. "; not taking any more")
        end
        return
    end

    entry.held[id] = animal
    entry.heldCount = entry.heldCount + 1
end

local function release(entry, id)
    if not entry.held[id] then return end
    entry.held[id] = nil
    entry.heldCount = entry.heldCount - 1
    entry.logged[id] = nil
    entry.loggedFull = nil
end

local function checkHutch(key, hutch, siblings)
    local entry = watched[key]

    -- A rebuilt or reloaded hutch is a different object with its own saved state, so
    -- start again rather than judging it by what the old one held.
    if not entry or entry.hutch ~= hutch then
        entry = { hutch = hutch, nest = {}, held = {}, heldCount = 0, logged = {} }
        watched[key] = entry
    end
    entry.siblings = siblings

    -- Who is sitting in a nest box right now.
    local current = {}
    for i = 0, hutch:getMaxNestBox() do
        local animal = hutch:getAnimalInNestBox(i)
        if animal then current[animal:getAnimalID()] = animal end
    end

    -- Anyone who was in one last pass and has not turned up anywhere since.
    for id, animal in pairs(entry.nest) do
        if not current[id] and not isAccountedFor(entry, animal) then
            hold(entry, key, id, animal)
        end
    end
    entry.nest = current

    for id, animal in pairs(entry.held) do
        if current[id] or isAccountedFor(entry, animal) then
            -- Something else claimed her while we were holding on. Let go.
            release(entry, id)
        else
            local where = rehome(entry, animal)
            if where then
                print("ZomboidFixesB42.HutchNestBox recovered " .. describe(animal)
                    .. " lost leaving a nest box at " .. key .. ", put back in " .. where)
                release(entry, id)
            elseif not entry.logged[id] then
                entry.logged[id] = true
                print("ZomboidFixesB42.HutchNestBox holding " .. describe(animal)
                    .. " lost leaving a nest box at " .. key
                    .. "; the hutch and every nest box are full, so she cannot be put back yet")
            end
        end
    end
end

local function pass()
    local zones = DesignationZoneAnimal.getAllZones()
    if not zones then return end

    local seen = {}

    for z = 0, zones:size() - 1 do
        local zone = zones:get(z)
        local hutches = zone and zone:getHutchs()
        if hutches and hutches:size() > 0 then
            -- Built once per zone and shared by every hutch in it, so a bird with
            -- nowhere to go at home can be offered the coop next door.
            local siblings = {}
            for h = 0, hutches:size() - 1 do
                local hutch = hutches:get(h)
                if hutch then table.insert(siblings, hutch) end
            end

            for i = 1, #siblings do
                local key = hutchKey(siblings[i])
                if not seen[key] then
                    seen[key] = true
                    checkHutch(key, siblings[i], siblings)
                end
            end
        end
    end

    -- A zone rebuilds its hutch list from loaded squares, so a hutch drops out of it
    -- whenever its chunk is away. That is not a reason to forget a bird we are
    -- holding: keep checking the object itself until it really leaves the world.
    local stale = nil
    for key, entry in pairs(watched) do
        if not seen[key] then
            stale = stale or {}
            table.insert(stale, key)
        end
    end
    if not stale then return end

    for i = 1, #stale do
        local key = stale[i]
        local entry = watched[key]
        if entry.hutch:isExistInTheWorld() then
            checkHutch(key, entry.hutch, entry.siblings)
        else
            watched[key] = nil
        end
    end
end

local function onTick()
    if not isEnabled() then return end

    tickCounter = tickCounter + 1
    if tickCounter < PASS_TICKS then return end
    tickCounter = 0

    pass()
end

Events.OnTick.Add(onTick)
