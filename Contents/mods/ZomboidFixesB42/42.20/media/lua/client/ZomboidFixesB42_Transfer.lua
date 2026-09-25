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

    Everything here is opt-in per action: if the FastTransfers sandbox option is
    off, or the containers involved cannot be addressed over the wire, zfixFast is
    never set and the action runs exactly as vanilla does today.
--]]

require "TimedActions/ISInventoryTransferAction"

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
    self.zfixAcked = false
end

--- Ask the server to move one batch of items, and start waiting for it.
local function sendBatch(self, queuedItem)
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

    sendClientCommand(self.character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_TRANSFER, {
        token = self.zfixToken,
        src = self.zfixSrc,
        dst = self.zfixDst,
        items = table.concat(ids, ","),
    })
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
        local keep = {}
        for _, item in ipairs(action.zfixPending) do
            if not declined[item:getID()] then
                table.insert(keep, item)
            end
        end
        action.zfixPending = keep
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
    return self.zfixSentMs ~= nil and (getTimestampMs() - self.zfixSentMs) > LOST_PACKET_TIMEOUT_MS
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
    if not self.zfixFast then return vanilla.start(self) end

    -- Vanilla handles the sounds, the animation, the microwave, and it calls
    -- checkQueueList() so queueList[1] is already the full first batch. It also
    -- sets setWaitForFinished(true), which is left alone: update() below decides
    -- when this action is done.
    vanilla.start(self)

    -- Vanilla returns early, with the time at 0 and nothing started, when the item
    -- has already moved or is no longer in the source. Nothing to send then.
    if not self.started then return end

    self.action:setUseProgressBar(false)

    -- The transaction it opened is not wanted; we do the move ourselves.
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
    if not self.zfixFast then return vanilla.update(self) end

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

    if not self.zfixCompleted and (batchMoved(self) or waitedTooLong(self)) then
        self.zfixCompleted = true
        self:forceComplete()
    end
end

function ISInventoryTransferAction:perform()
    if not self.zfixFast then return vanilla.perform(self) end

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
    if self.zfixFast then forgetBatch(self) end
    return vanillaStop(self)
end
