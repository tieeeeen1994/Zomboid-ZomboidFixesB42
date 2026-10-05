--[[
    Zomboid Fixes B42.20 -- client, item transfers

    Takes item transfers off the server-authoritative transaction path when the
    player has the instant timed action cheat, so they are not held at the full
    transfer time the server would otherwise impose. See
    shared/ZomboidFixesB42.lua for why this is necessary.

    Like single player. Under the cheat single player gives every transfer
    maxTime = 1 (ISInventoryTransferAction:new), so it is over in a tick and no
    progress bar is ever seen. These do the same, maxTime
    ZomboidFixesB42.TRANSFER_MAX_TIME with the progress bar turned off
    (useProgressBar, as ISPetAnimal and the hotbar actions do). Batching is not
    lost: vanilla holds the first transfer back for CLIENT_DELAY_FOR_MULTI_TRANSACTION
    (waitToStart), so by start() a whole shift-click is queued and
    checkQueueList() merges it.

    It cannot stop being a timed action altogether. The queue is what orders it
    after the walk to the container and before whatever was queued behind it --
    eating, equipping, a recipe -- and those expect the item to be there.

    The action must not finish until the item has really moved. This is why vanilla
    sets setWaitForFinished(true) and waits on isItemTransactionDone: a queued
    follow-up action expects to find the item where the transfer put it. Eating out
    of a bag queues a transfer and then ISEatFoodAction, whose isValid() does

        if self.character:getInventory():containsID(self.item:getID()) then ...
        else self:forceComplete(); return false end

    so completing the transfer early -- before the server's move has come back --
    cancels the meal. The item is moved by the server, never locally, so the wait is
    unavoidable; what this does instead is replace the transaction as the completion
    signal with the item actually arriving. So a transfer takes one round trip to
    the server, with no bar, instead of the full vanilla transfer time.

    Grabbing from the ground (ISGrabItemAction: the world context menu's Grab, a
    build cursor picking up materials, foraging and search mode icons) is its own
    action with its own transaction, timed by the same Java Transaction.getDuration
    that never reads the cheat, so it is taken off the transaction the same way
    (see "Grabbing from the ground" at the end of this file).

    Everything here is opt-in per action: if the FastTransfers sandbox option is
    off, or the containers involved cannot be addressed over the wire, zfixFast is
    never set and the action runs exactly as vanilla does today.
--]]

require "TimedActions/ISInventoryTransferAction"
require "TimedActions/ISGrabItemAction"

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- Last resort only. The server tells us when it declines a move (see
-- CMD_TRANSFER_DECLINED below), so the ordinary failure path resolves in one round
-- trip and never reaches this. What is left is a genuinely lost packet, where
-- without a backstop the action would wait forever with setWaitForFinished(true)
-- and jam every action queued behind it -- and stopOnWalk is false for
-- inventory-to-inventory moves, so the player could not even walk out of it.
-- On expiry the action completes rather than stops, so anything behind it fails its
-- own validation normally instead of being cancelled wholesale.
local LOST_PACKET_TIMEOUT_MS = 10000

-- Actions currently waiting on the server, by token, so a decline can find the one
-- it belongs to. Split screen can have more than one in flight.
local waitingByToken = {}
local nextToken = 0

local vanilla = {
    new     = ISInventoryTransferAction.new,
    start   = ISInventoryTransferAction.start,
    update  = ISInventoryTransferAction.update,
    perform = ISInventoryTransferAction.perform,
}

--- Can this transfer be done the fast way?
-- Deliberately isTimedActionInstantCheat() and not isTimedActionInstant(): the
-- latter also returns true for Core.debug plus the instant timed-action debug
-- option, which is a purely local state the server knows nothing about. Taking the
-- fast path on that basis means the server refuses the move and the action waits
-- for something that is never coming. This is the same flag the server checks, and
-- it is the one the admin panel toggles.
local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.FastTransfers == true
end

local function wantsFastTransfer(character)
    if not isClient() or character == nil or not isEnabled() then return false end
    return character:isTimedActionInstantCheat() and not character:isAccessLevel("None")
end

--- Stop waiting on a batch, releasing its slot in the token registry.
local function forgetBatch(self)
    if self.zfixToken then
        waitingByToken[self.zfixToken] = nil
        self.zfixToken = nil
    end
    self.zfixPending = nil
    self.zfixSentMs = nil
    self.zfixDeadlineMs = nil
    self.zfixAcked = false
