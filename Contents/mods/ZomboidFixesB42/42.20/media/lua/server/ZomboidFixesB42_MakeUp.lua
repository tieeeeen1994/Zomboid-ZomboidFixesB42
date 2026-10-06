--[[
    Zomboid Fixes B42.20 -- server, removing make-up in multiplayer

    Takes a make-up item off the player and out of their inventory, and tells the
    owner. See shared/ZomboidFixesB42_MakeUp.lua for why vanilla's removal leaves
    the item in the server's inventory.

    Only the sender's own make-up, found by item ID among their worn items and in
    their main inventory: the client's worn copy can be one SyncClothingPacket made
    (in no inventory, with the real item's ID), so either can be missing.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MakeUpSync == true
end

local function findWorn(player, id)
    local wornItems = player:getWornItems()
    if not wornItems then return nil end
    for i = 0, wornItems:size() - 1 do
        local worn = wornItems:get(i)
        local item = worn and worn:getItem()
        if item and item:getID() == id then return item end
    end
    return nil
end

local function onRemoveMakeUp(player, args)
    if not player or not isEnabled() then return end

    local id = tonumber(args.id)
    if not id then return end

    local inventory = player:getInventory()
    local worn = findWorn(player, id)
    local item = inventory:getItemWithID(id)
    if not ZomboidFixesB42.isMakeUp(worn or item) then return end

    -- false: never drop it on the floor for being over the weight limit. On the
    -- server this sends SyncClothing and SyncVisuals to everyone.
    if worn then
        player:removeWornItem(worn, false)
    end
    if item then
        sendRemoveItemFromContainer(inventory, item)
        inventory:Remove(item)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_REMOVE_MAKEUP then return end
    onRemoveMakeUp(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
