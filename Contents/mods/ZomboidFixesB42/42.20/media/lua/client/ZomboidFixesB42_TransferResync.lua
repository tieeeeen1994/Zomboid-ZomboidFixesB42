--[[
    Zomboid Fixes B42.20 -- client, item transfers that fail without a word

    The server half, and the Java behind it, is in
    server/ZomboidFixesB42_TransferResync.lua. In short: when the server's end of
    a transfer fails, it tells the client nothing. The client's copy of the
    transaction times out (the duration + 10 s, or 20 s), and vanilla's
    ISInventoryTransferAction:update then reads isItemTransactionDone as true --
    an empty list "all match" -- so the bar hangs, then the action ends having
    moved nothing. Two things the player sees come out of that:

      - an item on the floor that cannot be picked up, and is gone after a relog
        (a ghost: only the client has it);
      - an item that vanished while being picked up and is in the inventory after
        a relog (the server moved it, the client was never told).

    How a transfer's state reads from Lua (TransactionManager.isDone / isRejected
    over the client's list; both are true for an ID no longer in it):

        done and rejected     gone from the list: timed out (or removed by us)
        rejected only         the server refused it (Reject packet)
        done only             the server finished it (Done packet)
        neither               still waiting

    This file watches every vanilla transaction of ISInventoryTransferAction and
    ISGrabItemAction and asks the server where the items really are
    (ZomboidFixesB42.resyncTransfer) when:

      - "late": the transfer is LATE_GRACE_MS past the end the server gave it.
        If the server has already moved the items (or they are nowhere), the
        transfer ends there instead of hanging for another 10 s.
      - "lost": the transfer timed out. It is held open (isItemTransactionDone /
        isItemTransactionRejected report "waiting" for it) until the answer: if
        the items are still at the source on the server, the batch is sent again,
        once; otherwise it ends as vanilla would.
      - "refused": the server rejected it. Held the same way: if every item turns
        out to be a ghost or already moved, the action carries on with its next
        batch instead of stopping the whole transfer; if not, it stops as vanilla.
      - a grab from the ground (ISGrabItemAction) finishes by its timer, not by
        the server, so it is checked GRAB_CHECK_MS after it ends, and only if the
        item is not in the inventory by then.

    With the answer the server re-sends anything the client does not show, and
    this drops the client's stale copies: world items the server does not have
    on the ground, and items in a world or vehicle container the server does not
    have there. Never from the player's own inventory.

    Also: an item that has arrived in the inventory while a world item with the
    same ID is still on the client's floor is a ghost left by the index-based
    removal, and is dropped at once (clearGhostsOf). And a transfer stopped after
    its server side is over is not cancelled on the server (cancelQuietly).

    Multiplayer only. Single player moves items itself and never waits on a server.
--]]

if not isClient() then return end

require "TimedActions/ISInventoryTransferAction"
require "TimedActions/ISGrabItemAction"
require "ZomboidFixesB42_Transfer"

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- How long past the server's end of a transfer before asking. The Done packet
-- normally arrives within a round trip of it.
local LATE_GRACE_MS = 2500
-- Longest a timed-out or refused transfer is held open for the server's answer.
local HOLD_MS = 5000
-- Once the server says the items are at the destination, how long to wait for
-- them to show up before the transfer is let go anyway.
local ARRIVAL_WAIT_MS = 3000
-- A grab ends on its own timer; this is how long after that it is checked.
local GRAB_CHECK_MS = 3000
-- Requests with no answer are forgotten after this.
local REQUEST_TTL_MS = 30000

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.TransferResync == true
end

local vanillaIsDone = isItemTransactionDone
local vanillaIsRejected = isItemTransactionRejected
local vanillaRemove = removeItemTransaction

-- Transactions held open while their answer is on its way: [id] = until (ms).
-- The expiry matters: IDs are one byte, numbered per client, and come round again.
local holding = {}

local function isHeld(id)
    local untilMs = id and holding[id]
    if not untilMs then return false end
    if getTimestampMs() <= untilMs then return true end
    holding[id] = nil
    return false
end

function isItemTransactionDone(id)
    if isHeld(id) then return false end
    return vanillaIsDone(id)
end

