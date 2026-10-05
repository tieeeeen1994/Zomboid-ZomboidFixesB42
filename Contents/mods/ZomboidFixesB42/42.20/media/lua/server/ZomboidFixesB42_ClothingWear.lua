--[[
    Zomboid Fixes B42.20 -- server, clothing wear down rework

    Each player's game rolls every zombie attack that lands on it and sends a thump
    or a blocked attack as its own event, clothingWear { zombie, part, scratch }
    (client/ZomboidFixesB42_ClothingWear.lua, which explains vanilla's roll). This
    file applies each event to the server's copy of the clothing with vanilla's own
    player:addHoleFromZombieAttacks(part, scratch): it picks the hit layer from the
    server's current clothing and rolls the hole and the armor chance, and its
    setConditionAndSync works here (ItemStats to the owner; at 0 Clothing.setCondition
    takes the item off and drops it, replicated to everyone). Events only add holes
    and take condition, so their order does not matter and none replaces another. At
    the end of the tick each player whose clothing changed is synced once
    (player:syncVisuals(): SyncVisuals and HumanVisual to everyone, the owner
    included), which also replaces the holes vanilla's local roll of the owner's own
    zombies added on the owner's game. An event with no part only asks for that sync.

    The client's own syncs (vanilla sends SyncVisuals from a client when dirt is
    added, for example) replace every worn item's holes and condition on the server
    with the client's, which may not have the server's copy of the last swing yet.
    So what each swing changed (new holes, the condition after) is kept for GUARD_MS
    and put back if a client sync takes it away. A raise of condition within that
    time is taken back too, legitimate or not.

    The event is checked against the server: the player alive and not in god mode,
    a zombie with that online ID within a few tiles, at most one event per zombie per
    MIN_ZOMBIE_GAP_MS and RATE_LIMIT a second per player. It can only wear the
    sender's own clothing.

    The rest of this file applies a clothing break a client reports to the server's
    own copy of the item; see the client file for how the two copies drift apart.
    Trusting the client here is safe because it can only ever hurt the reporter:
    the item has to be in their own inventory, and the only outcome is that item
    losing its condition and being dropped at their feet. Nothing is
    created, so nothing can be duplicated.

    The drop waits until the server's copy is no longer worn. When the server gets
    a SyncClothing listing a worn item it does not have in the inventory, it creates
    a new one with that ID and puts it on (SyncClothingPacket.process). So dropping
    the item while a SyncClothing that still lists it is on its way would leave a
    fresh, undamaged copy on the player. The client takes the item off as it
    reports, and SyncClothing arrives in order, so once the server sees the item
    unworn every older SyncClothing has already been applied and it is safe to drop.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ClothingWearRework == true
end

-- How long to wait for the client's SyncClothing before giving up and letting
-- vanilla Unwear drop the item anyway.
local PENDING_TIMEOUT_MS = 10000

-- Broken items waiting to be taken off, by item ID.
local pending = {}
local pendingCount = 0

--- Copy the client's holes onto the item. Only ever adds holes, never removes
-- them, and removes the patch under each new one the way BloodClothingType.addHole
-- does.
local function applyHoles(item, encoded)
    if type(encoded) ~= "string" or not item:getCanHaveHoles() then return end

    local visual = item:getVisual()
    if not visual then return end

    local max = BloodBodyPartType.MAX:index()
    for field in string.gmatch(encoded, "%d+") do
        local index = tonumber(field)
        if index and index >= 0 and index < max then
            local part = BloodBodyPartType.FromIndex(index)
            if visual:getHole(part) <= 0 then
                visual:setHole(part)
                item:removePatch(part)
            end
        end
    end
end

--- Do the drop Unwear(true) would have done, for an item already taken off.
local function dropItem(player, item)
    local square = player:getCurrentSquare()
    if not square or player:getVehicle() then return end

    local inventory = player:getInventory()
    sendRemoveItemFromContainer(inventory, item)
    inventory:Remove(item)
    square:AddWorldInventoryItem(item, ZombRand(100) / 100, ZombRand(100) / 100, 0.0)
end

local function removePending(id)
    pending[id] = nil
    pendingCount = pendingCount - 1
end

local function onBrokenClothing(player, args)
    if not isEnabled() or not player or player:isDead() then return end

    local id = tonumber(args.id)
    if not id or pending[id] then return end

    -- Worn items live in the main inventory, never in a bag.
    local item = player:getInventory():getItemWithID(id)
    if not item or not instanceof(item, "Clothing") or not item:isRemoveOnBroken() then return end

    applyHoles(item, args.holes)

    -- Without the sound, because Clothing.setCondition(int) is the one that calls
    -- Unwear(true), and the drop has to wait. The client already played the sound.
    item:setConditionNoSound(0)

    pending[id] = { player = player, item = item, deadline = getTimestampMs() + PENDING_TIMEOUT_MS }
    pendingCount = pendingCount + 1
end

local function tickBroken()
    if pendingCount == 0 then return end

    -- IDs copied out first so entries can be removed while walking them.
    local ids = {}
    for id in pairs(pending) do
        table.insert(ids, id)
    end

    local now = getTimestampMs()
    for _, id in ipairs(ids) do
        local entry = pending[id]
        local player, item = entry.player, entry.item

        if player:isDead() or item:getContainer() ~= player:getInventory() then
            -- Gone, or moved somewhere else since. Nothing left to drop.
            removePending(id)
        elseif not item:isWorn() then
            removePending(id)
            dropItem(player, item)
        elseif now >= entry.deadline then
            -- The client never took it off. Let vanilla do it: this takes it off,
            -- drops it and replicates both.
            removePending(id)
            item:setCondition(0)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Wear from zombie attacks
-- ---------------------------------------------------------------------------

-- Tiles around the server's position of the player searched for the zombie.
local SEARCH_RADIUS = 3
-- A swing is longer than this, so two events for one zombie inside it are one
-- swing.
local MIN_ZOMBIE_GAP_MS = 300
-- Events a player may send a second.
local RATE_LIMIT = 10
-- How long an applied swing is protected from a client sync that undoes it.
local GUARD_MS = 5000

local PART_MAX = BodyPartType.ToIndex(BodyPartType.MAX)

local function findZombie(player, id)
    local square = player:getCurrentSquare()
    if not square then return nil end
    local cell = getCell()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for dz = -1, 1 do
        for dx = -SEARCH_RADIUS, SEARCH_RADIUS do
            for dy = -SEARCH_RADIUS, SEARCH_RADIUS do
                local sq = cell:getGridSquare(x + dx, y + dy, z + dz)
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
    end
    return nil
end

-- [player online ID] = { second = whole second, count = events in it }
local rates = {}
-- ["player:zombie"] = time of the last event
local lastEvent = {}
local lastCleanup = 0

local function accept(player, zombieId)
    local now = getTimestampMs()
    local playerId = player:getOnlineID()

    local second = math.floor(now / 1000)
    local rate = rates[playerId]
    if not rate or rate.second ~= second then
        rate = { second = second, count = 0 }
        rates[playerId] = rate
    end
    rate.count = rate.count + 1
    if rate.count > RATE_LIMIT then return false end

    local key = playerId .. ":" .. zombieId
    local last = lastEvent[key]
    if last and now - last < MIN_ZOMBIE_GAP_MS then return false end
    lastEvent[key] = now

    if now - lastCleanup > 60000 then
        lastCleanup = now
        local stale = {}
        for k, t in pairs(lastEvent) do
            if now - t > 10000 then stale[#stale + 1] = k end
        end
        for _, k in ipairs(stale) do lastEvent[k] = nil end
    end
    return true
end

-- [full type] = ArrayList of the BloodBodyPartTypes the item covers, or false
local coveredCache = {}

local function coveredParts(item)
    local fullType = item:getFullType()
    local parts = coveredCache[fullType]
    if parts == nil then
        local types = item:getBloodClothingType()
        parts = types and BloodClothingType.getCoveredParts(types) or false
        coveredCache[fullType] = parts
    end
    return parts or nil
end

--- Every worn item's condition and the covered parts it has no hole at.
local function snapshot(player)
    local result = {}
    local wornItems = player:getWornItems()
    for i = 0, wornItems:size() - 1 do
        local item = wornItems:getItemByIndex(i)
        local visual = item and item:getVisual()
        local parts = visual and coveredParts(item)
        if parts then
            local open = {}
            for j = 0, parts:size() - 1 do
                local part = parts:get(j)
                if visual:getHole(part) == 0 then open[part:index()] = true end
            end
            result[item] = {
                open = open,
                condition = instanceof(item, "Clothing") and item:getCondition() or nil,
            }
        end
    end
    return result
end

-- { player, item, holes = { part index... }, condition, expires }: what applied
-- swings did, put back when a client sync takes it away.
local guards = {}
-- [player] = true: players whose clothing is synced at the end of the tick.
local dirty = {}

--- Apply one swing to the server's copy of the player's clothing with vanilla's
-- own code (the hole or armor roll, condition, ItemStats, the drop of a broken
-- item), and remember what it changed.
local function applySwing(player, part, scratch)
    if part then
        local before = snapshot(player)
        player:addHoleFromZombieAttacks(BloodBodyPartType.FromIndex(part), scratch)

        local expires = getTimestampMs() + GUARD_MS
        for item, was in pairs(before) do
            local visual = item:getVisual()
            local holes = {}
            for index in pairs(was.open) do
                if visual:getHole(BloodBodyPartType.FromIndex(index)) > 0 then
                    table.insert(holes, index)
                end
            end
            local condition = was.condition and item:getCondition() or nil
            if #holes > 0 or (condition and condition < was.condition) then
                table.insert(guards, {
                    player = player, item = item, holes = holes,
                    condition = condition, expires = expires,
                })
            end
        end
    end
    -- Also with no part: the client asks for the server's copy back.
    dirty[player] = true
end

--- Put back what a client sync took from a swing applied in the last few
-- seconds: SyncVisuals replaces every worn item's holes and condition with the
-- client's, which may not have the server's copy yet. Several guards on one item
-- end at the lowest condition.
local function checkGuards()
    if #guards == 0 then return end
    local now = getTimestampMs()
    for i = #guards, 1, -1 do
        local guard = guards[i]
        local player, item = guard.player, guard.item
        if now > guard.expires or player:isDead() or not item:isWorn()
            or item:getContainer() ~= player:getInventory() then
            table.remove(guards, i)
        else
            local fixed = false
            local visual = item:getVisual()
            local clothing = instanceof(item, "Clothing")
            for _, index in ipairs(guard.holes) do
                local part = BloodBodyPartType.FromIndex(index)
                -- A patch there now was sewn on since; left alone.
                if visual:getHole(part) == 0 and not (clothing and item:getPatchType(part)) then
                    visual:setHole(part)
                    fixed = true
                end
            end
            -- At 0 vanilla has taken the item off and dropped it already.
            if guard.condition and guard.condition > 0 and item:getCondition() > guard.condition then
                item:setConditionNoSound(guard.condition)
                fixed = true
            end
            if fixed then dirty[player] = true end
        end
    end
end

local function onClothingWear(player, args)
    if not isEnabled() or not player or player:isDead() or player:isGodMod() then return end

    local zombieId = tonumber(args.zombie)
    if not zombieId then return end
    local part = nil
    if args.part ~= nil then
        part = tonumber(args.part)
        if not part or part ~= math.floor(part) or part < 0 or part >= PART_MAX then return end
    end
    if not accept(player, zombieId) then return end

    local zombie = findZombie(player, zombieId)
    if not zombie or zombie:isDead() then return end

    applySwing(player, part, args.scratch == true)
end

local function onTick()
    tickBroken()
    checkGuards()
    for player in pairs(dirty) do
        if not player:isDead() then player:syncVisuals() end
    end
    dirty = {}
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command == ZomboidFixesB42.CMD_BROKEN_CLOTHING then
        onBrokenClothing(player, args or {})
    elseif command == ZomboidFixesB42.CMD_CLOTHING_WEAR then
        onClothingWear(player, type(args) == "table" and args or {})
    end
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(onTick)
