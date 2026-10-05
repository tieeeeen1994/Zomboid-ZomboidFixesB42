--[[
    Zomboid Fixes B42.20 -- client, every click on Craft is queued

    The crafting window's Craft button (ISWidgetHandCraftControl:startHandcraft,
    client/Entity/ISUI/CraftRecipe, 42.21) returns at once while
    logic:isCraftActionInProgress(). That flag is set when a craft action STARTS
    (HandcraftLogic.startCraftAction, from the action's onStart) and cleared when
    none is left running (stopCraftAction). So clicking Craft several times queues
    the clicks that land before the first craft starts (usually two: the first,
    and one more while its ingredients are carried out of a bag) and silently drops
    every later one. A quantity typed in the box is not affected: all of it is
    queued by one click.

    The check is there for a reason: while a craft runs, the window's recipe data
    holds that craft's own ingredients (startCraftAction -> populateInputs with the
    action's items), so a click taken then would plan with items already being used.
    So a click that lands while a craft runs is kept, and replayed through vanilla's
    own startHandcraft once this window has no craft left in the player's queue:
    by then stopCraftAction has fired onStopCraft, on which the panel calls
    logic:refresh() (ISHandCraftPanel:onStopCraft), so the replay picks fresh
    ingredients and carries them out of bags itself. It waits REPLAY_DELAY_MS of
    that quiet first, so that in multiplayer the server's removal of the used-up
    ingredients has arrived, and refreshes the logic again. Each kept click keeps
    the quantity the box showed when it was clicked, and they run one after another.

    Kept clicks are dropped when the craft is cancelled (onHandcraftActionCancelled,
    which ISHandcraftAction:stop calls), when another recipe is selected by then
    (the replay would craft that one), and when the window was not updating for a
    while (closed): update() runs only while it is shown, and a click should not
    turn into a craft long after the window is gone.
--]]

require "Entity/ISUI/CraftRecipe/ISWidgetHandCraftControl"

local REPLAY_DELAY_MS = 250
local STALE_MS = 3000

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.CraftClickQueue == true
end

local function hasQueuedCraft(player)
    return ISTimedActionQueue.hasActionType(player, "ISHandcraftAction")
end

local vanillaStart = ISWidgetHandCraftControl.startHandcraft

function ISWidgetHandCraftControl:startHandcraft(force)
    if isEnabled() and not self.zfixReplaying and self.logic and self.logic:isCraftActionInProgress() then
        local quantity = 1
        if self.allowBatchCraft and self.entryBox then
            quantity = math.max(1, tonumber(self.entryBox:getInternalText()) or 1)
        end
        self.zfixPending = self.zfixPending or {}
        table.insert(self.zfixPending, { force = force, quantity = quantity, recipe = self.logic:getRecipe() })
        self.zfixIdleSince = nil
        self.zfixLastSeen = getTimestampMs()
        return
    end
    return vanillaStart(self, force)
end

local vanillaCancelled = ISWidgetHandCraftControl.onHandcraftActionCancelled

function ISWidgetHandCraftControl:onHandcraftActionCancelled()
    self.zfixPending = nil
    self.zfixIdleSince = nil
    return vanillaCancelled(self)
end

local function replayNext(self)
    local click = table.remove(self.zfixPending, 1)
    if #self.zfixPending == 0 then self.zfixPending = nil end
    self.zfixIdleSince = nil
    if not click or not self.logic or self.logic:getRecipe() ~= click.recipe then return end

    self.logic:refresh()
    if self.allowBatchCraft and self.entryBox then
        self.craftTimes = nil
        self:setCraftQuantity(click.quantity)
    end
    self.zfixReplaying = true
    local ok, err = pcall(vanillaStart, self, click.force)
    self.zfixReplaying = nil
    if not ok then error(err) end
end

local vanillaUpdate = ISWidgetHandCraftControl.update

function ISWidgetHandCraftControl:update()
    vanillaUpdate(self)
    if not self.zfixPending then return end
    if not isEnabled() then
        self.zfixPending = nil
        return
    end
    local now = getTimestampMs()
    -- update() stopped for a while: the window was closed in between.
    if self.zfixLastSeen and now - self.zfixLastSeen > STALE_MS then
        self.zfixPending = nil
        self.zfixIdleSince = nil
        self.zfixLastSeen = nil
        return
    end
    self.zfixLastSeen = now
    if (self.logic and self.logic:isCraftActionInProgress()) or hasQueuedCraft(self.player) then
        self.zfixIdleSince = nil
        return
    end
    if not self.zfixIdleSince then
        self.zfixIdleSince = now
        return
    end
    if now - self.zfixIdleSince >= REPLAY_DELAY_MS then
        replayNext(self)
    end
end
