--[[
    Zomboid Fixes B42.20 -- client, a bag's max item size is checked per item

    Some bags take only items up to a weight: MaxItemSize in the item script (ALICE
    belt and chest rig 1.3, toolboxes and totes 2, first aid kits 1, hollow books
    1.6, wallets 0.2...). The Java check is in ItemContainer.hasRoomFor(chr,
    weight, weightAddedToFloor):

        } else if (this.inventoryContainer != null && this.inventoryContainer.getMaxItemSize() > 0.0F
                   && weightVal > this.inventoryContainer.getMaxItemSize()) {
            return false;

    which is right for one item, but two inventory window paths pass the running
    total of everything being moved:

      * dragging items onto a bag (ISInventoryPaneDraggedItems:update, ISInventoryPane
        ~1439: hasRoomFor(playerObj, newTotalWeight, newWeightAddedToFloor));
      * the "transfer items of the same type" button
        (ISInventoryWindowControlHandler_TransferSameTypeMultiContainer:consumeItems:
        hasRoomFor(self.playerObj, totalWeight + weight)).

    So a stack only goes in while its total stays under the size limit: 4 full
    M1911 magazines or 1 M16 magazine per drag into ALICE webbing with room for many
    more (forum 98673, 101849).

    Both are run here with the limit taken off that one bag's script for the call
    (Item.maxItemSize is read live by InventoryContainer.getMaxItemSize; the call is
    synchronous, so nothing else sees it), and the items heavier than the limit are
    held back separately, as one item at a time is. The total weight check stays
    vanilla's. With RemoveMaxItemSize on there is no limit left to check.

    Not reachable from Lua: picking items up from the floor straight into such a
    bag. TransactionManager.isConsistent (Java, client and server) checks
    hasRoomFor(item weight + every pending transaction into the same bag), so a
    batch of floor pickups into it still stops at the size limit.
--]]

require "ISUI/ISInventoryPane"
require "ISUI/InventoryWindow/Handlers/TransferSameTypeMultiContainer"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MaxItemSizePerItem == true
end

--- The bag item behind a container and its size limit, or nil when it has none.
local function sizeLimitOf(container)
    local bag = container and container:getContainingItem()
    if not bag or not instanceof(bag, "InventoryContainer") then return nil end
    local limit = bag:getMaxItemSize()
    if not limit or limit <= 0 then return nil end
    return bag:getScriptItem(), limit
end

--- Runs fn(...) with `script`'s MaxItemSize off, and puts it back even on an error.
local function withoutLimit(script, limit, fn, ...)
    script:DoParam("MaxItemSize", "0")
    local results = { pcall(fn, ...) }
    script:DoParam("MaxItemSize", tostring(limit))
    if not results[1] then error(results[2]) end
    return results[2], results[3]
end

-- ---------------------------------------------------------------------------
-- Dragging
-- ---------------------------------------------------------------------------

local DraggedItems = ISInventoryPaneDraggedItems
local vanillaDraggedUpdate = DraggedItems.update

function DraggedItems:update(...)
    if not isEnabled() then return vanillaDraggedUpdate(self, ...) end

    -- getDropContainer reads self.playerNum, which vanilla's update only sets on its
    -- first line: on a new pane's first drag it is still nil (getPlayerData(nil) errors).
    self.playerNum = self.inventoryPane.player
    local container = self:getDropContainer()
    local script, limit = sizeLimitOf(container)
    if not script then return vanillaDraggedUpdate(self, ...) end

    -- Vanilla fills self.items on the first update the same way.
    if not self.items then
        self.items = ISInventoryPane.getActualItems(ISMouseDrag.dragging)
        self.inventoryPane:sortItemsByTypeAndWeight(self.items)
    end

    local all, fits, tooBig = self.items, {}, {}
    for _, item in ipairs(all) do
        if item:getUnequippedWeight() > limit then
            table.insert(tooBig, item)
        else
            table.insert(fits, item)
        end
    end

    self.items = fits
    local ok, err = pcall(withoutLimit, script, limit, vanillaDraggedUpdate, self, ...)
    self.items = all
    if not ok then error(err) end

    for _, item in ipairs(tooBig) do
        self.itemNotOK[item] = true
    end
end

-- ---------------------------------------------------------------------------
-- Transfer items of the same type
-- ---------------------------------------------------------------------------

local Handler = ISInventoryWindowControlHandler_TransferSameTypeMultiContainer
local vanillaConsumeItems = Handler.consumeItems

--- Vanilla's consumeItems, with items over the bag's size limit skipped instead of
-- ending the batch, and the total checked without the limit.
function Handler:consumeItems(lootContainer, allItemsMap, ...)
    if not isEnabled() then return vanillaConsumeItems(self, lootContainer, allItemsMap, ...) end
    local script, limit = sizeLimitOf(lootContainer)
    if not script then return vanillaConsumeItems(self, lootContainer, allItemsMap, ...) end

    local itemMapLoot = self:getItemsTable(lootContainer)
    local itemsToTransferList = {}
    for type, _ in pairs(itemMapLoot) do
        if allItemsMap[type] then
            for _, item in ipairs(allItemsMap[type]) do
                if not item:isFavorite() and not item:isEquipped() then
                    table.insert(itemsToTransferList, item)
                end
            end
        end
    end
    local lootWindow = getPlayerLoot(self.playerNum)
    lootWindow.inventoryPane:sortItemsByTypeAndWeight(itemsToTransferList)

    local totalWeight = 0.0
    local itemsToTransferList1 = {}
    for _, item in ipairs(itemsToTransferList) do
        local weight = item:getUnequippedWeight()
        if weight <= limit then
            local wanted = totalWeight + weight
            local room = withoutLimit(script, limit, function()
                return lootContainer:hasRoomFor(self.playerObj, wanted)
            end)
            if not room then break end
            table.insert(itemsToTransferList1, item)
            local sourceItemList = allItemsMap[item:getFullType()]
            local index = luautils.indexOf(sourceItemList, item)
            table.remove(sourceItemList, index)
            totalWeight = totalWeight + weight
        end
    end
    return itemsToTransferList1
end
