--[[
    Zomboid Fixes B42.20 -- shared, make-up in multiplayer

    Make-up is a hidden Clothing item (scripts: `hidden = true`, BodyLocation
    base:makeup_*) worn at a MakeUp body location and kept in the main inventory
    (ISInventoryPane skips isHidden items, so it never shows there). The make-up
    window (client/ISUI/ISMakeUpUI.lua, 42.21) handles single player itself; in
    multiplayer applying goes through ISApplyMakeUp, removing does not:

      * Applying, ISApplyMakeUp:complete (server) adds a new make-up item and wears
        it, but sends the wrong item to the owner:

            self.character:getInventory():AddItem(makeUpSelected);
            sendAddItemToContainer(self.character:getInventory(), self.item);

        self.item is the lipstick or face paint used (the client already has it:
        "Dupe item ID"). The owner only learns of the make-up from the SyncClothing
        that setWornItem sends, whose SyncClothingPacket.process creates a copy
        (CreateItem + setID) worn in no inventory. The make-up it replaces is
        removed only when the server's inventory contains the item worn there, but
        by then the window's preview (a client instanceItem worn with setWornItem,
        sent by SyncClothing, which makes the server create and wear a copy of it)
        has taken its place, so the old make-up stays in the server's inventory.
        setWornItem with forceDropTooHeavy drops the preview copy it replaces on the
        floor when the player is over their weight limit.
      * Removing, ISMakeUpUI:onRemoveMakeUp (~114) is client only:

            self.character:removeWornItem(selected.item);
            self.character:getInventory():Remove(selected.item);

        The removeWornItem reaches the server as a SyncClothing, which takes it off
        there too, but the item itself stays in the server's inventory (the client
        never had it in its own, so there is nothing to remove or send). The server
        saves the player (ServerPlayerDB), so every make-up ever applied stays in the
        inventory, hidden, for good.
      * This mod's clothing wear rework takes off, after 2 s, worn items that are in
        no inventory (worn ghosts, see client/ZomboidFixesB42_ClothingWear.lua), so
        with it on the copy above came off 2 s after applying. That file now never
        takes off make-up.

    So complete (server) removes every make-up item at that location from the
    inventory and sends the right item before wearing it, and removing asks the
    server (server/ZomboidFixesB42_MakeUp.lua), which takes the item off and out of
    the inventory and tells the owner.
--]]

require "TimedActions/ISApplyMakeUp"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MakeUpSync == true
end

--- True for a MakeUp body location (the make-up window's own test).
function ZomboidFixesB42.isMakeUpLocation(location)
    if not location then return false end
    local name = location:getTranslationName()
    return name ~= nil and string.sub(name, 1, 6) == "MakeUp"
end

--- True for a make-up item: Clothing worn at a MakeUp body location.
function ZomboidFixesB42.isMakeUp(item)
    return item ~= nil and instanceof(item, "Clothing") and ZomboidFixesB42.isMakeUpLocation(item:getBodyLocation())
end

local function canUse(tool, fullType)
    for _, v in ipairs(MakeUpDefinitions.makeup) do
        if v.item == fullType and v.makeuptypes[tool:getMakeUpType()] then
            return true
        end
    end
    return false
end

local vanillaComplete = ISApplyMakeUp.complete

function ISApplyMakeUp:complete()
    -- Single player applies in the window and never runs this action.
    if not isEnabled() or not isServer() then
        return vanillaComplete(self)
    end

    if not self.item or not canUse(self.item, self.type) then
        return false
    end

    local makeUp = instanceItem(self.type)
    if not makeUp then return false end
    local location = makeUp:getBodyLocation()
    local key = tostring(location)
    local character = self.character
    local inventory = character:getInventory()

    -- Every make-up already at this location: the one worn and any left behind by
    -- earlier applies and removals.
    local old = {}
    local items = inventory:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if ZomboidFixesB42.isMakeUp(item) and tostring(item:getBodyLocation()) == key then
            table.insert(old, item)
        end
    end
    for _, item in ipairs(old) do
        sendRemoveItemFromContainer(inventory, item)
        inventory:Remove(item)
    end

    inventory:AddItem(makeUp)
    sendAddItemToContainer(inventory, makeUp)

    -- false: never drop what it replaces (a preview copy) on the floor.
    character:setWornItem(location, makeUp, false)
    sendClothing(character, location, makeUp)

    self.item:Use()
    sendItemStats(self.item)
    return true
end
