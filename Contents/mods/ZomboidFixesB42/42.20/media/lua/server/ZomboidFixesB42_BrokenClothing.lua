--[[
    Zomboid Fixes B42.20 -- server, broken clothing

    Applies a clothing break a client reports to the server's own copy of the item.
    See the client file for how the two copies drift apart.

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
    return vars ~= nil and vars.SyncBrokenClothing == true
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

local function onTick()
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

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_BROKEN_CLOTHING then return end
    onBrokenClothing(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(onTick)
