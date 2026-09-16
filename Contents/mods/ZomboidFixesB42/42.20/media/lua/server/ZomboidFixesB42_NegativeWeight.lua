--[[
    Zomboid Fixes B42.20 -- server, negative weight items

    An item with a negative weight subtracts from whatever carries it, so a handful
    of them lets a player haul far more than their capacity allows, or lets a crate
    or a trunk hold more than it should. However such an item came about, there is
    nothing legitimate about it, so it is deleted.

    Two triggers:

      * Each player's own inventory and every bag in it, every few real seconds.
      * Whenever a player steps onto a new square, the containers that have just
        come within reach. Reach is the same 3x3 of squares the vanilla loot panel
        shows (ISInventoryPage:refreshBackpacks), covering corpses, world object
        containers and vehicle parts, and any bags inside. Never the floor itself:
        see sweepSquare.

    The world scan deliberately skips the loot panel's wall and safehouse checks.
    Those decide what a player may take; this only removes items nobody should have,
    so looking through a wall does no harm.

    Keeping it cheap. Every item looked at costs a few calls into Java, so the work
    is bounded in three ways:

      * Stepping one square only brings three (or five, diagonally) new squares
        into reach, so only those are scanned, not all nine again.
      * A world container that was checked recently and still holds the same number
        of items is skipped. The count is a plain list size, so it cannot be stale,
        and anything dropped in or taken out changes it. What it misses is an item
        changing weight in place, or something going into a bag inside the
        container; both are picked up once the recheck interval has passed.
        Content weight would be a finer fingerprint, but whether Java caches it is
        not something that can be checked from here.
      * Inventories are swept at most one player per tick rather than everyone in
        the same frame, so a full server does not produce a spike.

    Runs on the server in multiplayer and on the game itself in single player; the
    client never deletes anything on its own, so there is nothing to desync.
--]]

if isClient() then return end

require "TimedActions/ISTransferAction"

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- Fluid and drainable weights are computed, so a genuinely empty item can land a
-- hair below zero through float error. Nobody gains anything from that, and it is
-- not worth deleting someone's water bottle over.
local EPSILON = 0.0001

-- Bags inside bags inside bags. Only here so a pathological nesting cannot stall
-- the sweep.
local MAX_DEPTH = 10

-- How often, in ticks, player positions are compared for the in-range scan. A
-- sprinting player crosses several squares a second, and scanning for every one
-- of them gains nothing.
local PASS_TICKS = 10

-- How long, in real milliseconds, between sweeps of one player's inventory.
local INVENTORY_INTERVAL_MS = 5000

-- How long a world container that has not changed size is trusted for.
local CONTAINER_RECHECK_MS = 60000

-- The trust cache holds references to containers, so it is thrown away
-- wholesale this often. That keeps it from pinning parts of the map the players
-- have long since left, and costs nothing but a few extra rescans.
local CACHE_RESET_MS = 5 * 60000

-- Both keyed by playerKey. Online IDs are reused after a disconnect, so a newcomer
-- can inherit a stale entry; the worst that does is delay their first scan a little.
-- Last square each player was scanned from.
local lastPosition = {}
-- When each player's inventory was last swept.
local lastInventorySweep = {}
-- container -> { count, at }
local trusted = {}
local trustedSince = 0

local tickCounter = 0

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.DeleteNegativeWeightItems ~= false
end

--- A stable per-player key. On a server the online ID, which is unique even for
-- split-screen guests sharing one connection; otherwise the local player number.
local function playerKey(player)
    if isServer() then
        return "o" .. tostring(player:getOnlineID())
    end
    return "l" .. tostring(player:getPlayerNum())
end

--- Should this be looked at again? Records it as looked at if so.
local function needsCheck(key, count, now)
    local entry = trusted[key]
    if entry and entry.count == count and now - entry.at < CONTAINER_RECHECK_MS then
        return false
    end
    trusted[key] = { count = count, at = now }
    return true
end

local function hasNegativeWeight(item, isBag)
    -- A bag's unequipped weight includes its contents, so a bag holding a negative
    -- item reads negative too. The bag itself is innocent; the item inside is found
    -- and deleted on its own. So a bag is judged on its own weight alone.
    if isBag then
        return item:getActualWeight() < -EPSILON
    end
    -- Anything else on what it actually adds to encumbrance, which for fluid
    -- containers and drainables includes what is in them.
    return item:getUnequippedWeight() < -EPSILON
end

--- Gather every negative item in a container tree, as { container, item } pairs.
-- Collected first and deleted afterwards, so no list is modified while it is being
-- walked. A deleted bag takes its contents with it, so there is no need to look
-- inside one.
local function collect(container, depth, found)
    if not container or depth > MAX_DEPTH then return found end

    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local isBag = instanceof(item, "InventoryContainer")
        if hasNegativeWeight(item, isBag) then
            table.insert(found, { container = container, item = item })
        elseif isBag then
            collect(item:getInventory(), depth + 1, found)
        end
    end
    return found
end

local function logDeletion(item, weight, where)
    print(string.format("ZomboidFixesB42 deleted negative weight item %s (id %s, weight %s) from %s",
        tostring(item:getFullType()), tostring(item:getID()), tostring(weight), where))
end

