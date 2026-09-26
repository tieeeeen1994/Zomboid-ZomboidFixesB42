--[[
    Zomboid Fixes B42.20 -- server, item transfers keep pace with fast forward

    A transfer in multiplayer is not a timed action the server runs: the client opens
    an item transaction (createItemTransaction), and the server's
    zombie.core.Transaction fixes its end when it arrives,

        endTime = startTime + getDuration()      -- real milliseconds, 20 per unit

    and TransactionManager.update moves the items once GameTime.getServerTimeMills()
    passes it. Nothing in that reads the game speed, so looting takes the same real
    time at 40x as at 1x. The transactions live in TransactionManager's private list
    and every Lua global that touches them (createItemTransaction, isItemTransactionDone,
    getItemTransactionDuration...) does nothing outside a client, so a running one
    cannot be shortened.

    So while fast forward runs, the client sends each new batch here instead of
    opening a transaction (client/ZomboidFixesB42_Transfer.lua). The batch waits the
    same length vanilla would give it (ZomboidFixesB42.transferUnits, the formula of
    Transaction.getDuration), counted at the running speed and re-counted when the
    speed changes, the way the timed actions are. Then it is moved by the same code as
    the instant transfer cheat (ZomboidFixesB42.moveTransferBatch), which checks again,
    at that moment, that the item is still in the source, that the destination takes it
    and has room, and that the player is in reach. Vanilla's server has no more checks
    than that (TransactionManager.isConsistent; safehouses are only checked on the
    client, and still are). At normal speed a batch takes exactly vanilla's time, so
    the path gives nothing a vanilla client does not have.

    A batch started before fast forward is a Java transaction and finishes at normal
    speed; every batch after it follows the speed.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- A Lua duration unit is 20 ms of real time (Transaction.getDuration, NetTimedAction).
local MS_PER_UNIT = 20
-- A client only ever has one batch waiting per action; this only bounds a tampered one.
local MAX_PENDING_PER_PLAYER = 8

-- { player, token, args, totalMs, doneMs, lastMs }
local pending = {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MultiplayerFastForward == true
end

local function speed()
    return ZomboidFixesB42.fastForwardSpeed or 1
end

local function reply(player, token, failedIds)
    sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_TRANSFER_DECLINED, {
        token = token,
        failed = table.concat(failedIds, ","),
    })
end

--- Vanilla's length for this batch at normal speed, in ms: its slowest item.
local function batchMs(player, args)
    local FLOOR = ZomboidFixesB42.FLOOR
    local square = player:getCurrentSquare()
    local src, dst
    if args.src == FLOOR then
        src = ItemContainer.new("floor", square, nil)
    else
        src = ZomboidFixesB42.decodeContainer(args.src, player)
    end
    if args.dst == FLOOR then
        dst = ItemContainer.new("floor", square, nil)
    else
        dst = ZomboidFixesB42.decodeContainer(args.dst, player)
    end
    if not src or not dst then return 0 end

    local units = 0
    for _, id in ipairs(ZomboidFixesB42.parseTransferItemIds(args.items)) do
        local item
        if args.src == FLOOR then
            item = ZomboidFixesB42.findItemOnGround(player, id)
        else
            item = src:getItemWithID(id)
        end
        if item then
            units = math.max(units, ZomboidFixesB42.transferUnits(player, item, src, dst))
        end
    end
    return units * MS_PER_UNIT
end

local function onTimedTransfer(player, args)
    local token = type(args.token) == "string" and args.token or nil
    if not token then return end
    if not isEnabled() or player:isDead() or not ZomboidFixesB42.moveTransferBatch then
        return reply(player, token, ZomboidFixesB42.parseTransferItemIds(args.items))
    end

    local count = 0
    for _, entry in ipairs(pending) do
        if entry.player == player then count = count + 1 end
    end
    if count >= MAX_PENDING_PER_PLAYER then
        return reply(player, token, ZomboidFixesB42.parseTransferItemIds(args.items))
    end

    local now = getTimestampMs()
    table.insert(pending, {
        player = player, token = token, args = args,
        totalMs = batchMs(player, args), doneMs = 0, lastMs = now,
    })
end

local function onCancel(player, args)
    local token = args.token
    for i = #pending, 1, -1 do
        local entry = pending[i]
        if entry.player == player and entry.token == token then
            table.remove(pending, i)
        end
    end
end

local function onTick()
    if #pending == 0 then return end
    local now = getTimestampMs()
    local running = speed()
    local due = {}
    for i = #pending, 1, -1 do
        local entry = pending[i]
        entry.doneMs = entry.doneMs + (now - entry.lastMs) * running
        entry.lastMs = now
        local player = entry.player
        if player:isDead() or not player:isExistInTheWorld() then
            table.remove(pending, i)
        elseif entry.doneMs >= entry.totalMs then
            table.remove(pending, i)
            table.insert(due, 1, entry)
        end
    end
    for _, entry in ipairs(due) do
        ZomboidFixesB42.moveTransferBatch(entry.player, entry.args)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or not player then return end
    if command == ZomboidFixesB42.CMD_TRANSFER_TIMED then
        onTimedTransfer(player, args or {})
    elseif command == ZomboidFixesB42.CMD_TRANSFER_TIMED_CANCEL then
        onCancel(player, args or {})
    end
end

Events.OnTick.Add(onTick)
Events.OnClientCommand.Add(onClientCommand)
