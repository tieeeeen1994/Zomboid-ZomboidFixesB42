--[[
    Zomboid Fixes B42.20 -- server, debug Delete for items in bags the game cannot address

    The client file (client/ZomboidFixesB42_DeleteItems.lua) explains the bug: an
    item in a bag lying in furniture, a corpse, on the floor or two bags deep in a
    car is deleted on the admin's client, but vanilla's RemoveInventoryItemFromContainer
    packet addresses its bag with container index -1 (ContainerID.setObject), the
    server finds no container and keeps the item.

    For those the client sends CMD_DELETE_IN_BAG instead:
        { bag = <bag item ID>, ids = { <item ID>, ... },
          x, y, z = the square holding the outermost item   -- or --
          vehicle = <vehicle ID> }
    The bag is found by ID (getItemWithIDRecursiv) in every container on that square
    (objects, floor items and the bags among them, corpses) or in every part of that
    vehicle, and the listed items are removed from it.

    Same checks as vanilla's packet: Edit Item (what the packet needs and what the
    menu is offered for) and Add Item (what processServer acts on). Every delete is
    logged. The other clients near the bag are told with sendRemoveItemsFromContainer,
    which for such bags often reaches nobody (see BagContentsSync, which re-sends the
    outermost bag when its option is on); the deleting client already removed them.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local MAX_IDS = 1000

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.DeleteSelectionSync == true
end

local function findIn(container, bagId)
    if not container then return nil end
    return container:getItemWithIDRecursiv(bagId)
end

local function findBagOnSquare(square, bagId)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        for j = 0, object:getContainerCount() - 1 do
            local found = findIn(object:getContainerByIndex(j), bagId)
            if found then return found end
        end
    end

    local worldObjects = square:getWorldObjects()
    for i = 0, worldObjects:size() - 1 do
        local item = worldObjects:get(i):getItem()
        if item then
            if item:getID() == bagId then return item end
            if instanceof(item, "InventoryContainer") then
                local found = findIn(item:getItemContainer(), bagId)
                if found then return found end
            end
        end
    end

    local bodies = square:getStaticMovingObjects()
    for i = 0, bodies:size() - 1 do
        local body = bodies:get(i)
        if instanceof(body, "IsoDeadBody") then
            local found = findIn(body:getContainer(), bagId)
            if found then return found end
        end
    end
    return nil
end

local function findBagInVehicle(vehicle, bagId)
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        local found = part and findIn(part:getItemContainer(), bagId)
        if found then return found end
    end
    return nil
end

local function onDeleteInBag(player, args)
    if not player or not isEnabled() then return end

    local role = player:getRole()
    if not role or not role:hasCapability(Capability.EditItem) or not role:hasCapability(Capability.AddItem) then
        print("[ZomboidFixesB42] deleteInBag refused for " .. tostring(player:getUsername())
            .. ": needs the Edit Item and Add Item permissions")
        return
    end

    local bagId = tonumber(args.bag)
    if not bagId or type(args.ids) ~= "table" then return end

    local bag, where
    if args.vehicle ~= nil then
        local vehicleId = tonumber(args.vehicle)
        local vehicle = vehicleId and getVehicleById(vehicleId)
        if not vehicle then return end
        bag = findBagInVehicle(vehicle, bagId)
        where = "vehicle " .. string.format("%d", vehicleId)
    else
        local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
        if not x or not y or not z then return end
        local square = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z))
        if not square then return end
        bag = findBagOnSquare(square, bagId)
        where = string.format("%d,%d,%d", x, y, z)
    end
    if not bag or not instanceof(bag, "InventoryContainer") then
        print("[ZomboidFixesB42] deleteInBag: no bag " .. string.format("%d", bagId) .. " at " .. tostring(where))
        return
    end

    local container = bag:getItemContainer()
    if not container then return end

    local removed = ArrayList.new()
    local types = {}
    local count = 0
    for _, value in pairs(args.ids) do
        count = count + 1
        if count > MAX_IDS then break end
        local id = tonumber(value)
        local item = id and container:getItemWithID(id)
        if item then
            container:DoRemoveItem(item)
            removed:add(item)
            types[item:getFullType()] = true
        end
    end
    if removed:size() == 0 then return end

    pcall(sendRemoveItemsFromContainer, container, removed)

    local names = {}
    for fullType in pairs(types) do names[#names + 1] = fullType end
    print("[ZomboidFixesB42] " .. tostring(player:getUsername()) .. " deleted " .. string.format("%d", removed:size())
        .. " item(s) from bag " .. string.format("%d", bagId) .. " (" .. tostring(bag:getFullType()) .. ") at "
        .. where .. " with debug Delete: " .. table.concat(names, ", "))
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_DELETE_IN_BAG then return end
    onDeleteInBag(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
