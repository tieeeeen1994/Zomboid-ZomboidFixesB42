--[[
    Zomboid Fixes B42.20 -- client, debug Delete > One item / Selection reach the server

    An item's right-click menu has Debug > Delete > One item / Selection for anyone
    with the Edit Item permission (ISRemoveItemTool.lua ~328, RemoveItemContextOptions).
    removeItem (~272) takes the item out of the client's container (DoRemoveItem),
    unequips / unwears / unattaches it, and sends sendRemoveItemFromContainer(container,
    item): one RemoveInventoryItemFromContainer packet per item. A floor item also
    costs an object.removeWorldItem client command (that is what removes it there).
    The server side (RemoveInventoryItemFromContainerPacket.processServer, 42.22) is
    fine: it removes every listed ID it finds in the addressed container, needs Edit
    Item for the packet and Add Item to act, relays to nearby clients and writes the
    item log. Three things go wrong (42.22, traced 2026-11-13):

    1. Selection sends one packet per item, and a client silently drops packets of
       one type beyond the server's MaxPacketsPerSecond (300 by default) in a second
       (PacketsCache.isLimitExceeded). Deleting a stack of 2000 removes all 2000 on
       the client and ~300 on the server; the rest come back on relog and keep
       growing the saved character. A character the server cannot fit into 1 MB is
       saved with no data at all (ServerPlayerDB.NetworkCharacterData stops growing
       its buffer at 1 MB) and can no longer log in: LoadPlayerProfilePacket.write
       throws on the NULL buffer.
    2. An item in a bag that lies in furniture (or in a corpse, or in a bag on the
       floor, or two bags deep in a car) gets an address the server cannot resolve:
       ContainerID.set walks to the outermost container's parent and calls setObject,
       whose containerIndex = object.getContainerIndex(bag's container) is -1, so the
       server's getContainerByIndex(-1) is nil and nothing is removed. Same for both
       options. Your own bags (InventoryContainer: found by ID) and a bag directly in
       a vehicle part (ObjectInVehicle) are fine.
    3. "One item" deletes listItems[1], and listItems is built from a pairs() walk
       over a set of the selected items, so with several rows selected it deletes
       any one of them, not the one you right-clicked.

    Fixed here, on a client only (single player has no packets):
    - ISRemoveItemTool.removeItem and removeItems are replaced. Vanilla's removeItem
      still does all the local work for each item, but its sendRemoveItemFromContainer
      calls are collected. Per container they go out as CMD_DELETE_ITEMS commands
      (CHUNK item IDs each) naming where to look: the player's own inventory tree,
      the square of the object, corpse or floor item holding the container (at any
      bag depth), or the vehicle. The server finds each item by ID there and removes
      it (server/ZomboidFixesB42_DeleteItems.lua). The Lua global
      sendRemoveItemsFromContainer cannot batch them: on a client it does nothing
      (LuaManager.GlobalObject ~9985 only sends when GameServer.server), which is
      why 3.4.0's batching deleted nothing on the server at all (reported
      2026-11-20: deleted items were back after relogging). A container with no such
      address still gets vanilla's packet per item.
    - Floor items keep vanilla's sends and are paced through a queue at
      FLOOR_PER_SECOND, well under the limit.
    - After vanilla fills the menu, "One item" is pointed at the row under the mouse
      (the first selected item if the mouse is over none).

    Not changed: vanilla offers the option for Edit Item but the server only acts
    for Add Item, so a role with the first and not the second still deletes on its
    own client only (admin and moderator have both).
--]]

if not isClient() then return end

require "DebugUIs/ISRemoveItemTool"
require "ISUI/ISInventoryPaneContextMenu"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local CHUNK = 500
local FLOOR_PER_SECOND = 100

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.DeleteSelectionSync == true
end

local vanillaRemoveItem = ISRemoveItemTool.removeItem
local vanillaRemoveItems = ISRemoveItemTool.removeItems

local function isFloorItem(item)
    local container = item:getContainer()
    return container ~= nil and container:getType() == "floor" and item:getWorldItem() ~= nil
end

local function squareAddress(square)
    if not square then return nil end
    return { x = square:getX(), y = square:getY(), z = square:getZ() }
end

--- Where the server should look for the items of `container`: the player's own
--- inventory tree, the square of the object / corpse / floor item holding it (at
--- any bag depth), or the vehicle whose part holds it. nil when none is known.
local function addressOf(container, playerObj)
    if container == playerObj:getInventory() or container:isInCharacterInventory(playerObj) then
        return { inv = true }
    end
    local current = container
    for _ = 1, 20 do
        local part = current:getVehiclePart()
        if part then
            local vehicle = part:getVehicle()
            return vehicle and { vehicle = vehicle:getId() } or nil
        end
        local parent = current:getParent()
        if parent and instanceof(parent, "IsoObject") and parent:getSquare() then
            return squareAddress(parent:getSquare())
        end
        local bag = current:getContainingItem()
        if not bag then return nil end
        local worldItem = bag:getWorldItem()
        if worldItem and worldItem:getSquare() then
            return squareAddress(worldItem:getSquare())
        end
        current = bag:getContainer()
        if not current then return nil end
    end
    return nil
end

