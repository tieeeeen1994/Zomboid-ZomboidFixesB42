--[[
    Zomboid Fixes B42.20 -- server, telling a client where the items of a failed
    transfer really are

    A multiplayer transfer is a Java item transaction (zombie.core.TransactionManager,
    Transaction, ItemTransactionPacket; Vineflower decompile of 42.21). The server
    checks a Request once (isConsistent) and answers Accept or Reject, then at the
    end time runs Transaction.update. When that returns false or throws
    ("transaction.update() threw. Rejecting transaction" in the log) the state
    becomes Reject and NOTHING is sent: the client keeps waiting until its own
    timeout (the duration + 10 s, 20 s without one) drops the transaction, and
    since isItemTransactionDone then reads an empty list as done (allMatch), the
    transfer "finishes" having moved nothing. Entries already moved stay moved.

    That silence is how the two "the item is there / the item is not there until
    I relog" cases happen:

      - A ghost: the client shows a floor item the server does not have. Floor
        items are found by item ID; with none, isConsistent still accepts (source
        null, item ID -1 skips every check), the server logs "ERROR:
        sendItemsToContainer: can't find world item with id=N" and fails silently
        later. The ghost stays on the client's floor until the area reloads.
        Ghosts are born mostly by RemoveItemFromSquarePacket, which removes by the
        object's INDEX on the square, not its ID: a client whose object list on
        that square differs from the server's removes the wrong object, or none.
      - Hidden: the server moved the item, but the client never got the
        AddInventoryItemToContainer (the move threw part way, or the client could
        not find the bag it was addressed to). Only a relog, which rebuilds the
        inventory from the server's copy, shows it.

    The client (client/ZomboidFixesB42_TransferResync.lua) asks here when a
    transfer ends like that, or is refused, or runs well past its end, or a fast
    transfer is declined. For every item it names, this finds where the item
    really is -- the transfer's destination, its source, anywhere in the player's
    inventory, on the ground within reach, or nowhere -- and:

      - re-sends it (sendAddItemToContainer) to wherever the client does not show
        it; the client's AddInventoryItemToContainer skips an ID the container
        already holds, so this cannot duplicate anything;
      - answers with each item's place, so the client can drop its own stale
        copies (ghosts) and decide whether the transfer is over or worth retrying.

    Nothing here moves or creates an item. Every container looked at is one the
    client could open anyway (in reach), and the player's own inventory.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- A transfer batch is at most 20 items (checkQueueList); this only bounds a
-- tampered client.
local MAX_ITEMS = 25
-- Requests per player per window. A client asks at most a few times per batch.
local WINDOW_MS = 10000
local MAX_REQUESTS_PER_WINDOW = 30

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.TransferResync == true
end

local function isInReach(player, container)
    local x, y = ZomboidFixesB42.containerPosition(container)
    if not x then return true end
    local dx, dy = player:getX() - x, player:getY() - y
    return (dx * dx + dy * dy) <= (ZomboidFixesB42.MAX_REACH * ZomboidFixesB42.MAX_REACH)
end

--- A container the client named, if it resolves and is in reach. The floor
-- marker resolves to nil on purpose: floor items are found by ID.
local function resolve(player, encoded)
    if type(encoded) ~= "string" or encoded == "" then return nil end
    local container = ZomboidFixesB42.decodeContainer(encoded, player)
    if container and isInReach(player, container) then return container end
    return nil
end

local function idSet(encoded)
    local set = {}
    if type(encoded) ~= "string" then return set end
    for field in string.gmatch(encoded, "([^,]+)") do
        local id = tonumber(field)
        if id then set[id] = true end
    end
    return set
end

--- Where an item really is, from the transfer's point of view: "dst", "src",
-- "inv" (elsewhere in the player's inventory), "floor" (on the ground in reach)
-- or "none". Returns the place, the item and the container holding it.
function ZomboidFixesB42.locateTransferItem(player, id, src, dst, hint)
    if dst then
        local item = dst:getItemWithID(id)
        if item then return "dst", item, dst end
    end
    if src then
        local item = src:getItemWithID(id)
        if item then return "src", item, src end
    end
    local item = ZomboidFixesB42.findItemById(player:getInventory(), id)
    if item then return "inv", item, item:getContainer() end
    item = ZomboidFixesB42.findItemOnGroundNear(player, id, hint)
    if item then return "floor", item, nil end
    return "none", nil, nil
end

-- [username] = { windowStart, count }
local recent = {}

local function allowRequest(player)
    local now = getTimestampMs()
    local key = player:getUsername() or tostring(player:getOnlineID())
    local entry = recent[key]
    if not entry or now - entry.windowStart > WINDOW_MS then
        entry = { windowStart = now, count = 0 }
        recent[key] = entry
    end
    entry.count = entry.count + 1
    return entry.count <= MAX_REQUESTS_PER_WINDOW
end

local function onResync(player, args)
    if not isEnabled() or not player or player:isDead() then return end
    if not allowRequest(player) then return end

    local token = type(args.token) == "string" and args.token or nil
    local reason = type(args.reason) == "string" and string.sub(args.reason, 1, 16) or "?"
    local src = resolve(player, args.src)
    local dst = resolve(player, args.dst)
    local hints = ZomboidFixesB42.parseFloorHints(args.floor)
    local held = idSet(args.held)
    local inSrc = idSet(args.inSrc)
    local inDst = idSet(args.inDst)
    local inventory = player:getInventory()

    local results = {}
    local repairs = {}
    local count = 0
    for field in string.gmatch(type(args.items) == "string" and args.items or "", "([^,]+)") do
        local id = tonumber(field)
        if id then
            count = count + 1
            if count > MAX_ITEMS then break end

            local place, item, container = ZomboidFixesB42.locateTransferItem(player, id, src, dst, hints[id])
            table.insert(results, tostring(id) .. ":" .. place)

            -- Re-send it where the client does not show it. For the player's own
            -- inventory tree "does not show it" means anywhere in it: the client's
            -- dupe check only covers the one container, so re-sending an item the
            -- client holds in another bag would show it twice.
            if item and container then
                local carried = container == inventory or container:isInCharacterInventory(player)
                local shown
                if carried then
                    shown = held[id]
                elseif place == "src" then
                    shown = inSrc[id]
                else
                    shown = inDst[id]
                end
                if not shown then
                    sendAddItemToContainer(container, item)
                    table.insert(repairs, string.format("%d %s re-sent (%s)", id, item:getFullType(), place))
                end
            end
            if place ~= "floor" and hints[id] then
                table.insert(repairs, string.format("%d on the player's floor but not the server's (%s)", id, place))
            elseif place ~= "src" and inSrc[id] then
                table.insert(repairs, string.format("%d in the player's source container but not the server's (%s)", id, place))
            end
        end
    end

    if #repairs > 0 then
        print(string.format("[ZomboidFixesB42] Transfer resync for %s (%s): %s",
            tostring(player:getUsername()), reason, table.concat(repairs, "; ")))
    end

    sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_TRANSFER_RESYNC_RESULT, {
        token = token,
        results = table.concat(results, ","),
    })
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_TRANSFER_RESYNC then return end
    onResync(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
