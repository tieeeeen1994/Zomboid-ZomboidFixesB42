--[[
    Zomboid Fixes B42.20 -- server, Refill Container fix and Reroll button

    Rerolls one world container (why: shared/ZomboidFixesB42_RerollContainer.lua).
    In one go, on the server:

      - the items are sent away (sendRemoveItemsFromContainer: to the clients near
        the object) and removed (removeItemsFromProcessItems, so nothing keeps
        cooking or ticking, then removeAllItems);
      - the room's record of procedural items already spawned
        (RoomDef.getProceduralSpawnedContainer, which keeps a room from spawning
        some items twice) is cleared, as vanilla's refill does, guarded for a
        container outside a room;
      - ItemPickerJava.fillContainer rolls it again exactly as the first look at an
        unexplored container does (RequestItemsForContainerPacket: setExplored,
        fillContainer, then every item sent with AddInventoryItemToContainer), and
        the new items are sent the same way (sendAddItemsToContainer);
      - ItemPickerJava.updateOverlaySprite redraws shelves that show their contents
        (doOverlaySprite sends the change from the server).

    Who may: on a server, a role with Capability.UseLootZed. Vanilla offers the
    option to the admin role (which has every capability) and to whoever has the
    LootZed cheat on, which needs that capability. Single player runs this too
    (sendClientCommand reaches this handler there); the role has no capabilities
    there, so the client's own check (the LootZed cheat) is the gate, as in
    vanilla. Also checked: the container within MAX_DISTANCE tiles of the server's
    copy of the player, at most one command per MIN_GAP_MS. Every reroll on a
    server goes to the admin log with the place and the item counts.

    The admin hotbar's "Reroll containers" sends { x, y, z, all = true } for a
    square picked anywhere on screen: every rerollable container there is rerolled.
--]]

if isClient() then return end

local RerollContainer = ZomboidFixesB42.RerollContainer

-- The loot window reaches one tile around the player, the hotbar's square picker
-- anything on screen; the server's copy of the player trails the client's.
local MAX_DISTANCE = 60
local MIN_GAP_MS = 200

-- [username] = getTimestampMs() of the last reroll
local lastReroll = {}

local function isAllowed(player)
    if player:isDead() then return false end
    if not isServer() then return true end
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.UseLootZed)
end

local function copyOf(list)
    local copy = ArrayList.new()
    copy:addAll(list)
    return copy
end

local function reroll(player, object, container)
    local items = container:getItems()
    local removed = items:size()
    if removed > 0 then
        sendRemoveItemsFromContainer(container, copyOf(items))
        container:removeItemsFromProcessItems()
        container:removeAllItems()
    end

    local square = container:getSourceGrid()
    local room = square and square:getRoom()
    local roomDef = room and room:getRoomDef()
    local spawned = roomDef and roomDef:getProceduralSpawnedContainer()
    if spawned then spawned:clear() end

    container:setExplored(true)
    ItemPickerJava.fillContainer(container, player)

    local added = container:getItems():size()
    if added > 0 then
        sendAddItemsToContainer(container, copyOf(container:getItems()))
    end
    ItemPickerJava.updateOverlaySprite(object)
    return removed, added
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_REROLL_CONTAINER then return end
    if not player or type(args) ~= "table" or not RerollContainer.isEnabled() then return end
    if not isAllowed(player) then
        print("ZomboidFixesB42.rerollContainer The player's access level is not sufficient to perform this action")
        return
    end

    local username = player:getUsername()
    local now = getTimestampMs()
    if lastReroll[username] and now - lastReroll[username] < MIN_GAP_MS then return end

    local targets = {}
    if args.all == true then
        local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
        local square = x and y and z and getCell():getGridSquare(x, y, z)
        if square then targets = RerollContainer.onSquare(square) end
    else
        local object, container = RerollContainer.resolve(args)
        if object then targets = { { object = object, container = container } } end
    end
    if #targets == 0 then return end
    local square = targets[1].object:getSquare()
    if math.abs(square:getX() - player:getX()) > MAX_DISTANCE or math.abs(square:getY() - player:getY()) > MAX_DISTANCE then
        return
    end
    lastReroll[username] = now

    for _, target in ipairs(targets) do
        local removed, added = reroll(player, target.object, target.container)
        if isServer() then
            writeLog("admin", string.format("%s rerolled a %s at %d,%d,%d (%d items removed, %d added)",
                tostring(username), target.container:getType(), square:getX(), square:getY(), square:getZ(), removed, added))
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
