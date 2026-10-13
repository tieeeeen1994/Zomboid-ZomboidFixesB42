--[[
    Zomboid Fixes B42.20 -- server, zombie damage to car doors and bodywork

    A zombie banging on a car door or body panel lowers its condition only on the
    game that owns the zombie (client/ZomboidFixesB42_ZombieCarDamage.lua has the
    Java). That client sends each loss as zombieCarDamage { vehicle, part, amount,
    zombie }, and this applies it the way AttackVehicleState does on the owner:

        part:setCondition(condition - amount)
        part:doInventoryItemStats(item, 0)
        vehicle:transmitPartCondition(part)
        vehicle:transmitPartItem(part)

    which on the server reaches every client near the car, the owner included (its
    copy already shows the hit, so nothing changes there).

    Checked against the server: the part is a door or body panel with no window of
    its own and some condition left, someone is in the vehicle, the zombie is alive,
    within a few tiles of the car on the server and owned by the sender
    (IsoZombie.getOwnerPlayer), at most one hit per zombie per MIN_ZOMBIE_GAP_MS
    (a bang lasts over a second) and RATE_LIMIT a second per player, and the amount
    is at most the strongest zombie's strength (5, "Superhuman"). A vehicle God
    Vehicle holds is left alone. Option ZombieCarDamageSync.
--]]

if isClient() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ZombieCarDamageSync == true
end

-- Tiles around the vehicle searched for the zombie (its server position trails
-- the owner's a little).
local SEARCH_RADIUS = 6
-- IsoZombie.strength is 5, 3 or 1 by the Strength sandbox option, or 1-4 for random.
local MAX_AMOUNT = 5
local MIN_ZOMBIE_GAP_MS = 500
local RATE_LIMIT = 30

local function isHitPart(part)
    local category = part:getCategory()
    return (category == "door" or category == "bodywork") and part:getWindow() == nil
end

local function hasOccupant(vehicle)
    for seat = 0, vehicle:getMaxPassengers() - 1 do
        if vehicle:getCharacter(seat) then return true end
    end
    return false
end

local function findZombie(vehicle, id)
    local square = vehicle:getSquare()
    if not square then return nil end
    local cell = getCell()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for dx = -SEARCH_RADIUS, SEARCH_RADIUS do
        for dy = -SEARCH_RADIUS, SEARCH_RADIUS do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq then
                local objects = sq:getMovingObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if instanceof(object, "IsoZombie") and object:getOnlineID() == id then
                        return object
                    end
                end
            end
        end
    end
    return nil
end

-- [player online ID] = { second = whole second, count = hits in it }
local rates = {}
-- [zombie online ID] = time of its last hit
local lastHit = {}
local lastCleanup = 0

--- Counts a command against the sender's limit; false once they are over it.
local function withinRate(player)
    local now = getTimestampMs()
    local playerId = player:getOnlineID()
    local second = math.floor(now / 1000)
    local rate = rates[playerId]
    if not rate or rate.second ~= second then
        rate = { second = second, count = 0 }
        rates[playerId] = rate
    end
    rate.count = rate.count + 1
    return rate.count <= RATE_LIMIT
end

--- One hit per zombie per bang.
local function acceptHit(zombieId)
    local now = getTimestampMs()
    local last = lastHit[zombieId]
    if last and now - last < MIN_ZOMBIE_GAP_MS then return false end
    lastHit[zombieId] = now

    if now - lastCleanup > 60000 then
        lastCleanup = now
        local stale = {}
        for id, t in pairs(lastHit) do
            if now - t > 10000 then stale[#stale + 1] = id end
        end
        for _, id in ipairs(stale) do lastHit[id] = nil end
    end
    return true
end

local function onZombieCarDamage(player, args)
    if not isEnabled() or not player or player:isDead() or not withinRate(player) then return end

    local vehicleId = tonumber(args.vehicle)
    local zombieId = tonumber(args.zombie)
    local amount = tonumber(args.amount)
    if not vehicleId or not zombieId or not amount or type(args.part) ~= "string" then return end
    amount = math.floor(amount)
    if amount < 1 then return end
    amount = math.min(amount, MAX_AMOUNT)

    local vehicle = getVehicleById(vehicleId)
    if not vehicle or not hasOccupant(vehicle) then return end
    local part = vehicle:getPartById(args.part)
    if not part or not isHitPart(part) or part:getCondition() <= 0 then return end

    local GodVehicle = ZomboidFixesB42.GodVehicle
    if GodVehicle and GodVehicle.isHeld and GodVehicle.isHeld(vehicle) then return end

    local zombie = findZombie(vehicle, zombieId)
    if not zombie or zombie:isDead() or zombie:getOwnerPlayer() ~= player then return end
    if not acceptHit(zombieId) then return end

    part:setCondition(math.max(0, part:getCondition() - amount))
    local item = part:getInventoryItem()
    if item then part:doInventoryItemStats(item, 0) end
    vehicle:transmitPartCondition(part)
    vehicle:transmitPartItem(part)
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_ZOMBIE_CAR_DAMAGE then return end
    onZombieCarDamage(player, type(args) == "table" and args or {})
end

Events.OnClientCommand.Add(onClientCommand)
