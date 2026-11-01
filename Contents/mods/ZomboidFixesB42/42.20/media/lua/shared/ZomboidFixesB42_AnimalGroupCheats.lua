--[[
    Zomboid Fixes B42.20 -- shared, animal cheats on a whole pen (admin)

    Vanilla's animal cheats (the animal's Debug submenu with the Animal Cheat power,
    ISAnimalContextMenu.lua) act on one animal at a time: one right-click, one
    submenu, often one number typed into a box, per animal. Calming a stressed herd,
    making every ewe of a flock pregnant or bringing a pen's births forward means
    doing that dozens of times. These are the same cheats for a group: every animal in
    a pen, a hutch or a radius, optionally of one type, from one admin hotbar slot.

    What each one does is what vanilla's handler does (server/ClientCommands.lua,
    Commands.animal.*), with the gaps that only show on a group filled in (42.21):

      - Stress: IsoAnimal.setDebugStress (stressLevel, 0-100).
      - Hunger / thirst: the animal's CharacterStat HUNGER / THIRST (0-1).
      - Health: setHealth (0-1). Never 0: vanilla kills with a fake attacker first
        (Commands.animal.kill), and a group "kill" is not what this is for.
      - Age: setAgeDebug(days) (clamped to the definition's minAge, then
        AnimalData.init re-reads the grow stage).
      - Breeding: vanilla's Impregnate only flips AnimalData.pregnant, and offers
        Fertilize instead for egg layers. Natural mating (IsoAnimal.fertilize) does
        the same on success: egg layers (adef.eggsPerDay > 0) get fertilized = true
        with fertilizedTime 1 (it counts up daily and ends past fertilizedTimeMax;
        every egg laid meanwhile is fertile), the others pregnant = true with
        pregnantTime 0. The father's genome is the mate's; with none set the baby
        takes the mother's (AnimalGene.initGenesFromParents), as with vanilla's
        cheat. Only adult females of a type with a babyType.
      - Days until birth: pregnantTime counts the days of pregnancy (+1 in each
        daily growUp) and AnimalData.checkPregnancy, every update, births the litter
        once it reaches getPregnantPeriod() (the definition's days x the sandbox
        pregnancy time modifier, at least 8), but only while pregnantTime > 0. So
        "N days until birth" is pregnantTime = period - N, and 0 means at the next
        update. Vanilla's Set Pregnancy Period box takes the raw day count.
      - Milk: vanilla sets maxMilkActual and the milk to the number typed, which does
        nothing for a female that is not lactating (updateMilk drains it again unless
        canHaveMilk). Here a percentage of the animal's own maximum (getMaxMilk, from
        its genes); filling also starts lactation (setCanHaveMilk, which refuses
        geriatric animals and the nomilk disorder).
      - Wool: setWoolQuantity(percentage of getMaxWool(), force).
      - Acceptance: setDebugAcceptance(admin, value), like vanilla's Full Acceptance;
        acceptance is kept per player (by online ID), so it is the admin's own.
      - Invincible: setIsInvincible, which vanilla only offers as a flip per animal.

    Every one of these reaches the clients by itself: AnimalPacket, which the server
    sends for every animal it simulates every 0.8-1 s to each connection
    (NetworkPlayerAI.set / parse), carries stress, hunger, thirst, health, age,
    pregnant + pregnantTime, fertilized + fertilizedTime, milk and wool, all of them
    to any role with AnimalCheats, and hutched animals too (location 1). Invincible
    is server-only state. So nothing is sent per animal here.

    Which animals (all on the server's copy):
      - pen: DesignationZoneAnimal.getZone(x, y, z) at the picked square, with every
        zone joined to it: getAnimalsConnected() (loose animals; a new list) and
        getHutchsConnected().
      - hutch: an IsoHutch on the picked square (a hutch is several squares, each
        with an IsoHutch object; getHutch() gives the one holding the animals).
      - radius: every IsoAnimal moving object and hutch within N tiles on that level.
    A hutch holds its animals outside the world: getAnimal(i) for the roosting
    positions 0 .. getMaxAnimals() - 1 and getAnimalInNestBox(i) for the nest boxes
    0 .. getMaxNestBox(). Dead animals and carcasses on a hook are skipped.

    Gate: Capability.AnimalCheats, as every vanilla Commands.animal.* handler; single
    player trusts the client, which offers it only with -debug (the admin hotbar).
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local Cheats = ZomboidFixesB42.AnimalGroupCheats or {}
ZomboidFixesB42.AnimalGroupCheats = Cheats

function Cheats.isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.AnimalGroupCheats == true
end

-- Which animals. A radius scope names its radius; the largest keeps a click to a few
-- thousand squares.
Cheats.SCOPES = { "pen", "hutch", "r5", "r10", "r20", "r30" }
Cheats.RADIUS = { r5 = 5, r10 = 10, r20 = 20, r30 = 30 }
Cheats.ANY_KIND = "any"

local function isScope(scope)
    for _, id in ipairs(Cheats.SCOPES) do
        if id == scope then return true end
    end
    return false
end

-- The cheats --------------------------------------------------------------------------
--
-- Each: id, then either a number range (min, max, default) or choices (list of
-- values, default), and apply(animal, value, player) -> true when it changed that
-- animal (false: the cheat does not apply to it).

local function isAdultFemale(animal)
    return animal:isFemale() and not animal:isBaby()
end

local function canBreed(animal)
    local babyType = animal:getBabyType()
    return isAdultFemale(animal) and babyType ~= nil and babyType ~= ""
end

Cheats.LIST = {
    {
        id = "stress", min = 0, max = 100, default = 0,
        apply = function(animal, value)
            animal:setDebugStress(value)
            return true
        end,
    },
    {
        id = "hunger", min = 0, max = 100, default = 0,
        apply = function(animal, value)
            animal:getStats():set(CharacterStat.HUNGER, value / 100)
            return true
        end,
    },
    {
        id = "thirst", min = 0, max = 100, default = 0,
        apply = function(animal, value)
            animal:getStats():set(CharacterStat.THIRST, value / 100)
            return true
        end,
    },
    {
        id = "health", min = 1, max = 100, default = 100,
        apply = function(animal, value)
            animal:setHealth(value / 100)
            return true
        end,
    },
    {
        id = "age", min = 0, max = 10000,
        apply = function(animal, value)
            animal:setAgeDebug(value)
            return true
        end,
    },
    {
        id = "breed", choices = { "start", "stop" }, default = "start",
        apply = function(animal, value)
            if not canBreed(animal) then return false end
            local data = animal:getData()
            if value == "stop" then
                if not data:isPregnant() and not data:isFertilized() then return false end
                data:setPregnant(false)
                data:setPregnancyTime(0)
                data:setFertilized(false)
                data:setFertilizedTime(0)
                return true
            end
            if animal:getEggsPerDay() > 0 then
                if data:isFertilized() then return false end
                data:setFertilized(true)
                data:setFertilizedTime(1)
                return true
            end
            if data:isPregnant() then return false end
            data:setPregnant(true)
            data:setPregnancyTime(0)
            return true
        end,
    },
    {
        id = "birth", min = 0, max = 1000, default = 0,
        apply = function(animal, value)
            local data = animal:getData()
            if not data:isPregnant() then return false end
            local period = data:getPregnantPeriod()
            data:setPregnancyTime(math.max(0, math.min(period, period - value)))
            return true
        end,
    },
    {
        id = "milk", min = 0, max = 100, default = 100,
        apply = function(animal, value)
            if not animal:hasUdder() or not isAdultFemale(animal) then return false end
            local data = animal:getData()
            if value > 0 and not data:canHaveMilk() then
                data:setCanHaveMilk(true)
                if not data:canHaveMilk() then return false end
            end
            local amount = data:getMaxMilk() * value / 100
            if amount > data:getMaxMilkActual() then data:setMaxMilkActual(amount) end
            data:setMilkQuantity(amount)
            return true
        end,
    },
    {
        id = "wool", min = 0, max = 100, default = 100,
        apply = function(animal, value)
            if not animal:canBeSheared() then return false end
            local data = animal:getData()
            data:setWoolQuantity(data:getMaxWool() * value / 100, true)
            return true
        end,
    },
    {
        id = "acceptance", min = 0, max = 100, default = 100,
        apply = function(animal, value, player)
            if not player then return false end
            animal:setDebugAcceptance(player, value)
            return true
        end,
    },
    {
        id = "invincible", choices = { "on", "off" }, default = "on",
        apply = function(animal, value)
            animal:setIsInvincible(value == "on")
            return true
        end,
    },
}

Cheats.byId = {}
for _, cheat in ipairs(Cheats.LIST) do
    Cheats.byId[cheat.id] = cheat
end

--- A cheat's value made safe: a number clamped to its range and rounded to a whole
-- number, or one of its choices. nil when it cannot be one.
function Cheats.cleanValue(cheat, value)
    if cheat.choices then
        for _, choice in ipairs(cheat.choices) do
            if choice == value then return value end
        end
        return nil
    end
    value = tonumber(value)
    if not value then return nil end
    return math.max(cheat.min, math.min(cheat.max, math.floor(value + 0.5)))
end

-- Finding the animals ---------------------------------------------------------------------

local function addAnimal(found, seen, animal)
    if not animal or seen[animal] then return end
    if animal:isDead() or animal:isOnHook() then return end
    seen[animal] = true
    table.insert(found, animal)
end

local function addHutch(found, seen, hutch)
    if not hutch or seen[hutch] then return end
    seen[hutch] = true
    for i = 0, hutch:getMaxAnimals() - 1 do
        addAnimal(found, seen, hutch:getAnimal(i))
    end
    for i = 0, hutch:getMaxNestBox() do
        addAnimal(found, seen, hutch:getAnimalInNestBox(i))
    end
end

--- The hutch (the IsoHutch that holds the animals) standing on a square, if any.
local function hutchOn(square)
    local objects = square:getSpecialObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if instanceof(object, "IsoHutch") then
            return object:getHutch()
        end
    end
    return nil
end

--- The animals a cheat would go to. Returns the list, or nil and a reason:
-- "notLoaded", "noPen", "noHutch".
function Cheats.collect(x, y, z, scope)
    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, z)
    if not square then return nil, "notLoaded" end

    local found, seen = {}, {}
    if scope == "pen" then
        local zone = DesignationZoneAnimal.getZone(x, y, z)
        if not zone then return nil, "noPen" end
        local animals = zone:getAnimalsConnected()
        for i = 0, animals:size() - 1 do
            addAnimal(found, seen, animals:get(i))
        end
        local hutches = zone:getHutchsConnected()
        for i = 0, hutches:size() - 1 do
            addHutch(found, seen, hutches:get(i):getHutch())
        end
    elseif scope == "hutch" then
        local hutch = hutchOn(square)
        if not hutch then return nil, "noHutch" end
        addHutch(found, seen, hutch)
    else
        local radius = Cheats.RADIUS[scope] or 10
        local r2 = radius * radius
        for dy = -radius, radius do
            for dx = -radius, radius do
                if dx * dx + dy * dy <= r2 then
                    local sq = cell:getGridSquare(x + dx, y + dy, z)
                    if sq then
                        local moving = sq:getMovingObjects()
                        for i = 0, moving:size() - 1 do
                            local object = moving:get(i)
                            if instanceof(object, "IsoAnimal") then addAnimal(found, seen, object) end
                        end
                        local hutch = hutchOn(sq)
                        if hutch then addHutch(found, seen, hutch) end
                    end
                end
            end
        end
    end
    return found