--- Delete an item from a container. Pass the character when the container tree is
-- that character's own inventory, so anything held, worn or on the hotbar is taken
-- off them first.
local function deleteFromContainer(container, item, character, where)
    local weight = item:getActualWeight()

    local onBody = false
    if character then
        onBody = character:isEquipped(item) or item:getAttachedSlot() ~= -1
        -- Unequip, unwear and detach, the same way a vanilla transfer does, or the
        -- character is left holding an item that no longer exists.
        ISTransferAction:removeItemOnCharacter(character, item)
    end

    container:DoRemoveItem(item)
    if isServer() then
        sendRemoveItemFromContainer(container, item)
    end

    if onBody then
        sendEquip(character)
    end

    logDeletion(item, weight, where)
end

local function sweepContainer(container, character, where)
    for _, entry in ipairs(collect(container, 0, {})) do
        deleteFromContainer(entry.container, entry.item, character, where)
    end
end

--- A world container, skipped if it was checked recently and has not changed size.
local function sweepWorldContainer(container, where, now)
    if not container then return end
    if not needsCheck(container, container:getItems():size(), now) then return end
    sweepContainer(container, nil, where)
end

local function describeSquare(square)
    return string.format("%d,%d,%d", square:getX(), square:getY(), square:getZ())
end

local function sweepSquare(square, vehiclesSeen, now)
    local where = describeSquare(square)

    -- Items lying on the floor are deliberately left alone. Removing one from a
    -- square reaches the clients as an object index, and a client whose object list
    -- is ordered differently removes whatever sits at that index instead -- a crate,
    -- a hutch. A negative item on the ground gives nobody anything anyway, and the
    -- inventory sweep deletes it soon after it is picked up.

    -- Corpses.
    local staticObjects = square:getStaticMovingObjects()
    if staticObjects then
        for i = 0, staticObjects:size() - 1 do
            local object = staticObjects:get(i)
            if object then
                sweepWorldContainer(object:getContainer(), "a corpse at " .. where, now)
            end
        end
    end

    -- Crates, shelves, fridges and anything else built into the world. An object
    -- can hold more than one container.
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        for c = 0, object:getContainerCount() - 1 do
            local container = object:getContainerByIndex(c)
            sweepWorldContainer(container, tostring(container:getType()) .. " at " .. where, now)
        end
    end

    -- A vehicle spans several squares, so it is only swept once per scan.
    local vehicle = square:getVehicleContainer()
    if vehicle and not vehiclesSeen[vehicle] then
        vehiclesSeen[vehicle] = true
        for p = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(p)
            local container = part and part:getItemContainer()
            if container then
                sweepWorldContainer(container, string.format("vehicle %s %s at %s",
                    tostring(vehicle:getId()), tostring(part:getId()), where), now)
            end
        end
    end
end

local function isSweepable(player)
    return player and not player:isDead() and not instanceof(player, "IsoAnimal")
end

--- Scan whatever has come into reach since the player was last scanned.
local function checkMoved(player, now)
    local square = player:getCurrentSquare()
    if not square then return end

    local key = playerKey(player)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local last = lastPosition[key]
    if last and last.x == x and last.y == y and last.z == z then return end
    lastPosition[key] = { x = x, y = y, z = z }

    local cell = getCell()
    local vehiclesSeen = {}

    for dy = -1, 1 do
        for dx = -1, 1 do
            local sx, sy = x + dx, y + dy
            -- Already in reach from the previous square, so already scanned. After a
            -- teleport, a level change or on the first scan, everything is new.
            local wasInReach = last and last.z == z
                and math.abs(sx - last.x) <= 1 and math.abs(sy - last.y) <= 1
            if not wasInReach then
                local target = cell:getGridSquare(sx, sy, z)
                if target then
                    sweepSquare(target, vehiclesSeen, now)
                end
            end
        end
    end
end

--- Every player this side of the game is responsible for.
local function getPlayers()
    local players = {}

    -- Everyone connected, on a server. Empty in single player.
    local online = getOnlinePlayers()
    if online then
        for i = 0, online:size() - 1 do
            table.insert(players, online:get(i))
        end
    end

    -- Local players, which covers single player and split screen. Skipped on a
    -- server so nobody is handled twice.
    if not isServer() then
        for i = 0, getNumActivePlayers() - 1 do
            table.insert(players, getSpecificPlayer(i))
        end
    end

    return players
end

--- Sweep the first player whose inventory is due, and no one else this tick.
-- Run every tick rather than every pass: a dedicated server ticks slowly, and one
-- inventory per pass would leave a full server's players waiting far longer than
-- the interval.
local function sweepOneInventory(players, now)
    for _, player in ipairs(players) do
        if isSweepable(player) then
            local key = playerKey(player)
            if now - (lastInventorySweep[key] or 0) >= INVENTORY_INTERVAL_MS then
                lastInventorySweep[key] = now
                sweepContainer(player:getInventory(), player, tostring(player:getUsername()) .. "'s inventory")
                return
            end
        end
    end
end

local function onTick()
    if not isEnabled() then return end

    local now = getTimestampMs()
    local players = getPlayers()

    sweepOneInventory(players, now)

    tickCounter = tickCounter + 1
    if tickCounter < PASS_TICKS then return end
    tickCounter = 0

    if now - trustedSince > CACHE_RESET_MS then
        trusted = {}
        trustedSince = now
    end

    for _, player in ipairs(players) do
        if isSweepable(player) then
            checkMoved(player, now)
        end
    end
end

Events.OnTick.Add(onTick)
