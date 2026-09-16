--[[
    Zomboid Fixes B42.20 -- client, item editor

    ISItemEditPanel:saveAll() writes every change straight onto the client's own
    copy of the item. The only thing ISItemEditorUI does about multiplayer is:

        if isClient() then
            local player = self.item:getPlayer();
            if player and player:getRole():hasCapability(Capability.InspectPlayerInventory) then
                InvMngUpdateItem(self.item, player:getOnlineID())
            end
        end

    which misses nearly everything. item:getPlayer() walks up to the outermost
    container and only returns something when that container belongs to a player, so
    an item in a crate, a vehicle or on the floor never syncs at all. And the
    capability it tests belongs to the item's *owner*, not to the admin doing the
    editing, so editing another player's item usually fails that check too. Hence
    having to take ownership of an item, drop it so the world transmits it, and pick
    it up again.

    InvMngUpdateItem itself cannot be reused more widely: it ships the whole
    serialised item (InventoryItem.saveWithSize) and the server resolves it with
    player.getInventory().getItemWithIDRecursiv(), so it is inherently limited to
    player inventories. Lua also cannot serialise an item.

    So send the changed fields instead, and let the server apply the same setters to
    its own copy and broadcast the result with sendItemStats.

    Changes go one per command: the values include free text like the item name, and
    packing several into one string would mean inventing an escaping scheme. A save
    touches a handful of fields at most.
--]]

require "ISUI/AdminPanel/ISItemEditorUI"
require "ISUI/AdminPanel/ISItemEditPanel"

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- Mirrors the file-local constants in ISItemEditPanel, which are not exported.
local TYPE_NUMBER = 1
local TYPE_STRING = 2
local TYPE_COLOR = 3
local TYPE_BOOLEAN = 4

local vanillaOnOptionMouseDown = ISItemEditorUI.onOptionMouseDown

--- Where the server should look for this item.
-- A player's inventory is searched recursively, so this also covers items inside
-- bags they are carrying. An item lying on the ground is found through the world
-- object holding it. Anything else is addressed by its outermost container.
-- Returns nil when the item cannot be addressed, and the edit is then left to
-- behave as it does in vanilla.
local function describeItem(item, character)
    if not item then return nil end

    local owner = item:getPlayer()
    if owner then
        return { id = tostring(item:getID()), owner = tostring(owner:getOnlineID()) }
    end

    -- On the ground. A held item never has a world item, so this only catches the
    -- floor case, and it is checked before the container because the floor
    -- container is a transient object the server cannot be handed a reference to.
    local worldItem = item:getWorldItem()
    local worldSquare = worldItem and worldItem:getSquare()
    if worldSquare then
        return {
            id = tostring(item:getID()),
            wx = tostring(worldSquare:getX()),
            wy = tostring(worldSquare:getY()),
            wz = tostring(worldSquare:getZ()),
        }
    end

    local container = item:getOutermostContainer()
    local encoded = container and ZomboidFixesB42.encodeContainer(container, character)
    if not encoded then return nil end

    return { id = tostring(item:getID()), cont = encoded }
end

--- Read the pending value of one editor row, or nil if it has not changed.
-- Mirrors how ISItemEditPanel:saveAll() pulls values out of the controls.
local function readChange(elem)
    if not elem.editable or not elem.control then return nil end

    if elem.type == TYPE_STRING then
        local value = string.trim(elem.control:getInternalText())
        if value == elem.originalValue then return nil end
        return "s", value

    elseif elem.type == TYPE_NUMBER then
        local value = tonumber(string.trim(elem.control:getInternalText()))
        if value == nil or value == elem.originalValue then return nil end
        return "n", tostring(value)

    elseif elem.type == TYPE_BOOLEAN then
        local value = elem.control.selected[1]
        if value == elem.originalValue then return nil end
        return "b", value and "true" or "false"

    elseif elem.type == TYPE_COLOR then
        local current = elem.control.backgroundColor
        local original = elem.originalValue
        if original and current.r == original.r and current.g == original.g and current.b == original.b then
            return nil
        end
        return "c", nil, current
    end

    return nil
end

--- Collect every pending change as a list of ready-to-send argument tables.
local function collectChanges(panel, target)
    local changes = {}

    for _, elem in ipairs(panel.usedElems or {}) do
        local valueType, value, color = readChange(elem)

        if valueType then
            local args = {
                id = target.id,
                owner = target.owner,
                cont = target.cont,
                wx = target.wx,
                wy = target.wy,
                wz = target.wz,
                vt = valueType,
            }

            if elem.isAttribute then
                if elem.attributeType then
                    args.kind = "attr"
                    args.name = elem.attributeType:getName()
                    args.v = value
                    table.insert(changes, args)
                end
            elseif valueType == "c" then
                -- Vanilla sets the three channels and then calls the registered
                -- setter with a Color, so send the channels and let the server
                -- rebuild it.
                args.kind = "color"
                args.name = elem.funcSet
                args.r = tostring(color.r)
                args.g = tostring(color.g)
                args.b = tostring(color.b)
                table.insert(changes, args)
            elseif elem.funcSet then
                args.kind = "setter"
                args.name = elem.funcSet
                args.v = value
                table.insert(changes, args)
            end
        end
    end

    return changes
end

function ISItemEditorUI:onOptionMouseDown(button, x, y)
    if button.internal ~= "SAVE" or not isClient() then
        return vanillaOnOptionMouseDown(self, button, x, y)
    end

    -- Read the controls before vanilla applies and closes them. Changes are
    -- detected against elem.originalValue, which saveAll leaves alone.
    local changes
    local target = describeItem(self.item, self.admin)
    if target then
        changes = collectChanges(self.optionsPanel, target)
    end

    -- Let vanilla apply everything locally, including its own InvMngUpdateItem
    -- path, so nothing it already handles is lost.
    vanillaOnOptionMouseDown(self, button, x, y)

    if not changes then return end

    for _, args in ipairs(changes) do
        sendClientCommand(self.admin, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_ITEM_EDIT, args)
    end
end