function isItemTransactionRejected(id)
    if isHeld(id) then return false end
    return vanillaIsRejected(id)
end

--- Is this container the ground? A grab's source is an "object" container whose
-- parent is the world item itself.
local function isFloorContainer(container)
    if not container then return false end
    if container:getType() == "floor" then return true end
    return instanceof(container:getParent(), "IsoWorldInventoryObject")
end

local function isCarried(container, character)
    return container == character:getInventory() or container:isInCharacterInventory(character)
end

local function squaresAround(character, hint)
    local squares = {}
    local cell = getCell()
    if hint then
        local square = cell:getGridSquare(hint.x, hint.y, hint.z)
        if square then table.insert(squares, square) end
    end
    local px, py, pz = math.floor(character:getX()), math.floor(character:getY()), math.floor(character:getZ())
    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = cell:getGridSquare(px + dx, py + dy, pz)
            if square then table.insert(squares, square) end
        end
    end
    return squares
end

--- Drop the client's own world item(s) with this ID, if it shows any around the
-- player (or on the hinted square). Local only: IsoGridSquare.removeWorldObject
-- sends nothing. Returns true if one was dropped.
local function removeLocalWorldItem(character, id, hint)
    local removed = false
    for _, square in ipairs(squaresAround(character, hint)) do
        local worldObjects = square:getWorldObjects()
        for i = worldObjects:size() - 1, 0, -1 do
            local worldObject = worldObjects:get(i)
            local item = worldObject and worldObject:getItem()
            if item and item:getID() == id then
                square:removeWorldObject(worldObject)
                item:setWorldItem(nil)
                removed = true
            end
        end
    end
    return removed
end

local function hasLocalWorldItem(character, id, hint)
    for _, square in ipairs(squaresAround(character, hint)) do
        local worldObjects = square:getWorldObjects()
        for i = 0, worldObjects:size() - 1 do
            local item = worldObjects:get(i) and worldObjects:get(i):getItem()
            if item and item:getID() == id then return true end
        end
    end
    return false
end

--- Items that have arrived in the character's inventory but are still lying on
-- the client's floor: the server removed them from the ground (its removal comes
-- before the item on the same ordered channel), so what is left is a ghost.
function ZomboidFixesB42.clearGhostsOf(character, items)
    if not isEnabled() or not character then return end
    local inventory = character:getInventory()
    local any = false
    for _, item in ipairs(items or {}) do
        local id = item:getID()
        if ZomboidFixesB42.findItemById(inventory, id) and removeLocalWorldItem(character, id, nil) then
            any = true
        end
    end
    if any then ISInventoryPage.renderDirty = true end
end

-- Asked and not answered yet: [token] = request.
local requests = {}
local nextToken = 0

local function forgetOldRequests(now)
    for token, request in pairs(requests) do
        if now - request.sentMs > REQUEST_TTL_MS then requests[token] = nil end
    end
end

--- Ask the server where these items really are. src and dst are the transfer's
-- containers (either may be nil). callback(results), if given, gets
-- { [itemId] = "dst" | "src" | "inv" | "floor" | "none" } after the client's
-- stale copies have been dropped. Returns true if the question was sent.
function ZomboidFixesB42.resyncTransfer(character, items, src, dst, reason, callback)
    if not isEnabled() or not character or not items or #items == 0 then return false end

    local now = getTimestampMs()
    forgetOldRequests(now)

    local inventory = character:getInventory()
    local srcFloor, dstFloor = isFloorContainer(src), isFloorContainer(dst)
    local ids, held, inSrc, inDst = {}, {}, {}, {}
    for _, item in ipairs(items) do
        local id = tostring(item:getID())
        table.insert(ids, id)
        if ZomboidFixesB42.findItemById(inventory, item:getID()) then table.insert(held, id) end
        if src and not srcFloor and src:containsID(item:getID()) then table.insert(inSrc, id) end
        if dst and not dstFloor and dst:containsID(item:getID()) then table.insert(inDst, id) end
    end

    local FLOOR = ZomboidFixesB42.FLOOR
    local srcCode = srcFloor and FLOOR or (src and ZomboidFixesB42.encodeContainer(src, character)) or ""
    local dstCode = dstFloor and FLOOR or (dst and ZomboidFixesB42.encodeContainer(dst, character)) or ""
    local floor = ZomboidFixesB42.encodeFloorHints(items)

    nextToken = nextToken + 1
    local token = tostring(nextToken)
    requests[token] = {
        character = character, items = items, src = src, dst = dst,
        srcFloor = srcFloor, dstFloor = dstFloor,
        hints = ZomboidFixesB42.parseFloorHints(floor),
        callback = callback, sentMs = now,
    }

    sendClientCommand(character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_TRANSFER_RESYNC, {
        token = token, reason = reason,
        src = srcCode, dst = dstCode,
        items = table.concat(ids, ","),
        held = table.concat(held, ","),
        inSrc = table.concat(inSrc, ","),
        inDst = table.concat(inDst, ","),
        floor = floor,
    })
    return true
