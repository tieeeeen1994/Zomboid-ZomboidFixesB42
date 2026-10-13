--[[
    Zomboid Fixes B42.20 -- client, crafting and build windows with many items nearby

    The crafting window (ISHandCraftPanel, 42.21) keeps a cached "can craft" state
    for every recipe it lists. Building it is HandcraftLogic.rebuildCachedRecipeInfo
    (Java): for every handcraft recipe (about 700 in vanilla) canPerform tests each
    input against every item in every nearby container (each item type the input
    accepts x every item, plus the recipe's Lua OnTest and a walk of the timed
    action queue per match). So its cost is recipes x accepted types x nearby items,
    and it runs whenever the set of nearby items changes:

      - ISInventoryPage:refreshBackpacks sets the global ISHandCraftPanel.drawDirty
        (and ISBuildPanel.drawDirty), and that runs on every inventory window
        refresh: any world item added or removed anywhere this client has loaded
        (MP), every transfer batch (MP), food changing freshness, a door... and on
        every step or turn of the player. ISHandCraftPanel:update then refreshes
        once its frame counter allows (1 update, or 10 for long lists): with the
        window open and things moving nearby, a full rebuild every few frames.
      - Every finished craft (onStopCraft: updateContainers, sortRecipeList,
        refresh), once per item of a batch.
      - ISHandCraftPanel:updateContainers also hands the containers to the two
        tooltip logics (O(items) each), which this window never shows (its recipe
        list has noTooltip), and ISCraftInventoryPanel:populate runs twice per
        change (updateContainers and onRebuildItemNodes).
      - Every update: ISEntityUI.FindCraftSurface (about 35 squares, canReachTo and
        their objects) and ISCraftRecipePanel:updateTitleWidget (labels, icons and a
        full layout of the title, plus an O(items) recipe-at-hand scan when the
        player is short of the skill).

    The build window (ISBuildPanel) runs updateContainers the same frame drawDirty is
    set or the player steps onto another square, and its list rebuilds the same
    cache on its next draw.

    What this does, without changing what the windows show once they settle:

      - A refresh request waits until requests have stopped for a while: as long as
        the last refresh took x COST_FACTOR (crafting window; nothing under
        MIN_COST_MS) or BUILD_QUIET_MS (build window), and never longer than
        MAX_LATENCY_MS after the first one. Never while a craft is running (vanilla
        never refreshes then either).
      - During a batch of crafts, a finished craft with more of the batch still
        queued (two or more ISHandcraftAction in the queue) skips the window's
        refresh; the last one does the full refresh as before.
      - The tooltip logics get the containers when a tooltip is about to show.
      - The manual-input column is marked dirty instead of being rebuilt on the
        spot (its prerender rebuilds it once).
      - FindCraftSurface is reused for SURFACE_TTL_MS while the player stays on the
        same square, the title widget is updated at most every TITLE_MS and at once
        when the recipe changes.

    Option CraftingPerformance.
--]]

require "Entity/ISEntityUI"
require "Entity/ISUI/CraftRecipe/ISHandCraftPanel"
require "Entity/ISUI/CraftRecipe/ISCraftRecipePanel"
require "Entity/ISUI/CraftRecipe/ISCraftInventoryPanel"
require "Entity/ISUI/BuildRecipe/ISBuildPanel"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.CraftingPerformance == true
end

local MIN_COST_MS = 2
local COST_FACTOR = 8
local MAX_QUIET_MS = 500
local MAX_LATENCY_MS = 1000
local BUILD_QUIET_MS = 200
local SURFACE_TTL_MS = 500
local TITLE_MS = 200

local function quietFor(costMs)
    if not costMs or costMs < MIN_COST_MS then return 0 end
    return math.min(MAX_QUIET_MS, costMs * COST_FACTOR)
end

--- Notes a refresh request on a panel; returns true once it should run.
local function debounce(panel, requested, quietMs, now)
    if requested then
        panel.zfixDirtyFirst = panel.zfixDirtyFirst or now
        panel.zfixDirtyLast = now
    end
    if not panel.zfixDirtyFirst then return false end
    if now - panel.zfixDirtyLast >= quietMs or now - panel.zfixDirtyFirst >= MAX_LATENCY_MS then
        panel.zfixDirtyFirst = nil
        panel.zfixDirtyLast = nil
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Crafting window refresh
-- ---------------------------------------------------------------------------

-- The panel whose update is running, for the FindCraftSurface cache.
local updatingPanel = nil

local vanillaHandUpdate = ISHandCraftPanel.update
function ISHandCraftPanel:update(...)
    if not isEnabled() then
        return vanillaHandUpdate(self, ...)
    end

    local now = getTimestampMs()
    local requested = ISHandCraftPanel.drawDirty == true
    ISHandCraftPanel.drawDirty = false
    local release = false
    if not self.logic:isCraftActionInProgress() then
        release = debounce(self, requested, quietFor(self.zfixRefreshCost), now)
    elseif requested then
        -- Keep it for after the craft, as vanilla does.
        self.zfixDirtyFirst = self.zfixDirtyFirst or now
        self.zfixDirtyLast = now
    end
    if release then
        ISHandCraftPanel.drawDirty = true
        self.updateTimer = 0
    end

    updatingPanel = self
    local ok, err = pcall(vanillaHandUpdate, self, ...)
    updatingPanel = nil
    if release then
        local cost = getTimestampMs() - now
        -- Remember expensive refreshes for a while: only some of them rebuild.
        self.zfixRefreshCost = math.max(cost, (self.zfixRefreshCost or 0) / 2)
    end
    if not ok then error(err) end
