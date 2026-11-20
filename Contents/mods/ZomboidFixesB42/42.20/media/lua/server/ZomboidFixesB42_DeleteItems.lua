--[[
    Zomboid Fixes B42.20 -- server, debug Delete > One item / Selection on the server

    The client file (client/ZomboidFixesB42_DeleteItems.lua) explains the bugs:
    vanilla's one packet per item loses everything past MaxPacketsPerSecond, and an
    item in a bag lying in furniture, a corpse, on the floor or two bags deep in a
    car gets an address (container index -1) the server cannot resolve.

    The client sends CMD_DELETE_ITEMS instead, per container it deleted from:
        { ids = { <item ID>, ... },
          inv = true                     -- the sender's own inventory tree, or
          x, y, z = a square             -- the object / corpse / floor item there, or
          vehicle = <vehicle ID> }
    Each item is found by ID (getItemWithIDRecursiv) in the sender's inventory, in
    every container on that square (objects, floor bags, corpses) or in every part of
    that vehicle, and removed with ItemContainer.Remove like vanilla's packet. An
    item from the sender's own inventory is also taken off (worn, attached, hands);
    the client did that on its copy and sends it too, this only keeps the server's
    copy right whatever arrives first.

    Same checks as vanilla's packet: Edit Item (what the packet needs and what the
    menu is offered for) and Add Item (what processServer acts on). Every delete is
    logged. The other clients near a world container are told with
    sendRemoveItemsFromContainer, which for bags in furniture often reaches nobody
    (see BagContentsSync, which re-sends the outermost bag when its option is on);
    the deleting client already removed them.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local MAX_IDS = 1000

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.DeleteSelectionSync == true
end

local function addContainer(list, container)
    if container then list[#list + 1] = container end
end

local function containersOnSquare(square)
    local list = {}
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        for j = 0, object:getContainerCount() - 1 do
            addContainer(list, object:getContainerByIndex(j))
        end
    end

    local worldObjects = square:getWorldObjects()
    for i = 0, worldObjects:size() - 1 do
        local item = worldObjects:get(i):getItem()
        if item and instanceof(item, "InventoryContainer") then
            addContainer(list, item:getItemContainer())
        end
    end

    local bodies = square:getStaticMovingObjects()
    for i = 0, bodies:size() - 1 do
        local body = bodies:get(i)
        if instanceof(body, "IsoDeadBody") then
            addContainer(list, body:getContainer())
        end
    end
    return list
end

local function containersInVehicle(vehicle)
    local list = {}
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        if part then addContainer(list, part:getItemContainer()) end
    end
    return list
end

local function findItem(containers, id)
    for _, container in ipairs(containers) do
        local item = container:getItemWithIDRecursiv(id)
        if item then return item end
    end
    return nil
end

--- The containers to search and a description for the log, or nil.
local function resolveAddress(player, args)
    if args.inv == true then
        return { player:getInventory() }, "own inventory"
    end
    if args.vehicle ~= nil then
        local vehicleId = tonumber(args.vehicle)
        local vehicle = vehicleId and getVehicleById(vehicleId)
        if not vehicle then return nil end
        return containersInVehicle(vehicle), "vehicle " .. string.format("%d", vehicleId)
    end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not x or not y or not z then return nil end
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    local square = getCell():getGridSquare(x, y, z)
    if not square then return nil end
    return containersOnSquare(square), string.format("%d,%d,%d", x, y, z)
end

local function onDeleteItems(player, args)
    if not player or not isEnabled() then return end

    local role = player:getRole()
    if not role or not role:hasCapability(Capability.EditItem) or not role:hasCapability(Capability.AddItem) then
        print("[ZomboidFixesB42] deleteItems refused for " .. tostring(player:getUsername())
            .. ": needs the Edit Item and Add Item permissions")
        return
    end
    if type(args.ids) ~= "table" then return end

    local containers, where = resolveAddress(player, args)
    if not containers then
        print("[ZomboidFixesB42] deleteItems from " .. tostring(player:getUsername()) .. ": location not found")
        return
    end
    local own = args.inv == true

    local groups, order = {}, {}
    local types = {}
    local count, removedCount, missing = 0, 0, 0
    for _, value in pairs(args.ids) do
        count = count + 1
        if count > MAX_IDS then break end
        local id = tonumber(value)
        local item = id and findItem(containers, id)
        local container = item and item:getContainer()
        if container then
            if own then
                if player:isEquippedClothing(item) then player:removeWornItem(item, false) end
                player:removeAttachedItem(item)
                if player:isHandItem(item) then player:removeFromHands(item) end
            end
            container:Remove(item)
            if not own then
                local group = groups[container]
                if not group then
                    group = ArrayList.new()
                    groups[container] = group
                    order[#order + 1] = container
                end
                group:add(item)
            end
            removedCount = removedCount + 1
            types[item:getFullType()] = true
        else
            missing = missing + 1
        end
    end

    for _, container in ipairs(order) do
        pcall(sendRemoveItemsFromContainer, container, groups[container])
    end

    local names = {}
    for fullType in pairs(types) do names[#names + 1] = fullType end
    print("[ZomboidFixesB42] " .. tostring(player:getUsername()) .. " deleted " .. string.format("%d", removedCount)
        .. " item(s) at " .. where .. " with debug Delete"
        .. (missing > 0 and (" (" .. string.format("%d", missing) .. " not found)") or "")
        .. ": " .. table.concat(names, ", "))
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_DELETE_ITEMS then return end
    onDeleteItems(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