end

--- Drop what the client shows that the server does not have.
local function reconcile(request, results)
    local character = request.character
    local any = false
    for _, item in ipairs(request.items) do
        local id = item:getID()
        local place = results[id]
        if place then
            if place ~= "floor" and removeLocalWorldItem(character, id, request.hints[id]) then
                any = true
            end
            for _, side in ipairs({ { request.src, request.srcFloor, "src" }, { request.dst, request.dstFloor, "dst" } }) do
                local container, floor, name = side[1], side[2], side[3]
                if container and not floor and place ~= name and not isCarried(container, character) then
                    local stale = container:getItemWithID(id)
                    if stale then
                        container:DoRemoveItem(stale)
                        any = true
                    end
                end
            end
        end
    end
    if any then
        ISInventoryPage.renderDirty = true
        print("[ZomboidFixesB42] Dropped items the server does not have after a failed transfer")
    end
end

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_TRANSFER_RESYNC_RESULT then return end
    if type(args) ~= "table" then return end
    local token = tostring(args.token)
    local request = requests[token]
    if not request then return end
    requests[token] = nil

    local results = {}
    if type(args.results) == "string" then
        for id, place in string.gmatch(args.results, "(-?%d+):(%a+)") do
            results[tonumber(id)] = place
        end
    end

    reconcile(request, results)
    if request.callback then request.callback(results) end
end

Events.OnServerCommand.Add(onServerCommand)

--[[ Watching a transfer's transaction -------------------------------------------

    Per action, self.zfixRs = the batch being watched:
      id          its transaction
      items       its items, as they were when it opened
      since       when it was first seen
      retried     sent again once already
      asked       "late" already asked
      holdUntil   held open for an answer until then
      release     { untilMs, ids } -- answered, waiting for these to arrive
      finished    nothing more to do for it
--]]

local function atDestination(batch, place)
    if place == "dst" or place == "none" then return true end
    return batch.dstFloor and place == "floor"
end

local function atSource(batch, place)
    if place == "src" then return true end
    return batch.srcFloor and place == "floor"
end

--- Does the client still show this item where the transfer takes it from?
local function stillAtSourceLocally(batch, character, item)
    if batch.srcFloor then return hasLocalWorldItem(character, item:getID(), nil) end
    return batch.src ~= nil and batch.src:containsID(item:getID())
end

local function releaseHold(batch)
    holding[batch.id] = nil
    batch.holdUntil = nil
end

--- End the batch here: its transaction is dropped locally (no Reject is sent to
-- the server, see removeItemTransaction(id, true) in CLAUDE.md), so vanilla's
-- next check reads it as done and completes the action.
local function finishBatch(batch)
    releaseHold(batch)
    batch.release = nil
    batch.finished = true
    batch.selfRemoved = true
    vanillaRemove(batch.id, false)
end

