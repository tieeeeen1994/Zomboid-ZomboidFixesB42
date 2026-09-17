--[[
    Zomboid Fixes B42.20 -- server, item editor

    Applies one edited field to the authoritative copy of an item and broadcasts the
    result. See the client file for why vanilla only manages this for items sitting
    in a player's inventory.

    Setter names arrive from a client, so they are checked against the editor's own
    field registry before being called. That registry is rebuilt here from
    ISItemEditPanel:initElements(), which is entirely static -- it just inserts
    descriptor tables and never touches the item -- so running it against a bare
    probe object yields exactly the set of fields the editor can offer, without
    duplicating the list.
--]]

if isClient() then return end

require "ISUI/AdminPanel/ISItemEditPanel"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local registry = nil
local registryBuilt = false

--- funcSet name -> the editor's descriptor for that field.
local function getRegistry()
    if registryBuilt then return registry end
    registryBuilt = true

    -- pcall because this walks a client UI file. If it is unavailable for any
    -- reason we fall back to a narrower check rather than failing outright.
    local ok, result, fieldCount = pcall(function()
        local probe = setmetatable({ elems = {} }, { __index = ISItemEditPanel })
        ISItemEditPanel.initElements(probe)

        local bySetter = {}
        local count = 0
        for _, elem in ipairs(probe.elems) do
            if elem.funcSet then
                bySetter[elem.funcSet] = elem
                count = count + 1
            end
        end
        return bySetter, count
    end)

    -- Not next(result): Kahlua does not provide next().
    if ok and result and fieldCount and fieldCount > 0 then
        registry = result
    else
        print("ZomboidFixesB42.applyItemEdit could not rebuild the item editor field list; falling back to name checks")
    end

    return registry
end

--- Is this a setter the item editor could legitimately have offered?
local function resolveSetter(item, name)
    if type(name) ~= "string" then return nil end

    local known = getRegistry()
    if known then
        local elem = known[name]
        if not elem then return nil end
        if type(item[name]) ~= "function" then return nil end
        return elem
    end

    -- Fallback: a set* method that actually exists on this item. The command is
    -- already gated on Capability.EditItem, so this is a sanity check rather than
    -- the security boundary.
    if string.sub(name, 1, 3) ~= "set" then return nil end
    if type(item[name]) ~= "function" then return nil end
    return {}
end

--- Find an item lying on a square, by the world object carrying it.
local function findWorldItem(square, id)
    local worldObjects = square:getWorldObjects()
    if not worldObjects then return nil end

    for i = 0, worldObjects:size() - 1 do
        local worldObject = worldObjects:get(i)
        local item = worldObject and worldObject:getItem()
        if item and item:getID() == id then
            return item
        end
    end
    return nil
end

--- Find the item the client is talking about.
-- A player's inventory is searched recursively, which also covers bags they carry.
-- Items on the ground come through as a square, everything else as its outermost
-- container.
local function resolveItem(player, args)
    local id = tonumber(args.id)
    if not id then return nil end

    if args.owner then
        local owner = getPlayerByOnlineID(tonumber(args.owner) or -1)
        local inventory = owner and owner:getInventory()
        return inventory and inventory:getItemWithIDRecursiv(id) or nil
    end

    if args.wx then
        local square = getCell():getGridSquare(tonumber(args.wx), tonumber(args.wy), tonumber(args.wz))
        return square and findWorldItem(square, id) or nil
    end

    local container = ZomboidFixesB42.decodeContainer(args.cont, player)
    return container and container:getItemWithIDRecursiv(id) or nil
end

--- Convert the transported value into what the setter expects.
local function decodeValue(valueType, raw)
    if valueType == "n" then return tonumber(raw) end
    if valueType == "s" then return raw end
    if valueType == "b" then return raw == "true" end
    return nil
end

local function applyAttribute(item, args)
    if type(args.name) ~= "string" then return false end

    local attributes = item:getAttributes()
    if not attributes then return false end

    -- Walked by index and matched on name, the same way ISItemEditPanel
    -- :initAttributes() enumerates them. Attribute.TypeFromName() would be more
    -- direct but nothing in vanilla Lua touches that class, so its availability
    -- here is not something to rely on.
    local attribute = nil
    for i = 0, attributes:size() - 1 do
        local key = attributes:getKey(i)
        if key and key:getName() == args.name then
            attribute = attributes:getAttribute(i)
            break
        end
    end
    if not attribute then return false end

    -- Mirrors ISItemEditPanel:saveAll(): numbers go through setValueFloat, the
    -- rest through setValue.
    if args.vt == "n" then
        local value = tonumber(args.v)
        if value == nil then return false end
        attribute:setValueFloat(value)
    else
        local value = decodeValue(args.vt, args.v)
        if value == nil then return false end
        attribute:setValue(value)
    end

    return true
end

local function applyColor(item, args)
    local r, g, b = tonumber(args.r), tonumber(args.g), tonumber(args.b)
    if not r or not g or not b then return false end

    local elem = resolveSetter(item, args.name)
    if not elem then return false end

    -- Same order as the editor's colour branch.
    item:setColorRed(r)
    item:setColorGreen(g)
    item:setColorBlue(b)
    item[args.name](item, Color.new(r, g, b, 1))

    return true, elem
end

local function applySetter(item, args)
    local elem = resolveSetter(item, args.name)
    if not elem then return false end

    local value = decodeValue(args.vt, args.v)
    if value == nil then return false end

    -- The editor's weight box has a minimum of 0, but that is only enforced on the
    -- client. Negative weights are deleted on sight anyway (see
    -- ZomboidFixesB42_NegativeWeight), so do not let this path create them.
    if args.name == "setActualWeight" and value < 0 then return false end

    item[args.name](item, value)
    return true, elem
end

local function onApplyItemEdit(player, args)
    local role = player and player:getRole()
    if not role or not role:hasCapability(Capability.EditItem) then
        print("ZomboidFixesB42.applyItemEdit The player's access level is not sufficient to perform this action")
        return
    end

    local item = resolveItem(player, args)
    if not item then return end

    local applied, elem
    if args.kind == "attr" then
        applied = applyAttribute(item, args)
    elseif args.kind == "color" then
        applied, elem = applyColor(item, args)
    elseif args.kind == "setter" then
        applied, elem = applySetter(item, args)
    end

    if not applied then return end

    -- Some fields carry a follow-up the editor performs after setting them, such as
    -- flagging a custom weight or restoring fully repaired clothing. They only need
    -- the item and the editing player, so a probe stands in for the panel.
    if elem and elem.funcOnSave then
        pcall(elem.funcOnSave, { item = item, admin = player })
    end

    -- Two different packets, because neither one carries the whole item.
    --
    -- ItemStatsPacket is the food and consumable side of things -- hunger, calories,
    -- cooked, burned, frozen, spices, uses -- plus the handful of basics it always
    -- writes. Nothing in it describes how an item looks.
    sendItemStats(item)

    -- SyncItemFieldsPacket is the rest: the ItemVisual, so clothing holes, patches,
    -- per-body-part blood, dirtiness and wetness, alongside condition, head
    -- condition, sharpness, colour, custom name and mod data. Without it a
    -- fully restored jacket arrives at the client with perfect condition and every
    -- hole still in place, because fullyRestore() only touched the visual.
    --
    -- It addresses the item through ContainerID, which knows about floor containers
    -- and resolves them back through the IsoWorldInventoryObject, so this reaches
    -- items lying on the ground as well as ones in a container.
    if type(item.syncItemFields) == "function" then
        item:syncItemFields()
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_ITEM_EDIT then return end
    onApplyItemEdit(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