end

local vanillaHandUpdateContainers = ISHandCraftPanel.updateContainers
function ISHandCraftPanel:updateContainers(forceRefresh, ...)
    if not isEnabled() or not (self.recipesPanel and self.recipesPanel.noTooltip) then
        return vanillaHandUpdateContainers(self, forceRefresh, ...)
    end
    local containers = ISInventoryPaneContextMenu.getContainers(self.player)
    if self.logic:setContainers(containers) or forceRefresh then
        self.zfixTooltipContainers = containers
        self.inventoryPanel:updateContainers(containers)
        return true
    end
    return false
end

local vanillaHandUpdateTooltip = ISHandCraftPanel.updateTooltip
function ISHandCraftPanel:updateTooltip(...)
    if self.zfixTooltipContainers then
        local containers = self.zfixTooltipContainers
        self.zfixTooltipContainers = nil
        self.tooltipLogic:setContainers(containers)
        self.recipesPanel:updateContainers(containers)
    end
    return vanillaHandUpdateTooltip(self, ...)
end

--- Two or more crafts in the player's queue: this one finishing is not the last.
local function moreCraftsQueued(player)
    local queue = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player]
    if not queue or not queue.queue then return false end
    local crafts = 0
    for _, action in ipairs(queue.queue) do
        if action.Type == "ISHandcraftAction" then crafts = crafts + 1 end
    end
    return crafts >= 2
end

-- Panels bind onStopCraft when they are created (logic:addEventListener), after
-- this file has loaded.
local vanillaHandStopCraft = ISHandCraftPanel.onStopCraft
function ISHandCraftPanel:onStopCraft(...)
    if isEnabled() and moreCraftsQueued(self.player) then
        -- The next craft of the batch starts now; the last one refreshes (a
        -- cancelled batch too: ISBaseTimedAction.stop clears the queue first).
        return
    end
    return vanillaHandStopCraft(self, ...)
end

-- ---------------------------------------------------------------------------
-- Work done every update
-- ---------------------------------------------------------------------------

local vanillaFindCraftSurface = ISEntityUI.FindCraftSurface
ISEntityUI.FindCraftSurface = function(player, radius, ...)
    local panel = updatingPanel
    if not panel or not player or not isEnabled() then
        return vanillaFindCraftSurface(player, radius, ...)
    end
    local now = getTimestampMs()
    local square = player:getCurrentSquare()
    local cache = panel.zfixSurface
    if cache and cache.square == square and cache.radius == radius and now - cache.time < SURFACE_TTL_MS then
        return cache.result
    end
    local result = vanillaFindCraftSurface(player, radius, ...)
    panel.zfixSurface = { square = square, radius = radius, time = now, result = result }
    return result
end

local vanillaTitleWidget = ISCraftRecipePanel.updateTitleWidget
function ISCraftRecipePanel:updateTitleWidget(...)
    if isEnabled() then
        local now = getTimestampMs()
        if self.zfixTitleMs and now - self.zfixTitleMs < TITLE_MS then return end
        self.zfixTitleMs = now
    end
    return vanillaTitleWidget(self, ...)
end

local vanillaRecipeChanged = ISCraftRecipePanel.onRecipeChanged
function ISCraftRecipePanel:onRecipeChanged(...)
    self.zfixTitleMs = nil
    return vanillaRecipeChanged(self, ...)
end

-- ---------------------------------------------------------------------------
-- The manual-input column
-- ---------------------------------------------------------------------------

local vanillaInvUpdateContainers = ISCraftInventoryPanel.updateContainers
function ISCraftInventoryPanel:updateContainers(...)
    if not isEnabled() then return vanillaInvUpdateContainers(self, ...) end
    self.isDirty = true
end

local vanillaInvRebuildNodes = ISCraftInventoryPanel.onRebuildItemNodes
function ISCraftInventoryPanel:onRebuildItemNodes(...)
    if not isEnabled() then return vanillaInvRebuildNodes(self, ...) end
    self.isDirty = true
end

-- ---------------------------------------------------------------------------
-- Build window
-- ---------------------------------------------------------------------------

local vanillaBuildUpdate = ISBuildPanel.update
function ISBuildPanel:update(...)
    if not isEnabled() then
        return vanillaBuildUpdate(self, ...)
    end
    local now = getTimestampMs()
    -- hasPlayerMoved remembers the square, so ask it here and not again in vanilla.
    local requested = ISBuildPanel.drawDirty == true or self:hasPlayerMoved() == true
    ISBuildPanel.drawDirty = false
    if debounce(self, requested, BUILD_QUIET_MS, now) then
        ISBuildPanel.drawDirty = true
    end
    return vanillaBuildUpdate(self, ...)
end