end

--- Run a cheat on the animals of a scope, on this machine's (the server's, or single
-- player's) copy. args: { cheat, value, x, y, z, scope, kind }. Returns a result
-- table: { cheat, count, ids = online IDs of the changed animals, animals (the
-- objects, kept out of network replies) } or { reason }.
function Cheats.run(player, args)
    local cheat = type(args.cheat) == "string" and Cheats.byId[args.cheat] or nil
    if not cheat then return { reason = "badArgs" } end
    local value = Cheats.cleanValue(cheat, args.value)
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    local scope = args.scope
    if value == nil or not x or not y or not z or not isScope(scope) then return { reason = "badArgs" } end
    local kind = type(args.kind) == "string" and args.kind or Cheats.ANY_KIND

    local animals, reason = Cheats.collect(math.floor(x), math.floor(y), math.floor(z), scope)
    if not animals then return { cheat = cheat.id, reason = reason } end

    local result = { cheat = cheat.id, value = value, count = 0, ids = {}, animals = {} }
    for _, animal in ipairs(animals) do
        if kind == Cheats.ANY_KIND or animal:getAnimalType() == kind then
            local ok, changed = pcall(cheat.apply, animal, value, player)
            if ok and changed then
                result.count = result.count + 1
                table.insert(result.ids, animal:getOnlineID())
                table.insert(result.animals, animal)
            elseif not ok then
                print("[ZomboidFixesB42] Animal group cheat " .. cheat.id .. " failed on " .. tostring(animal:getFullName()) .. ": " .. tostring(changed))
            end
        end
    end
    if result.count == 0 then result.reason = "noneMatched" end
    return result
end
