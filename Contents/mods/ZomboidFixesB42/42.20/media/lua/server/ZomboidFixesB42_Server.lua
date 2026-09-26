--[[
    Zomboid Fixes B42.20 -- server

    Performs the instant item transfers the client asks for, and replicates them.

    This path bypasses the vanilla transaction system, so it also has to repeat the
    checks TransactionManager.isConsistent() would have made: that the source really
    holds the item, that the destination will accept it, and that the player is
    near enough to both. Getting that wrong is how you end up with duped items, so
    every item is validated individually and anything that fails is skipped rather
    than fudged.
--]]

if isClient() then return end

require "TimedActions/ISTransferAction"

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- A single transfer action never queues anywhere near this many items. It is only
-- here so a tampered client cannot hand us an unbounded list to walk.
local MAX_ITEMS_PER_COMMAND = 250

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.FastTransfers == true
end

--- Is this player actually allowed to cheat?
local function isAllowed(player)
    if not isEnabled() then return false end
    if not player or player:isDead() then return false end

    -- Matches the gate inside IsoPlayer.isTimedActionInstant().
    if player:isAccessLevel("None") then return false end

    if not player:isTimedActionInstantCheat() then return false end

    -- The admin panel only offers the toggle to roles holding this capability, so
    -- honour the same rule here.
    local role = player:getRole()
    if role and Capability and Capability.UseTimedActionInstantCheat then
        if not role:hasCapability(Capability.UseTimedActionInstantCheat) then return false end
    end

    return true
end

--- Is the player near enough to use this container?
local function isInReach(player, container)
    local x, y = ZomboidFixesB42.containerPosition(container)
    -- Containers the player is carrying have no world position and are always fine.
    if not x then return true end

    local dx = player:getX() - x
    local dy = player:getY() - y
    return (dx * dx + dy * dy) <= (ZomboidFixesB42.MAX_REACH * ZomboidFixesB42.MAX_REACH)
end

local function parseItemIds(encoded)
    local ids = {}
    if type(encoded) ~= "string" then return ids end
    for field in string.gmatch(encoded, "([^,]+)") do
        local id = tonumber(field)
        if id then
            table.insert(ids, id)
            if #ids >= MAX_ITEMS_PER_COMMAND then break end
        end
    end
    return ids
end

--- Picking an item up off the ground.
local function moveFromGround(player, itemId, destContainer)
    local item, square = ZomboidFixesB42.findItemOnGround(player, itemId)
    if not item then return false end
    if not destContainer:isItemAllowed(item) or not destContainer:hasRoomFor(player, item) then return false end

    -- A floor container bound to the square the item is actually on. Vanilla does
    -- the same thing from TransactionProcessor.dropOnFloor, and transferItem's
    -- floor branch works off item:getWorldItem() rather than the container's
    -- contents, so a freshly built one is enough.
    local floorContainer = ItemContainer.new("floor", square, nil)

    local moved = ISTransferAction:transferItem(player, item, floorContainer, destContainer, nil)
    sendAddItemToContainer(destContainer, moved or item)
    return true
end

--- Putting an item down on the ground.
local function moveToGround(player, itemId, srcContainer)
    if not srcContainer:containsID(itemId) then return false end
    local item = srcContainer:getItemWithID(itemId)
    if not item then return false end

    local floorContainer = ItemContainer.new("floor", player:getCurrentSquare(), nil)

    -- Where there is actually room, checked the same way the single player path
    -- checks it: the player's square first, then the eight around it, each tested
    -- for a walkable floor, blocked or window transitions, stairs, and weight.
    local dropSquare = ISTransferAction:getNotFullFloorSquare(player, item, floorContainer)
    if not dropSquare then return false end

    -- No sendAddItemToContainer here: the floor branch of transferItem ends in
    -- AddWorldInventoryItem, which does the world replication itself.
    ISTransferAction:transferItem(player, item, srcContainer, floorContainer, dropSquare)
    return true
end

--- A container-to-container move, both ends real.
local function moveBetweenContainers(player, itemId, srcContainer, destContainer)
    -- Re-checked every iteration: an earlier item in this batch may have filled
    -- the destination up.
    if not srcContainer:containsID(itemId) then return false end

    local item = srcContainer:getItemWithID(itemId)
    if not item then return false end
    if not destContainer:isItemAllowed(item) or not destContainer:hasRoomFor(player, item) then return false end

    -- Vanilla's own server-side move. It handles worn and equipped items, vehicle
    -- part weights, item replacement and the remove half of the replication.
    local moved = ISTransferAction:transferItem(player, item, srcContainer, destContainer, nil)
    sendAddItemToContainer(destContainer, moved or item)
    return true
end

--- Tell the client we are done with a batch, and which items we would not move.
-- The client is waiting with setWaitForFinished(true), so a refusal it never hears
-- about would leave the action hanging until its lost-packet backstop expires.
local function replyToClient(player, token, failed)
    if not token then return end
    sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_TRANSFER_DECLINED, {
        token = token,
        failed = table.concat(failed, ","),
    })
end

--- Validate and move one batch now, then answer the client. Also used by fast
-- forward's timed transfers (ZomboidFixesB42_FastForwardTransfer.lua) once their
-- time is up.
local function moveBatch(player, args)
    local FLOOR = ZomboidFixesB42.FLOOR
    local fromGround = (args.src == FLOOR)
    local toGround = (args.dst == FLOOR)

    -- Ground to ground is not a transfer.
    if fromGround and toGround then return replyToClient(player, args.token, {}) end

    -- decodeContainer returns nil for the floor marker on purpose, so only the
    -- non-floor side is resolved here.
    local srcContainer = (not fromGround) and ZomboidFixesB42.decodeContainer(args.src, player) or nil
    local destContainer = (not toGround) and ZomboidFixesB42.decodeContainer(args.dst, player) or nil

    -- Every one of these is a refusal the client has to hear about, otherwise it
    -- sits waiting for a move that is never coming.
    if (not fromGround and not srcContainer) or (not toGround and not destContainer) then
        return replyToClient(player, args.token, parseItemIds(args.items))
    end
    if srcContainer and destContainer and srcContainer == destContainer then
        return replyToClient(player, args.token, parseItemIds(args.items))
    end
    if srcContainer and not isInReach(player, srcContainer) then
        return replyToClient(player, args.token, parseItemIds(args.items))
    end
    if destContainer and not isInReach(player, destContainer) then
        return replyToClient(player, args.token, parseItemIds(args.items))
    end

    local failed = {}

    for _, itemId in ipairs(parseItemIds(args.items)) do
        local moved
        if fromGround then
            moved = moveFromGround(player, itemId, destContainer)
        elseif toGround then
            moved = moveToGround(player, itemId, srcContainer)
        else
            moved = moveBetweenContainers(player, itemId, srcContainer, destContainer)
        end

        if not moved then
            table.insert(failed, tostring(itemId))
        end
    end

    replyToClient(player, args.token, failed)
end

ZomboidFixesB42.moveTransferBatch = moveBatch
ZomboidFixesB42.parseTransferItemIds = parseItemIds

local function onInstantTransfer(player, args)
    -- Answered rather than dropped: a client that took the fast path on a cheat
    -- flag the server disagrees about would otherwise hang on every transfer.
    if not isAllowed(player) then
        return replyToClient(player, args.token, parseItemIds(args.items))
    end
    moveBatch(player, args)
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_TRANSFER then return end
    onInstantTransfer(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