local function sendCollected(groups, order, playerObj)
    for _, container in ipairs(order) do
        local items = groups[container]
        local address = addressOf(container, playerObj)
        if address then
            local i = 1
            while i <= #items do
                local last = math.min(#items, i + CHUNK - 1)
                local ids = {}
                for n = i, last do ids[#ids + 1] = items[n]:getID() end
                address.ids = ids
                sendClientCommand(playerObj, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_DELETE_ITEMS, address)
                i = last + 1
            end
        else
            -- No address the server could use: vanilla's packet per item.
            for _, item in ipairs(items) do
                sendRemoveItemFromContainer(container, item)
            end
        end
    end
end

-- Floor items waiting for vanilla's removeItem: { item, player }.
local floorQueue = {}
local floorHead = 1
local floorBudget = 0
local lastTickMs = nil

local function onTick()
    local now = getTimestampMs()
    if lastTickMs then
        floorBudget = math.min(FLOOR_PER_SECOND, floorBudget + (now - lastTickMs) * FLOOR_PER_SECOND / 1000)
    end
    lastTickMs = now
    while floorBudget >= 1 and floorHead <= #floorQueue do
        local entry = floorQueue[floorHead]
        floorQueue[floorHead] = nil
        floorHead = floorHead + 1
        floorBudget = floorBudget - 1
        -- Skip items someone else picked up or removed in the meantime.
        if isFloorItem(entry.item) then
            vanillaRemoveItem(entry.item, entry.player)
        end
    end
    if floorHead > #floorQueue then
        floorQueue = {}
        floorHead = 1
        lastTickMs = nil
        floorBudget = 0
        Events.OnTick.Remove(onTick)
    end
end

local function queueFloorItem(item, player)
    if floorHead > #floorQueue then
        -- Starting a new run: the first FLOOR_PER_SECOND go out at once.
        floorBudget = FLOOR_PER_SECOND
        lastTickMs = nil
        Events.OnTick.Remove(onTick)
        Events.OnTick.Add(onTick)
    end
    floorQueue[#floorQueue + 1] = { item = item, player = player }
end

--- Vanilla's local removal for every item, with the sends collected and batched.
local function removeNow(items, player)
    local playerObj = getSpecificPlayer(player)
    local groups = {}
    local order = {}
    local vanillaSend = sendRemoveItemFromContainer
    sendRemoveItemFromContainer = function(container, item)
        local group = groups[container]
        if not group then
            group = {}
            groups[container] = group
            order[#order + 1] = container
        end
        group[#group + 1] = item
    end

    local ok, err = pcall(function()
        for _, item in ipairs(items) do
            if isFloorItem(item) then
                queueFloorItem(item, player)
            elseif item:getContainer() then
                vanillaRemoveItem(item, player)
            end
        end
    end)

    sendRemoveItemFromContainer = vanillaSend
    -- Whatever was already removed locally must still reach the server.
    if playerObj then
        sendCollected(groups, order, playerObj)
    end
    if not ok then error(err) end
end

function ISRemoveItemTool.removeItem(item, player)
    if not isClient() or not isEnabled() then
        return vanillaRemoveItem(item, player)
    end
    removeNow({ item }, player)
end

function ISRemoveItemTool.removeItems(items, player)
    if not isClient() or not isEnabled() then
        return vanillaRemoveItems(items, player)
    end
    removeNow(items, player)
end

--- The item on the inventory row under the mouse, if one of the player's panes
--- has one.
local function hoveredItem(player)
    local pages = { getPlayerInventory(player), getPlayerLoot(player) }
    for _, page in ipairs(pages) do
        local pane = page and page.inventoryPane
        if pane and pane:isMouseOver() and pane.mouseOverOption and pane.items then
            local row = pane.items[pane.mouseOverOption]
            if instanceof(row, "InventoryItem") then return row end
            if type(row) == "table" and row.items and row.items[1] then return row.items[1] end
        end
    end
    return nil
end

local function firstItem(items)
    local first = items[1]
    if first == nil then return nil end
    if instanceof(first, "InventoryItem") then return first end
    return first.items and first.items[1] or nil
end

local function isSelected(items, item)
    for _, v in ipairs(items) do
        if v == item then return true end
        if not instanceof(v, "InventoryItem") and v.items then
            for _, it in ipairs(v.items) do
                if it == item then return true end
            end
        end
    end
    return false
end

-- Runs after vanilla's RemoveItemContextOptions (vanilla files load first).
local function pointOneItemAtClicked(player, context, items)
    if not isClient() or not isEnabled() then return end
    local debugMenu = context:getSubMenu(ISInventoryPaneContextMenu.debugContextNum) or context
    local deleteOption = debugMenu:getOptionFromName(getText("ContextMenu_Delete"))
    local deleteMenu = deleteOption and deleteOption.subOption and debugMenu:getSubMenu(deleteOption.subOption)
    local oneOption = deleteMenu and deleteMenu:getOptionFromName(getText("ContextMenu_Delete_OneItem"))
    if not oneOption then return end

    local item = hoveredItem(player)
    if not item or not isSelected(items, item) then
        item = firstItem(items)
    end
    if item then oneOption.target = item end
end

Events.OnFillInventoryObjectContextMenu.Add(pointOneItemAtClicked)