--- What to do with the answer for a batch held open (timed out or refused).
local function onHeldAnswer(self, batch, spec, results)
    if self.zfixRs ~= batch or not batch.holdUntil then return end
    batch.answered = true

    local retry, allDone = {}, true
    for _, item in ipairs(batch.items) do
        local place = results[item:getID()]
        if not place or not atDestination(batch, place) then allDone = false end
        if place and atSource(batch, place) and stillAtSourceLocally(batch, self.character, item) then
            table.insert(retry, item)
        end
    end

    if allDone then
        -- Every item is where the transfer was taking it, or a ghost now gone:
        -- over, successfully as far as anyone can tell. Carries on with the next
        -- batch even after a refusal.
        return finishBatch(batch)
    end

    if batch.timedOut and #retry > 0 and not batch.retried and spec.reopen then
        -- The server did nothing with it (its transaction failed or was dropped)
        -- and the items are still there: send it once more.
        releaseHold(batch)
        batch.finished = true
        local id = spec.reopen(self, retry)
        if id and id ~= 0 then
            self.zfixRsRetryId = id
        end
        return
    end

    -- Vanilla takes it from here: a timeout completes, a refusal stops.
    releaseHold(batch)
    batch.finished = true
end

local function hold(self, batch, spec, reason)
    batch.holdUntil = getTimestampMs() + HOLD_MS
    holding[batch.id] = batch.holdUntil
    local sent = ZomboidFixesB42.resyncTransfer(self.character, batch.items, batch.src, batch.dst, reason,
        function(results) onHeldAnswer(self, batch, spec, results) end)
    if not sent then
        releaseHold(batch)
        batch.finished = true
    end
end

local function onLateAnswer(self, batch, results)
    if self.zfixRs ~= batch or batch.finished then return end
    batch.answered = true
    local ids = {}
    for _, item in ipairs(batch.items) do
        local place = results[item:getID()]
        if not place or not atDestination(batch, place) then return end
        if place == "dst" then table.insert(ids, item:getID()) end
    end
    -- Already moved, the Done just never came. Wait for the items themselves,
    -- which a follow-up action (eating out of a bag) will look for.
    batch.release = { untilMs = getTimestampMs() + ARRIVAL_WAIT_MS, ids = ids }
end

local function arrived(batch)
    local dst = batch.dst
    if not dst or batch.dstFloor then return true end
    for _, id in ipairs(batch.release.ids) do
        if not dst:containsID(id) then return false end
    end
    return true
end

--- Called before every update of a watched action.
local function watch(self, spec)
    if not isEnabled() then return end
    local id = self.transactionId
    if not id or id == 0 then return end

    local now = getTimestampMs()
    local batch = self.zfixRs
    if not batch or batch.id ~= id then
        local src, dst = spec.containers(self)
        batch = {
            id = id, items = spec.items(self), since = now,
            src = src, dst = dst, srcFloor = isFloorContainer(src), dstFloor = isFloorContainer(dst),
            retried = self.zfixRsRetryId == id,
        }
        self.zfixRs = batch
    end
    if batch.finished then return end

    if batch.holdUntil then
        if now > batch.holdUntil then
            releaseHold(batch)
            batch.finished = true
        end
        return
    end

    if batch.release then
        if arrived(batch) or now > batch.release.untilMs then finishBatch(batch) end
        return
    end

    local done, rejected = vanillaIsDone(id), vanillaIsRejected(id)
    if done and rejected then
        if batch.selfRemoved then batch.finished = true return end
        batch.timedOut = true
        return hold(self, batch, spec, "lost")
    elseif rejected then
        return hold(self, batch, spec, "refused")
    elseif done then
        batch.finished = true
        if batch.srcFloor and not batch.dstFloor then
            ZomboidFixesB42.clearGhostsOf(self.character, batch.items)
        end
        return
    end

    if not batch.asked then
        local units = getItemTransactionDuration(id) or 0
        if now > batch.since + units * 20 + LATE_GRACE_MS then
            batch.asked = true
            ZomboidFixesB42.resyncTransfer(self.character, batch.items, batch.src, batch.dst, "late",
                function(results) onLateAnswer(self, batch, results) end)
        end
    end
end

local function stopWatching(self)
    local batch = self.zfixRs
    if batch then
        releaseHold(batch)
        batch.finished = true
    end
end

--- Before vanilla's stop cancels the transaction: a cancel sends Reject, and the
-- server applies a Reject with removeIf(id == id) over every player's
-- transactions (TransactionManager.removeItemTransaction), while IDs are one byte
-- numbered by each client. So a cancel can drop another player's transfer in
-- flight. It is only needed while the server may still move the items; once the
-- transaction is done, refused or gone, it is dropped here without a word.
local function cancelQuietly(self)
    if not isEnabled() then return end
    local id = self.transactionId
    if id and id ~= 0 and (vanillaIsDone(id) or vanillaIsRejected(id)) then
        vanillaRemove(id, false)
        self.transactionId = 0
    end