end

--- Ask the server to move one batch of items, and start waiting for it. command is
-- CMD_TRANSFER (move now, the cheat) unless given (CMD_TRANSFER_TIMED, fast forward).
local function sendBatch(self, queuedItem, command)
    local items = (queuedItem and queuedItem.items) or { self.item }

    local ids = {}
    for _, item in ipairs(items) do
        table.insert(ids, tostring(item:getID()))
    end

    forgetBatch(self)

    nextToken = nextToken + 1
    self.zfixToken = tostring(nextToken)
    self.zfixPending = items
    self.zfixSentMs = getTimestampMs()
    self.zfixAcked = false
    self.zfixCompleted = false
    waitingByToken[self.zfixToken] = self

    -- Nothing to ask for. The action is waiting on setWaitForFinished, so it has
    -- to be let go rather than left hanging: an empty pending list plus a
    -- pretended acknowledgement reads as done and update() completes it next tick.
    if #ids == 0 then
        self.zfixPending = {}
        self.zfixAcked = true
        return
    end

    sendClientCommand(self.character, ZomboidFixesB42.MODULE, command or ZomboidFixesB42.CMD_TRANSFER, {
        token = self.zfixToken,
        src = self.zfixSrc,
        dst = self.zfixDst,
        items = table.concat(ids, ","),
        -- Which square each floor item lies on; see "Floor hints" in the shared file.
        floor = ZomboidFixesB42.encodeFloorHints(items),
    })
end

--- Does the client still show this item where the batch takes it from?
local function stillAtSource(action, item)
    if action.zfixSrc == ZomboidFixesB42.FLOOR then return item:getWorldItem() ~= nil end
    return action.srcContainer ~= nil and action.srcContainer:containsID(item:getID())
end

--- The declined items, once we know where they really are. Ones the server has
-- at the destination after all are waited for; ones still at the source go the
-- vanilla way (fallBackToVanilla), which is what worked with the cheat off;
-- ghosts (nowhere on the server) were dropped by the resync and are let go.
-- Without an answer (resync off), everything the client still shows at the
-- source goes the vanilla way.
local function settleDeclined(action, token, items, results)
    if action.zfixToken ~= token or not action.zfixPending then return end
    local FLOOR = ZomboidFixesB42.FLOOR
    local fallback = {}
    for _, item in ipairs(items) do
        local place = results and results[item:getID()]
        if place == "dst" or (place == "floor" and action.zfixDst == FLOOR) then
            table.insert(action.zfixPending, item)
        elseif (not results or place == "src" or (place == "floor" and action.zfixSrc == FLOOR))
                and stillAtSource(action, item) then
            table.insert(fallback, item)
        end
    end
    if #fallback > 0 then action.zfixFallback = fallback end
    action.zfixAcked = true
end

--- The server has finished with a batch and says which items it would not move.
-- This only ever shrinks what is being waited on, and never completes a
-- container-bound transfer by itself: sendServerCommand and the item packets are
-- different packet types with no ordering between them, so treating the reply as
-- "done" could finish the action before the item had actually arrived -- the very
-- thing that was cancelling meals.
local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_TRANSFER_DECLINED then return end
    if type(args) ~= "table" then return end

    local action = waitingByToken[tostring(args.token)]
    if not action or not action.zfixPending then return end

    -- Counted by hand: Kahlua does not provide next(), so the usual
    -- "is this table empty" idiom fails at runtime.
    local declined = {}
    local anyDeclined = false
    if type(args.failed) == "string" then
        for id in string.gmatch(args.failed, "([^,]+)") do
            declined[tonumber(id) or -1] = true
            anyDeclined = true
        end
    end

    if anyDeclined then
        local keep, refused = {}, {}
        for _, item in ipairs(action.zfixPending) do
            if declined[item:getID()] then
                table.insert(refused, item)
            else
                table.insert(keep, item)
            end
        end
        action.zfixPending = keep

        -- A declined item used to be dropped from the batch, which then finished
        -- having moved nothing: the transfer silently did not happen, and worked
        -- with the cheat off. Now we first ask where each one really is
        -- (client/ZomboidFixesB42_TransferResync.lua), then settle them.
        if #refused > 0 then
            local token = action.zfixToken
            local resync = ZomboidFixesB42.resyncTransfer
            if resync and resync(action.character, refused, action.srcContainer, action.destContainer, "declined",
                    function(results) settleDeclined(action, token, refused, results) end) then
                return
            end
            return settleDeclined(action, token, refused, nil)
        end
    end

    action.zfixAcked = true
