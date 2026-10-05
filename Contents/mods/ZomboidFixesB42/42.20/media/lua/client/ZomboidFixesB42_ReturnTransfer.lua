--[[
    Zomboid Fixes B42.20 -- client, putting an item back never cancels the queue

    Eating, smoking, reading a recipe's inputs and other actions on an item in a
    bag first move it to the main inventory and queue a transfer to put it back
    afterwards (ISCraftingUI.ReturnItemToContainer, client/ISUI/ISCraftingUI.lua,
    42.21). That transfer is made with setAllowMissingItems(true): it is meant to do
    nothing when the item is gone, eaten whole or used up. Eat All, then queue
    another eat, and the put-back of the first item cancels everything behind it:

      * single player: isValid sets dontAdd and start() sets the time to 0 when the
        item is no longer in the inventory, but update() then finds it missing from
        the source and calls forceStop(); ISBaseTimedAction.stop resets the whole
        queue (ISTimedActionQueue:resetQueue).
      * multiplayer: the item is eaten on the server, and the client can still have
        it when the put-back starts, so start() opens a transaction for it; the
        server refuses it, update() sees isItemTransactionRejected and calls
        forceStop(), with the same result.

    A put-back is tidying up after the player, so here one that cannot happen ends
    quietly (the item, if it still exists, stays in the main inventory) and the rest
    of the queue goes on. Only transfers with allowMissingItems are touched, which
    vanilla sets for put-backs alone. This file loads before the mod's other
    transfer wrappers (Transfer, TransferResync), so they see it as vanilla.
--]]

require "TimedActions/ISInventoryTransferAction"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ReturnKeepsQueue == true
end

local vanillaUpdate = ISInventoryTransferAction.update

function ISInventoryTransferAction:update()
    if self.allowMissingItems and isEnabled() then
        if isClient() then
            local id = self.transactionId
            -- Rejected but not done: the server refused it (done and rejected
            -- together means the entry is gone, which vanilla treats as done).
            if id and id ~= 0 and isItemTransactionRejected(id) and not isItemTransactionDone(id) then
                self:forceComplete()
                return
            end
        elseif self.item and self.srcContainer and not self.srcContainer:contains(self.item) then
            -- Gone: start() has set the time to 0 and perform() skips it (dontAdd).
            return
        end
    end
    return vanillaUpdate(self)
end