end

-- ISInventoryTransferAction: a batch is queueList[1] from the moment its
-- transaction opens (start, or perform for the next one) until perform takes it.
local transferSpec = {
    items = function(self)
        local batch = self.queueList and self.queueList[1]
        local items = {}
        for _, item in ipairs((batch and batch.items) or { self.item }) do table.insert(items, item) end
        return items
    end,
    containers = function(self) return self.srcContainer, self.destContainer end,
    reopen = function(self, items)
        self.transactionId = createItemTransaction(self.character, items, self.srcContainer, self.destContainer)
        return self.transactionId
    end,
}

local previousTransferUpdate = ISInventoryTransferAction.update
function ISInventoryTransferAction:update()
    watch(self, transferSpec)
    return previousTransferUpdate(self)
end

local previousTransferStop = ISInventoryTransferAction.stop
function ISInventoryTransferAction:stop()
    stopWatching(self)
    cancelQuietly(self)
    return previousTransferStop(self)
end

-- ISGrabItemAction: one world item per transaction (createItemTransaction with
-- nil items takes the source container's own world item).
local function grabbedItem(self)
    local worldObject = self.sourceContainer and self.sourceContainer:getParent()
    if worldObject and instanceof(worldObject, "IsoWorldInventoryObject") then
        return worldObject:getItem()
    end
    return self.item and self.item:getItem()
end

local grabSpec = {
    items = function(self)
        local item = grabbedItem(self)
        return item and { item } or {}
    end,
    containers = function(self) return self.sourceContainer, self.destContainer end,
    reopen = function(self)
        self.transactionId = createItemTransaction(self.character, nil, self.sourceContainer, self.destContainer)
        return self.transactionId
    end,
}

local previousGrabUpdate = ISGrabItemAction.update
function ISGrabItemAction:update()
    watch(self, grabSpec)
    return previousGrabUpdate(self)
end

local previousGrabStop = ISGrabItemAction.stop
function ISGrabItemAction:stop()
    stopWatching(self)
    cancelQuietly(self)
    return previousGrabStop(self)
end

--[[ Grabs that end on their timer --------------------------------------------

    ISGrabItemAction never waits on the server: once the server's duration is
    known it becomes the action's time, and perform -> transferItem drops the
    transaction and ends the action, whatever the server did. So the check comes
    GRAB_CHECK_MS later: an item now in the inventory is fine (a copy still on the
    floor is a ghost and dropped), one that is not is asked about.
--]]
local grabChecks = {}

local previousGrabTransfer = ISGrabItemAction.transferItem
function ISGrabItemAction:transferItem(item)
    local batch = self.zfixRs
    local answered = batch and batch.id == self.transactionId and batch.answered
    if isEnabled() and self.transactionId and self.transactionId ~= 0 and self.zfixRsCheckedId ~= self.transactionId then
        self.zfixRsCheckedId = self.transactionId
        local grabbed = grabbedItem(self)
        -- Already asked about while the grab was running: nothing more to learn.
        if grabbed and answered then
            stopWatching(self)
        elseif grabbed then
            stopWatching(self)
            table.insert(grabChecks, {
                character = self.character, item = grabbed, dst = self.destContainer,
                atMs = getTimestampMs() + GRAB_CHECK_MS,
            })
        end
    end
    return previousGrabTransfer(self, item)
end

local function onTick()
    if #grabChecks == 0 then return end
    local now = getTimestampMs()
    for i = #grabChecks, 1, -1 do
        local check = grabChecks[i]
        if now >= check.atMs then
            table.remove(grabChecks, i)
            local id = check.item:getID()
            if ZomboidFixesB42.findItemById(check.character:getInventory(), id) then
                ZomboidFixesB42.clearGhostsOf(check.character, { check.item })
            else
                local src = ItemContainer.new("floor", nil, nil)
                ZomboidFixesB42.resyncTransfer(check.character, { check.item }, src, check.dst, "grab")
            end
        end
    end
end

Events.OnTick.Add(onTick)