end

Events.OnServerCommand.Add(onServerCommand)

--- Has the server moved everything in the current batch?
-- Checked by ID rather than by object, because the item the client ends up holding
-- after the server's packets is not necessarily the same Lua object.
--
-- Arrival at the destination is the signal, not departure from the source: that is
-- what a queued follow-up action actually tests, ISEatFoodAction being the case in
-- point. Dropping to the ground is the exception -- there is no destination
-- container to land in, so the item leaving the source has to serve instead.
local function batchMoved(self)
    if not self.zfixPending then return false end

    -- Dropping to the ground has no destination container to watch, and "gone from
    -- the source" is not observable either: sendRemoveItemFromContainer sends
    -- nothing at all when the source has no character, no parent object and no
    -- world item, which is any bag in your own inventory. So the server's
    -- acknowledgement is the signal. Safe here because nothing queues a follow-up
    -- action against an item lying on the floor.
    if self.zfixDst == ZomboidFixesB42.FLOOR then
        return self.zfixAcked == true
    end

    -- Everywhere else, wait to actually see it arrive.
    for _, item in ipairs(self.zfixPending) do
        if not self.destContainer:containsID(item:getID()) then return false end
    end
    return true
end

local function waitedTooLong(self)
    if self.zfixSentMs == nil then return false end
    local deadline = self.zfixDeadlineMs or (self.zfixSentMs + LOST_PACKET_TIMEOUT_MS)
    return getTimestampMs() > deadline
end

--[[
    Fast forward. A transfer's length is fixed by the server's item transaction in
    real milliseconds (see server/ZomboidFixesB42_FastForwardTransfer.lua), so while
    fast forward runs each new batch goes to the server as a timed move instead:
    vanilla's start() and perform() open a batch by calling the global
    createItemTransaction, and while batchFor is set that call sends the batch and
    returns 0, the id vanilla already treats as "no transaction" (removeItemTransaction
    and the other globals skip it). The server waits vanilla's length at the running
    speed, moves the items and answers; the action waits for them to arrive exactly as
    the cheat path does, and shows vanilla's progress bar, which runs at the client's
    game speed. Each batch decides for itself, so a long loot that fast forward starts
    in the middle of speeds up from the next batch on. Containers that cannot be
    addressed over the wire (corpses) keep the vanilla transaction.

    Auto fast forward never votes halfway through a batch, since that batch would only
    burn game time finishing at normal speed. Instead a batch that could be timed asks
    ZomboidFixesB42.castAutoVoteForBatch (ZomboidFixesB42_FastForward.lua) as it opens;
    when the player's auto vote is due it is cast there, and the batch waits
    (zfixDeferred) until the server has answered (autoVoteSettled), then opens at
    whatever speed the game is running: timed if everyone voted, vanilla if not.
--]]
local batchFor = nil

-- While set, createItemTransaction opens nothing and returns 0 (see start below).
local suppressTransaction = false

local function fastForwardRunning()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MultiplayerFastForward == true and (ZomboidFixesB42.fastForwardSpeed or 1) > 1
end

local vanillaCreateItemTransaction = createItemTransaction

function createItemTransaction(character, items, src, dst)
    if suppressTransaction then return 0 end
    local action = batchFor
    local castAutoVote = ZomboidFixesB42.castAutoVoteForBatch
    if action and (fastForwardRunning() or castAutoVote) then
        local srcCode = ZomboidFixesB42.encodeContainer(src, character)
        local dstCode = ZomboidFixesB42.encodeContainer(dst, character)
        if srcCode and dstCode and not fastForwardRunning() and castAutoVote
                and castAutoVote(character, action) then
            -- Auto fast forward's vote was due and has just been cast. The batch opens
            -- once the server has answered (update), at the speed the game runs then.
            action.zfixDeferred = { items = items, src = src, dst = dst }
            return 0
        end
        if srcCode and dstCode and fastForwardRunning() then
            local units = 0
            for _, item in ipairs(items or {}) do
                units = math.max(units, ZomboidFixesB42.transferUnits(character, item, src, dst))
            end
            action.zfixTimed = true
            action.zfixSrc, action.zfixDst = srcCode, dstCode
            action.zfixUnits = math.max(1, units)
            sendBatch(action, { items = items }, ZomboidFixesB42.CMD_TRANSFER_TIMED)
            -- At worst the whole batch runs at normal speed.
            action.zfixDeadlineMs = getTimestampMs() + units * 20 + LOST_PACKET_TIMEOUT_MS
            return 0
        end
    end
    return vanillaCreateItemTransaction(character, items, src, dst)
