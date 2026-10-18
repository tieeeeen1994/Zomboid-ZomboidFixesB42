--[[
    Zomboid Fixes B42.20 -- server, what the server puts into or takes out of a bag in a
    car reaches the players

    Server Lua tells clients about a container's contents with the globals
    sendAddItemToContainer, sendAddItemsToContainer, sendRemoveItemFromContainer,
    sendRemoveItemsFromContainer and sendReplaceItemInContainer. GameServer (~2475, 42.21)
    picks who gets the packet from the container itself:

        if (container.getCharacter() instanceof IsoPlayer)      -> that player
        else if (container.getParent() != null)                  -> players near the parent
        else if (container.inventoryContainer.getWorldItem())    -> players near the bag
        (else nobody)

    A bag lying in a car's trunk, glove box or seat has none of the three: no character,
    no world item, and its container's parent is only ever set by IsoObject.setContainer
    (an object's own containers, and a bag dropped on the floor, whose world object
    becomes its parent and stays its parent after it is picked up, until that world
    object is recycled). So every change server Lua makes inside such a bag goes to
    nobody, or to whoever stands where the bag last lay on the floor. The address in
    the packet would have been fine: ContainerID.set works it out from the outermost
    container, and for a bag directly in a vehicle part it is ObjectInVehicle (vehicle
    ID, part index, the bag's item ID), which a client resolves in its own copy of that
    part. Java's own item transactions are not affected: Transaction.updateItem sends
    with sendToRelative at the ContainerID's x, y.

    The case reported (2026-10-19): Fast Timed Actions / fast forward move items with
    ISTransferAction:transferItem on the server (ZomboidFixesB42_Server.lua), which ends
    in sendRemoveItemFromContainer for the source and this mod's sendAddItemToContainer
    for the destination. Eggs put into a cooler in a trunk never showed up in it, the
    transfer waited 10 s for them to arrive, and every look into the cooler showed what
    the client had before; eggs taken out of it arrived in the inventory but stayed in
    the cooler too. Tien's Coolers clearing spent ice and handing back plastic bags in
    such a cooler, and every vanilla server-side recipe or action that adds to a bag in a
    car, never showed either.

    So the five globals are wrapped. For a bag lying directly in a vehicle part
    container the bag's container gets the vehicle as its parent for the length of the
    call (INetworkPacket.sendToRelative builds and sends each packet at once) and gets
    its own parent back afterwards; the packet then goes to the players near the car
    with vanilla's own address, and their copy of the bag keeps being the same object,
    so a transfer waiting for an item to arrive in it sees it arrive.

    A bag the clients cannot address at all gets the whole outermost bag sent again
    (sendReplaceItemInContainer: the client swaps its copy, contents included, by ID),
    once per tick however many changes there were: a bag inside another bag in a car
    (the client looks the ObjectInVehicle item ID up in the part's container only), and
    a bag in a crate or on a shelf (ContainerID.setObject stores the crate's
    getContainerIndex of the bag's container, -1, which getContainerByIndex answers with
    nil on both ends). Vanilla never shows such bags in the loot window, but container
    mods do, and Tien's Coolers works on coolers on shelves.

    Not changed: bags a player carries (vanilla sends to that player), bags on the
    floor, and Java's own sends.
--]]

if isClient() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.BagContentsSync == true
end

-- Bags inside bags; vanilla stops far short of this.
local MAX_DEPTH = 10

--- How GameServer would fail to reach this container, and what reaches it instead.
-- "route", vehicle: a bag lying directly in a vehicle part container.
-- "resend", container, bag: the outermost bag and the world or vehicle container it
-- lies in, for a bag no client can find by its address.
-- nil: vanilla already sends to the right players (or there is nobody to send to).
local function classify(container)
    if not container then return nil end
    local holder = container:getContainingItem()
    if not holder or holder:getWorldItem() then return nil end
    if container:getCharacter() then return nil end

    local outer = holder:getContainer()
    if not outer then return nil end
    if not outer:getContainingItem() then
        local parent = outer:getParent()
        if not parent then return nil end
        if instanceof(parent, "BaseVehicle") then return "route", parent end
        return "resend", outer, holder
    end

    -- Deeper: climb to the bag that lies in a world or vehicle container.
    local bag = outer:getContainingItem()
    for _ = 1, MAX_DEPTH do
        if bag:getWorldItem() then return nil end
        local around = bag:getContainer()
        if not around then return nil end
        local up = around:getContainingItem()
        if not up then
            if not around:getParent() then return nil end
            return "resend", around, bag
        end
        bag = up
    end
    return nil
end

local pending = {}
local pendingCount = 0

local function queueResend(container, bag)
    local id = bag:getID()
    if not pending[id] then pendingCount = pendingCount + 1 end
    pending[id] = { container = container, bag = bag }
end

local function flushResends()
    if pendingCount == 0 then return end
    local due = pending
    pending, pendingCount = {}, 0
    for id, entry in pairs(due) do
        -- Gone since (moved, picked up): the move sent it the normal way.
        if entry.container:containsID(id) then
            sendReplaceItemInContainer(entry.container, entry.bag, entry.bag)
        end
    end
end

--- Run `call` (the vanilla send for `container`) so that it reaches the players who
-- see that container.
local function send(container, call)
    local kind, target, bag = nil, nil, nil
    if isServer() and isEnabled() then
        kind, target, bag = classify(container)
    end

    if kind ~= "route" then
        call()
        if kind == "resend" then queueResend(target, bag) end
        return
    end

    -- The parent goes back even when the send throws: a bag left parented to the car
    -- would be sent to the car's players from then on, wherever it went.
    local parent = container:getParent()
    container:setParent(target)
    local ok, err = pcall(call)
    container:setParent(parent)
    if not ok then error(err) end
end

-- One wrapper per arity: the globals are Java functions, and an extra nil argument
-- is still an argument to Kahlua's overload matching.
local function wrap2(name)
    local original = _G[name]
    if original == nil then return end
    _G[name] = function(container, a)
        send(container, function() original(container, a) end)
    end
end

local function wrap3(name)
    local original = _G[name]
    if original == nil then return end
    _G[name] = function(container, a, b)
        send(container, function() original(container, a, b) end)
    end
end

wrap2("sendAddItemToContainer")
wrap2("sendAddItemsToContainer")
wrap2("sendRemoveItemFromContainer")
wrap2("sendRemoveItemsFromContainer")
-- flushResends goes through this wrapper too, and passes straight through: the
-- outermost bag lies in a container vanilla already reaches.
wrap3("sendReplaceItemInContainer")

Events.OnTick.Add(flushResends)
