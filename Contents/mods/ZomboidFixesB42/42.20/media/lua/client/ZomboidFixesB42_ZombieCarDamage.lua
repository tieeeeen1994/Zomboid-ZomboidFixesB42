--[[
    Zomboid Fixes B42.20 -- client, zombie damage to car doors and bodywork

    A zombie going for someone inside a vehicle runs AttackVehicleState
    (zombie/vehicles/AttackVehicleState.java, 42.21). At the end of each bang
    (the "ThumpFrame" event of Zombie_DoorBang / Zombie_DoorShoulder) it hits:

      - the passenger's window, if the zombie stands at that seat's door and the
        window can be hit, else that closed door;
      - otherwise the nearest "door" or "bodywork" part around it
        (BaseVehicle.getNearestBodyworkPart), or that part's window.

    A window hit goes through VehicleWindow.damage, which on a client sends
    vehicle.damageWindow to the server: windows are fine. A door or body panel
    hit is done right there:

        part.setCondition(part.getCondition() - zombie.strength)
        part.doInventoryItemStats(part.getInventoryItem(), 0)
        vehicle.transmitPartCondition(part)     -- server only
        vehicle.transmitPartItem(part)          -- server only

    and the transmits do nothing on a client. Only one game runs this: the zombie's
    owner. Every other client puts a zombie it does not own in
    attackvehicle-network (bClient = GameClient.client && isRemoteZombie() in the
    zombie action group), which is GenericDefaultState and has no anim events. So
    in multiplayer the dents exist only on the game that owns the zombie: nobody
    else sees them, the server's car stays whole, and they are gone for that player
    too once the car is sent again (reloading the area, relogging, any repair).

    This file watches the doors and body panels of every vehicle with a player in
    it (the only vehicles a zombie attacks), once a tick. When one loses condition
    while a zombie this game owns is in "attackvehicle" next to the car going for
    someone in it, the loss is sent to the server, zombieCarDamage { vehicle, part,
    amount, zombie }, which applies it with vanilla's own code
    (server/ZomboidFixesB42_ZombieCarDamage.lua). Drops that come from the server
    (crashes, other players' hits sent back) happen to remote or absent zombies,
    or change the part's item, and are not sent. A vehicle God Vehicle holds is
    skipped: the hold puts its condition back.

    Multiplayer only. In single player the game is the server.
--]]

if not isClient() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ZombieCarDamageSync == true
end

-- Tiles around the vehicle searched for the zombie that hit it. A car is up to
-- about 5 tiles long and the zombie stands next to it.
local SEARCH_RADIUS = 4

local function isHitPart(part)
    local category = part:getCategory()
    return (category == "door" or category == "bodywork") and part:getWindow() == nil
end

local function itemIdOf(part)
    local item = part:getInventoryItem()
    return item and item:getID() or -1
end

-- [vehicle id] = { vehicle, parts = { { part, condition, itemId } } }
local watched = {}

local function watch(vehicle)
    local entry = { vehicle = vehicle, parts = {} }
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        if part and isHitPart(part) then
            table.insert(entry.parts, { part = part, condition = part:getCondition(), itemId = itemIdOf(part) })
        end
    end
    return entry
end

--- Vehicles with a player in them that this game knows of.
local function occupiedVehicles()
    local vehicles = {}
    local function add(player)
        local vehicle = player and player:getVehicle()
        if vehicle then vehicles[vehicle:getId()] = vehicle end
    end
    for i = 0, getNumActivePlayers() - 1 do
        add(getSpecificPlayer(i))
    end
    local online = getOnlinePlayers()
    if online then
        for i = 0, online:size() - 1 do
            add(online:get(i))
        end
    end
    return vehicles
end

--- A zombie this game owns banging on the vehicle for someone inside it.
local function findAttacker(vehicle)
    local square = vehicle:getSquare()
    if not square then return nil end
    local cell = getCell()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local best, bestDist = nil, nil
    for dx = -SEARCH_RADIUS, SEARCH_RADIUS do
        for dy = -SEARCH_RADIUS, SEARCH_RADIUS do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq then
                local objects = sq:getMovingObjects()
                for i = 0, objects:size() - 1 do
                    local zombie = objects:get(i)
                    if instanceof(zombie, "IsoZombie") and not zombie:isRemoteZombie() and not zombie:isDead() then
                        local state = zombie:getCurrentActionContextStateName()
                        local target = zombie:getTarget()
                        if state and string.lower(state) == "attackvehicle" and target
                            and instanceof(target, "IsoGameCharacter") and target:getVehicle() == vehicle then
                            local dist = dx * dx + dy * dy
                            if not bestDist or dist < bestDist then
                                best, bestDist = zombie, dist
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

local function report(vehicle, part, amount)
    local zombie = findAttacker(vehicle)
    local player = getPlayer()
    if not zombie or not player then return end
    sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_ZOMBIE_CAR_DAMAGE, {
        vehicle = vehicle:getId(),
        part = part:getId(),
        amount = amount,
        zombie = zombie:getOnlineID(),
    })
end

local function onTick()
    if not isEnabled() then
        watched = {}
        return
    end

    local GodVehicle = ZomboidFixesB42.GodVehicle
    local seen = {}
    for id, vehicle in pairs(occupiedVehicles()) do
        seen[id] = true
        local entry = watched[id]
        if not entry or entry.vehicle ~= vehicle then
            -- First seen, or streamed in again as a new object.
            watched[id] = watch(vehicle)
        else
            local held = GodVehicle and GodVehicle.isNamed and GodVehicle.isNamed(id)
            for _, snap in ipairs(entry.parts) do
                local condition = snap.part:getCondition()
                local itemId = itemIdOf(snap.part)
                if not held and condition < snap.condition and itemId == snap.itemId then
                    report(vehicle, snap.part, snap.condition - condition)
                end
                snap.condition = condition
                snap.itemId = itemId
            end
        end
    end
    for id in pairs(watched) do
        if not seen[id] then watched[id] = nil end
    end
end

Events.OnTick.Add(onTick)

Events.OnInitWorld.Add(function()
    watched = {}
end)