end

--- Run a vanilla function that may open a batch, letting fast forward take the batch.
local function openingBatch(self, fn)
    self.zfixTimed = false
    self.zfixDeferred = nil
    batchFor = self
    local ok, err = pcall(fn, self)
    batchFor = nil
    if not ok then error(err) end
    if self.zfixTimed then
        -- Vanilla leaves -1 here for the server's transaction to fill in.
        self.maxTime = self.zfixUnits
        self.action:setTime(self.maxTime)
    end
end

--- Open the batch that waited for auto fast forward's vote to be answered. While it
-- waited, maxTime stayed at vanilla's -1, so the action could not finish.
local function openDeferred(self)
    local batch = self.zfixDeferred
    self.zfixDeferred = nil
    self.zfixTimed = false
    batchFor = self
    local ok, result = pcall(createItemTransaction, self.character, batch.items, batch.src, batch.dst)
    batchFor = nil
    if not ok then error(result) end
    self.transactionId = result
    if self.zfixTimed then
        self.maxTime = self.zfixUnits
        self.action:setTime(self.maxTime)
    end
end

--- Move what the server declined the vanilla way, and run the rest of this action
-- as vanilla does. The batch stays queueList[1]: vanilla's perform takes it off
-- once the transaction is done, skipping the items already moved (isValid sets
-- dontAdd for items no longer in the source).
local function fallBackToVanilla(self)
    local items = self.zfixFallback
    self.zfixFallback = nil
    forgetBatch(self)
    self.zfixFast = false
    self.zfixTimed = false
    self.useProgressBar = true
    self.action:setUseProgressBar(true)
    -- Vanilla's "the server will say how long" for this batch and every later one.
    for _, queued in ipairs(self.queueList or {}) do queued.time = -1 end
    self.maxTime = -1
    self.action:setTime(-1)
    self.transactionId = vanillaCreateItemTransaction(self.character, items, self.srcContainer, self.destContainer)
    print(string.format("[ZomboidFixesB42] The server declined %d item(s) of a quick transfer; moving them the normal way", #items))
end

function ISInventoryTransferAction:new(character, item, srcContainer, destContainer, time)
    local o = vanilla.new(self, character, item, srcContainer, destContainer, time)

    if wantsFastTransfer(character) then
        local src = ZomboidFixesB42.encodeContainer(srcContainer, character)
        local dst = ZomboidFixesB42.encodeContainer(destContainer, character)
        if src and dst then
            o.zfixFast = true
            o.zfixSrc = src
            o.zfixDst = dst
            o.useProgressBar = false
            -- Vanilla set this to -1 so the action would wait for a duration the
            -- server would send back.
            o.maxTime = ZomboidFixesB42.TRANSFER_MAX_TIME
            for _, queued in ipairs(o.queueList or {}) do
                queued.time = o.maxTime
            end
        end
    end

    return o
end

function ISInventoryTransferAction:start()
    if not self.zfixFast then return openingBatch(self, vanilla.start) end

    -- Vanilla handles the sounds, the animation, the microwave, and it calls
    -- checkQueueList() so queueList[1] is already the full first batch. It also
    -- sets setWaitForFinished(true), which is left alone: update() below decides
    -- when this action is done.
    --
    -- Its transaction is not wanted, and must not even be opened: cancelling one
    -- sends a Reject that the server applies with removeIf(id == id) over EVERY
    -- player's transactions (TransactionManager.removeItemTransaction), and IDs are
    -- one byte numbered by each client, so the cancel could drop another player's
    -- transfer in flight, which then hangs and moves nothing.
    suppressTransaction = true
    local ok, err = pcall(vanilla.start, self)
    suppressTransaction = false
    if not ok then error(err) end

    -- Vanilla returns early, with the time at 0 and nothing started, when the item
    -- has already moved or is no longer in the source. Nothing to send then.
    if not self.started then return end

    self.action:setUseProgressBar(false)

    -- Nothing should be open (suppressTransaction above); only in case another
    -- mod's start() opened one of its own.
    if self.transactionId and self.transactionId ~= 0 then
        removeItemTransaction(self.transactionId, true)
        self.transactionId = 0
    end

    -- Set last, on purpose. create() has already put maxTime through adjustMaxTime
    -- (moodles, hand pain, body temperature) and vanilla start() adds another 1.5x
    -- while walking. A cheat should be the same speed whatever state the admin is
    -- in, so pin it back.
    self.maxTime = ZomboidFixesB42.TRANSFER_MAX_TIME
    self.action:setTime(self.maxTime)

    sendBatch(self, self.queueList and self.queueList[1])
end

--- Mirrors the vanilla 42.20 update() with the transaction polling replaced by a
-- check on whether the server's move has landed yet.
function ISInventoryTransferAction:update()
    -- A deferred batch has no transaction yet (id 0), which vanilla's polling would
    -- read as done.
    if not self.zfixFast and not self.zfixTimed and not self.zfixDeferred then return vanilla.update(self) end

    if self.character and (not self.character:hasTrait(CharacterTrait.DESENSITIZED)) and self.srcContainer and self.srcContainer:getType()
            and (self.srcContainer:getType() == "inventoryfemale" or self.srcContainer:getType() == "inventorymale") then
        local rate = getGameTime():getMultiplier()
        if self.character:hasTrait(CharacterTrait.COWARDLY) then rate = rate * 2
        elseif self.character:hasTrait(CharacterTrait.BRAVE) then rate = rate / 2 end
        self.character:getStats():add(CharacterStat.UNHAPPINESS, rate / 100)
    end

    if self.character and self.character:hasTrait(CharacterTrait.HEMOPHOBIC) and self.item and self.item:getBloodLevel() > 0 then
        local rate = self.item:getBloodLevelAdjustedLow() * getGameTime():getMultiplier()
        self.character:getStats():add(CharacterStat.STRESS, rate / 10000)
    end

    if self.selectedContainer then
        if self.selectedContainer:getParent() and not self.character:isSittingOnFurniture() then
            self.character:faceThisObject(self.selectedContainer:getParent())
        end
        if self.character:shouldBeTurning() then
            getPlayerLoot(self.character:getPlayerNum()):setForceSelectedContainer(self.selectedContainer)
        end
        getPlayerLoot(self.character:getPlayerNum()):selectButtonForContainer(self.selectedContainer)
    end

    self.item:setJobDelta(self.action:getJobDelta())
    self.character:setMetabolicTarget(Metabolics.LightWork)

    if self.zfixDeferred then
        local settled = ZomboidFixesB42.autoVoteSettled
        if not settled or settled(self.character) then openDeferred(self) end
        return
    end

    if self.zfixFallback and not self.zfixCompleted then return fallBackToVanilla(self) end

    if not self.zfixCompleted then
        local moved = batchMoved(self)
        if moved or waitedTooLong(self) then
            if moved and self.zfixSrc == ZomboidFixesB42.FLOOR and ZomboidFixesB42.clearGhostsOf then
                -- The server's removal from the ground goes by the object's index on
                -- the square and can miss on this client; see clearGhostsOf.
                ZomboidFixesB42.clearGhostsOf(self.character, self.zfixPending)
            elseif not moved and ZomboidFixesB42.resyncTransfer then
                ZomboidFixesB42.resyncTransfer(self.character, self.zfixPending, self.srcContainer, self.destContainer, "lost")
            end
            self.zfixCompleted = true
            self:forceComplete()
        end
    end
end

function ISInventoryTransferAction:perform()
    if not self.zfixFast then
        -- The finished batch, if it was a timed one, has landed; vanilla then opens
        -- the next.
        if self.zfixTimed then forgetBatch(self) end
        return openingBatch(self, vanilla.perform)
    end

    self.item:setJobDelta(0.0)

    -- This batch was handed to the server in start(), or when the previous perform
    -- advanced the queue, and update() has confirmed it landed.
    local queuedItem = table.remove(self.queueList, 1)

    if self.selectedContainer then
        getPlayerLoot(self.character:getPlayerNum()):selectButtonForContainer(self.selectedContainer)
    end

    if queuedItem ~= nil then
        for _, item in ipairs(queuedItem.items) do
            self.item = item
            self:playTransferCompleteSound(item)
        end
    end

    forgetBatch(self)

    self:checkQueueList()

    if #self.queueList > 0 then
        local nextItem = self.queueList[1]
        self.item = nextItem.items[1]
        self.action:reset() -- clears forceComplete
        self.maxTime = ZomboidFixesB42.TRANSFER_MAX_TIME
        self.action:setTime(self.maxTime)
        self:resetJobDelta()
        self:startActionAnim()
        sendBatch(self, nextItem)
    else
        self:playSourceContainerCloseSound()
        self:playDestContainerCloseSound()
        self:stopLoopingSound()

        self.action:stopTimedActionAnim()
        self.action:setLoopedAction(false)
        self.action:setWaitForFinished(false)

        if self.onCompleteFunc then
            local args = self.onCompleteArgs
            self.onCompleteFunc(args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8])
        end

        ISBaseTimedAction.perform(self)
        self.started = false
    end

    if instanceof(self.item, "Radio") then
        self.character:updateEquippedRadioFreq()
    end

    ISInventoryPage.renderDirty = true
end

--- Release the token registry slot if the action is abandoned rather than finished.
local vanillaStop = ISInventoryTransferAction.stop
function ISInventoryTransferAction:stop()
    if self.zfixTimed and self.zfixToken and not self.zfixCompleted then
        -- The server is still counting this batch down; it must not move it later.
        sendClientCommand(self.character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_TRANSFER_TIMED_CANCEL, {
            token = self.zfixToken,
        })
    end
    if self.zfixFast or self.zfixTimed then forgetBatch(self) end
    self.zfixTimed = false
    self.zfixDeferred = nil
    return vanillaStop(self)
end

--[[ Grabbing from the ground -------------------------------------------------

    ISGrabItemAction (42.21) queues world items in batches like a transfer
    (checkQueueList: same full type, up to 20, and later grabs join the last queued
    grab action), opens createItemTransaction(nil items, an "object" container whose
    parent is the batch's first world item) in start and waits for its Done. Under
    the cheat each batch goes to the server as CMD_TRANSFER from the floor instead
    (moveFromGround: every item of the batch, by ID and floor hint), and the action
    waits for the items to arrive in the inventory, as above. vanilla's grab never
    waits on its own (no setWaitForFinished), so that is set here, and isValid is
    skipped once started: the server removes each world item before the inventory
    copy arrives, and vanilla's "is it still on the square" check would stop the
    action, and the queue behind it, at that moment. Items the server declines that
    are still on the ground go the vanilla way, one world item per transaction as
    vanilla does.
--]]

local vanillaGrab = {
    new     = ISGrabItemAction.new,
    isValid = ISGrabItemAction.isValid,
    start   = ISGrabItemAction.start,
    update  = ISGrabItemAction.update,
    perform = ISGrabItemAction.perform,
    stop    = ISGrabItemAction.stop,
}

--- Send the world items of one grab batch that are still on the ground.
local function sendGrabBatch(self, queuedItem)
    local items = {}
    self.zfixSentIds = {}
    for _, worldItem in ipairs((queuedItem and queuedItem.items) or {}) do
        local item = worldItem:getItem()
        if item and worldItem:getSquare() then
            table.insert(items, item)
            self.zfixSentIds[item:getID()] = true
        end
    end
    sendBatch(self, { items = items })
end

--- Hand a declined batch to vanilla: a transaction for the first declined item
-- still on the ground, the rest of the batch after it the vanilla way.
local function fallBackToVanillaGrab(self)
    local worldItems = {}
    for _, item in ipairs(self.zfixFallback) do
        local worldItem = item:getWorldItem()
        if worldItem and worldItem:getSquare() then table.insert(worldItems, worldItem) end
    end
    self.zfixFallback = nil
    local queuedItem = self.queueList and self.queueList[1]
    -- Nothing left on the ground: the rest of the batch is waited for as usual.
    if #worldItems == 0 or not queuedItem then return end
    forgetBatch(self)
    self.zfixFast = false
    self.useProgressBar = true
    self.action:setUseProgressBar(true)
    self.action:setWaitForFinished(false)
    queuedItem.items = worldItems
    for _, queued in ipairs(self.queueList) do queued.time = -1 end
    self.item = worldItems[1]
    self.sourceContainer = ItemContainer.new("object", self.item:getSquare(), self.item)
    self.maxTime = -1
    self.action:setTime(-1)
    self.transactionId = vanillaCreateItemTransaction(self.character, nil, self.sourceContainer, self.destContainer)
    print(string.format("[ZomboidFixesB42] The server declined %d item(s) of a quick grab; picking them up the normal way", #worldItems))
end

function ISGrabItemAction:new(character, item, time)
    local o = vanillaGrab.new(self, character, item, time)
    -- A grab that joined an earlier grab action (ignoreAction) is never run itself.
    if not o.ignoreAction and wantsFastTransfer(character) then
        local dst = ZomboidFixesB42.encodeContainer(o.destContainer, character)
        if dst then
            o.zfixFast = true
            o.zfixSrc = ZomboidFixesB42.FLOOR
            o.zfixDst = dst
            -- Only for TransferResync, if the server declines an item.
            o.srcContainer = ItemContainer.new("floor", nil, nil)
            o.useProgressBar = false
            o.maxTime = ZomboidFixesB42.TRANSFER_MAX_TIME
            for _, queued in ipairs(o.queueList or {}) do queued.time = o.maxTime end
        end
    end
    return o
end

function ISGrabItemAction:isValid()
    if self.zfixFast and self.started then return true end
    return vanillaGrab.isValid(self)
end

function ISGrabItemAction:start()
    if not self.zfixFast then return vanillaGrab.start(self) end
    -- Vanilla's animation and job text, without its transaction (see
    -- ISInventoryTransferAction:start for why one must not even be opened).
    suppressTransaction = true
    local ok, err = pcall(vanillaGrab.start, self)
    suppressTransaction = false
    if not ok then error(err) end
    self.transactionId = 0
    self.action:setUseProgressBar(false)
    self.action:setWaitForFinished(true)
    self.maxTime = ZomboidFixesB42.TRANSFER_MAX_TIME
    self.action:setTime(self.maxTime)
    sendGrabBatch(self, self.queueList and self.queueList[1])
end

function ISGrabItemAction:update()
    if not self.zfixFast then return vanillaGrab.update(self) end
    local item = self.item and self.item:getItem()
    if item then item:setJobDelta(self.action:getJobDelta()) end

    if self.zfixFallback and not self.zfixCompleted then return fallBackToVanillaGrab(self) end

    if not self.zfixCompleted then
        local moved = batchMoved(self)
        if moved or waitedTooLong(self) then
            if moved and ZomboidFixesB42.clearGhostsOf then
                ZomboidFixesB42.clearGhostsOf(self.character, self.zfixPending)
            elseif not moved and ZomboidFixesB42.resyncTransfer then
                ZomboidFixesB42.resyncTransfer(self.character, self.zfixPending, self.srcContainer, self.destContainer, "lost")
            end
            self.zfixCompleted = true
            self:forceComplete()
        end
    end
end

function ISGrabItemAction:perform()
    if not self.zfixFast then return vanillaGrab.perform(self) end

    local queuedItem = table.remove(self.queueList, 1)
    -- Grabs queued after the batch was sent join it (checkQueueList): send them next.
    if queuedItem then
        local left = {}
        for _, worldItem in ipairs(queuedItem.items) do
            local item = worldItem:getItem()
            if item and not (self.zfixSentIds and self.zfixSentIds[item:getID()]) then
                table.insert(left, worldItem)
            end
        end
        if #left > 0 then
            table.insert(self.queueList, 1, { items = left, time = self.maxTime, type = queuedItem.type })
        end
    end
    forgetBatch(self)
    self.zfixSentIds = nil
    self.zfixCompleted = false

    if #self.queueList > 0 then
        local nextItem = self.queueList[1]
        self.item = nextItem.items[1]
        self.action:reset() -- clears forceComplete
        self.maxTime = ZomboidFixesB42.TRANSFER_MAX_TIME
        self.action:setTime(self.maxTime)
        self:resetJobDelta()
        sendGrabBatch(self, nextItem)
    else
        self.action:stopTimedActionAnim()
        self.action:setLoopedAction(false)
        self.action:setWaitForFinished(false)
        ISBaseTimedAction.perform(self)
        self.started = false
    end
    ISInventoryPage.renderDirty = true
end

function ISGrabItemAction:stop()
    if self.zfixFast then forgetBatch(self) end
    return vanillaGrab.stop(self)
end
