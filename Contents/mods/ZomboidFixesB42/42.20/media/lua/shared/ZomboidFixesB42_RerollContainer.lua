--[[
    Zomboid Fixes B42.20 -- shared, Refill Container fix and Reroll button

    Vanilla's "Refill container" (a container button's right-click menu,
    ISInventoryPage:onBackpackRightMouseDown ~1385, offered with the LootZed cheat
    or to the admin role, isAdmin()) throws away what a container holds and fills
    it again from the loot tables. Single player does it in place
    (ItemPicker.fillContainer). In multiplayer it is a client script of commands
    that are not ordered and not checked:
      - one ISRemoveItemTool.removeItem per item;
      - object.clearContainerExplore, which marks the container unexplored and
        clears the room's procedural record but errors on a container outside a
        room (getSourceGrid():getRoom() is nil: trash bins, mailboxes), and has no
        permission check at all;
      - requestServerItemsForContainer, which the server ignores unless the
        container is unexplored by then (RequestItemsForContainerPacket), so when
        it overtakes clearContainerExplore, or that errored, nothing is refilled;
      - the client clears its own copy and marks it explored, so it stays empty.
    So on a server the option often just empties the container.

    Fixed by doing the whole reroll on the server in one go
    (server/ZomboidFixesB42_RerollContainer.lua): the client sends one command,
    CMD_REROLL_CONTAINER, with the container's address. The client file points
    vanilla's menu option at it and adds a Reroll button to the loot window, shown
    to the same people as the menu option. Option RerollContainerFix.

    A world container is addressed by its square, the object's index there, the
    container's index on the object and its type (checked; on a mismatch every
    object on the square is searched for a container of that type). Rerollable: a
    container of a world object (not a corpse, a bag on the floor or a vehicle) with
    a square, as vanilla's option (it skips vehicles, corpses, the floor and bags).
--]]

local RerollContainer = {}
ZomboidFixesB42.RerollContainer = RerollContainer

function RerollContainer.isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.RerollContainerFix == true
end

function RerollContainer.isRerollable(object, container)
    if not object or not container then return false end
    if not instanceof(object, "IsoObject") or instanceof(object, "IsoDeadBody")
        or instanceof(object, "IsoWorldInventoryObject") or instanceof(object, "BaseVehicle") then
        return false
    end
    if container:getContainingItem() or container:getParent() ~= object then return false end
    return container:getSourceGrid() ~= nil
end

--- Every rerollable container on a square, as { object, container } pairs.
function RerollContainer.onSquare(square)
    local list = {}
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        for j = 0, object:getContainerCount() - 1 do
            local container = object:getContainerByIndex(j)
            if RerollContainer.isRerollable(object, container) then
                list[#list + 1] = { object = object, container = container }
            end
        end
    end
    return list
end

function RerollContainer.hasRerollable(square)
    return #RerollContainer.onSquare(square) > 0
end

--- The container's address for the server, or nil.
function RerollContainer.address(object, container)
    if not RerollContainer.isRerollable(object, container) then return nil end
    local square = object:getSquare()
    if not square then return nil end
    for i = 0, object:getContainerCount() - 1 do
        if object:getContainerByIndex(i) == container then
            return {
                x = square:getX(), y = square:getY(), z = square:getZ(),
                index = object:getObjectIndex(), container = i, type = container:getType(),
            }
        end
    end
    return nil
end

--- Resolves an address back to the object and container, or nil.
function RerollContainer.resolve(args)
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not x or not y or not z or type(args.type) ~= "string" then return nil end
    local square = getCell():getGridSquare(x, y, z)
    if not square then return nil end
    local objects = square:getObjects()

    local index, containerIndex = tonumber(args.index), tonumber(args.container)
    if index and containerIndex and index >= 0 and index < objects:size() then
        local object = objects:get(index)
        if containerIndex >= 0 and containerIndex < object:getContainerCount() then
            local container = object:getContainerByIndex(containerIndex)
            if container:getType() == args.type and RerollContainer.isRerollable(object, container) then
                return object, container
            end
        end
    end

    -- The object list differs between the two sides: find it by type.
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        for j = 0, object:getContainerCount() - 1 do
            local container = object:getContainerByIndex(j)
            if container:getType() == args.type and RerollContainer.isRerollable(object, container) then
                return object, container
            end
        end
    end
    return nil
end
