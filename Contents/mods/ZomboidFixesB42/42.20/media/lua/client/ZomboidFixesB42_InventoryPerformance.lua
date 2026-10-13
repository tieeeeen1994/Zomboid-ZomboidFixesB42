--[[
    Zomboid Fixes B42.20 -- client, inventory windows with many items

    The inventory and loot windows (ISInventoryPage / ISInventoryPane, 42.21) redo
    work over every item far more often than anything changes, so a container with
    hundreds or thousands of items makes the game stutter:

    1. Full rebuilds on every change. ISInventoryPage.OnContainerUpdate only sets
       ISInventoryPage.renderDirty, and the Java side sets the player's
       invPageDirty; the next ISInventoryPage:prerender then runs
       ISInventoryPage.dirtyUI, which is refreshBackpacks on both windows of every
       local player: container buttons, the floor container rebuilt item by item
       from the 3x3 squares, refreshContainer of each shown container (every item's
       display name, which for food and drinks is built from prefixes and liquids,
       its weight, hidden flag, herbalist type; then a sort) and an item count
       (luautils.countItemsRecursive). It also marks the crafting and build windows
       dirty (ISHandCraftPanel.drawDirty, ISBuildPanel.drawDirty), which rescan every
       nearby container. OnContainerUpdate fires from Java for any item added or
       removed nearby, a door, window or curtain, a tree, a vehicle part, food
       turning stale, clothing getting wet, every item field sync in multiplayer...
       so with a big container open this runs many times a second, and a transfer of
       many items runs it once per batch. Separately, the pane's renderdetails runs
       refreshContainer whenever the container's drawDirty is set (any item added
       or removed in it), and the loot window's update runs refreshBackpacks every
       time the player turns or steps onto another square.

    2. Food aging every frame. renderdetails (prerender and render, so twice a
       frame) calls updateAge on every item of a collapsed food stack ("so they
       separate when freshness changes", ISInventoryPane.lua ~2567): 1000 apples are
       2000 calls into Java per frame. In single player Food.updateAge can also
       search the cell's process list (getProcessItems().contains) for each.

    What this does, without changing what the windows show:

      - Rebuilds are held back by what they cost: after one that took C ms, the
        next waits up to C x COST_FACTOR ms (never more than MAX_DELAY_MS, nothing
        under MIN_COST_MS), so they never take more than about a ninth of the time.
        The requests are not lost, only merged: renderDirty / invPageDirty are taken
        back and set again once it is due, a refreshContainer from renderdetails
        waits while drawDirty stays set, and a direct one runs from the pane's next
        update. A container that changes (another one selected) or a pane with no
        list yet is refreshed at once. The loot window's step / turn refresh waits
        the same way. Small containers cost under a millisecond and are never held.
      - A collapsed food stack of more than FOOD_SLICE_MIN items is aged a slice at
        a time: each frame's prerender ages 1 / FOOD_ROUND_FRAMES of it, the render
        pass none, so every item is still aged about twice a second.

    3. Right-clicking a big stack (ISInventoryPaneContextMenu.createMenu). Most of
       its tests already look at one item, but several helpers walk the whole
       stack or the whole inventory, and the menu itself grows quadratically:

       - ISContextMenu:addOption calls setWidth(calcWidth()), and calcWidth
         measures every option's text again, so a menu of K options costs K x K / 2
         text measurements. Consolidate (one option per partly used drainable of
         that type in the inventory) or the evolved recipe ingredient list can add
         hundreds: seconds for 1000 half-used items.
       - ISInventoryPane.getActualItems flattens the selection into a new list,
         deduplicated through a table keyed by item, about six times per menu.
       - doPlace3DItemOption calls getWorldStaticItem (which creates an empty
         modData table on every item that has none), getType, instanceof and
         isFavorite on every item and never stops early.
       - canUnpack calls ItemContainer.contains twice per item (a linear search,
         the second one through every bag), the same answer for every item of one
         container.
       - doReloadMenuForBullets reads the inventory's item list twice per item of
         the inventory, the 1000 rounds included.

       What this does, with the same menu: while addOption runs on a menu of more
       than BIG_MENU options, the width grows by the new option's text alone
       (calcWidth called from anywhere else measures everything as before);
       getActualItems copies the groups straight when the selection is only whole
       stacks (they never share an item); doPlace3DItemOption decides the 3D test
       per item script when the script has a world model (getWorldStaticItem is
       then never nil) and stops once one item rules the option out; canUnpack
       asks once per container; doReloadMenuForBullets reads the list once and
       skips the rounds themselves. The crafting part of the menu (Java,
       CraftRecipeManager.getUniqueRecipeItems over every nearby item) and the
       loops inside createMenu itself (eat, pills, joypad moves) are left alone.

    Option InventoryPerformance.
--]]

require "ISUI/ISInventoryPage"
require "ISUI/ISInventoryPane"
require "ISUI/ISContextMenu"
require "ISUI/ISInventoryPaneContextMenu"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.InventoryPerformance == true
end

local MIN_COST_MS = 2
local COST_FACTOR = 8
local MAX_DELAY_MS = 300
local FOOD_SLICE_MIN = 30
local FOOD_ROUND_FRAMES = 30
local BIG_MENU = 30

local function delayFor(costMs)
    if not costMs or costMs < MIN_COST_MS then return 0 end
    return math.min(MAX_DELAY_MS, costMs * COST_FACTOR)
end

-- ---------------------------------------------------------------------------
-- 1a. dirtyUI from renderDirty / invPageDirty
-- ---------------------------------------------------------------------------

local dirtyDueMs = 0
local dirtyPending = false

local vanillaDirtyUI = ISInventoryPage.dirtyUI
ISInventoryPage.dirtyUI = function(...)
    local start = getTimestampMs()
    vanillaDirtyUI(...)
    local now = getTimestampMs()
    dirtyDueMs = now + delayFor(now - start)
    dirtyPending = false
end

local vanillaPagePrerender = ISInventoryPage.prerender
function ISInventoryPage:prerender(...)
    if isEnabled() and getTimestampMs() < dirtyDueMs then
        if ISInventoryPage.renderDirty then
            ISInventoryPage.renderDirty = false
            dirtyPending = true
        end
        local playerObj = getSpecificPlayer(self.player)
        if playerObj and playerObj:isInvPageDirty() then
            playerObj:setInvPageDirty(false)
            dirtyPending = true
        end
    end
    return vanillaPagePrerender(self, ...)
end

-- ---------------------------------------------------------------------------
-- 1b. The loot window's refresh on every step and turn
-- ---------------------------------------------------------------------------

local vanillaRefreshBackpacks = ISInventoryPage.refreshBackpacks
function ISInventoryPage:refreshBackpacks(...)
    local start = getTimestampMs()
    vanillaRefreshBackpacks(self, ...)
    local now = getTimestampMs()
    self.zfixBackpacksDueMs = now + delayFor(now - start)
    self.zfixMovePending = nil
end

local vanillaPageUpdate = ISInventoryPage.update
function ISInventoryPage:update(...)
    if isEnabled() and not self.onCharacter then
        local playerObj = getSpecificPlayer(self.player)
        if playerObj then
            local now = getTimestampMs()
            local moved = self.lastDir ~= playerObj:getDir() or self.lastSquare ~= playerObj:getCurrentSquare()
            if moved and now < (self.zfixBackpacksDueMs or 0) then
                -- Vanilla compares these to decide; it refreshes once we let go.
                self.lastDir = playerObj:getDir()
                self.lastSquare = playerObj:getCurrentSquare()
                self.zfixMovePending = true
            elseif self.zfixMovePending and now >= (self.zfixBackpacksDueMs or 0) then
                self.zfixMovePending = nil
                self.lastSquare = nil
            end
        end
    end
    return vanillaPageUpdate(self, ...)
end

-- ---------------------------------------------------------------------------
-- 1c. refreshContainer of one pane
-- ---------------------------------------------------------------------------

local vanillaRefreshContainer = ISInventoryPane.refreshContainer
function ISInventoryPane:refreshContainer(...)
    local now = getTimestampMs()
    if isEnabled() and self.itemslist and self.zfixRefreshedInventory == self.inventory
        and now < (self.zfixRefreshDueMs or 0) then
        self.zfixRefreshPending = true
        return
    end
    vanillaRefreshContainer(self, ...)
    local after = getTimestampMs()
    self.zfixRefreshedInventory = self.inventory
    self.zfixRefreshDueMs = after + delayFor(after - now)
    self.zfixRefreshPending = nil
end

local vanillaPaneUpdate = ISInventoryPane.update
function ISInventoryPane:update(...)
    if self.zfixRefreshPending and getTimestampMs() >= (self.zfixRefreshDueMs or 0) then
        self:refreshContainer()
    end
    return vanillaPaneUpdate(self, ...)
end

-- ---------------------------------------------------------------------------
-- 2. Food aging in collapsed stacks
-- ---------------------------------------------------------------------------

local vanillaRenderdetails = ISInventoryPane.renderdetails
function ISInventoryPane:renderdetails(doDragged, ...)
    if not isEnabled() then
        return vanillaRenderdetails(self, doDragged, ...)
    end
    -- What vanilla does first, so the stacks below are the ones it will draw.
    if doDragged == false and self.inventory and self.inventory:isDrawDirty() then
        self:refreshContainer()
    end
    -- A drag in progress reads the dragged stacks' items while drawing.
    if not self.itemslist or not self.collapsed or ISMouseDrag.dragging ~= nil then
        return vanillaRenderdetails(self, doDragged, ...)
    end

    -- Each big collapsed food stack gets a short items list for this call: the
    -- header (items[1], which vanilla draws) and the slice to age. The real list
    -- is put back right after; the count shown comes from v.count.
    local swapped = nil
    for _, v in ipairs(self.itemslist) do
        local items = v.items
        local n = items and (#items - 1) or 0
        if n > FOOD_SLICE_MIN and self.collapsed[v.name] and instanceof(items[1], "Food") then
            local slice = { items[1] }
            if doDragged == false then
                local per = math.ceil(n / FOOD_ROUND_FRAMES)
                local cursor = v.zfixAgeCursor or 1
                for _ = 1, per do
                    cursor = cursor + 1
                    if cursor > n + 1 then cursor = 2 end
                    slice[#slice + 1] = items[cursor]
                end
                v.zfixAgeCursor = cursor
            end
            swapped = swapped or {}
            swapped[v] = items
            v.items = slice
        end
    end

    if not swapped then
        return vanillaRenderdetails(self, doDragged, ...)
    end
    local ok, err = pcall(vanillaRenderdetails, self, doDragged, ...)
    for v, items in pairs(swapped) do
        v.items = items
    end
    if not ok then error(err) end
end

-- ---------------------------------------------------------------------------
-- 3. Context menus of big stacks
-- ---------------------------------------------------------------------------

--- ISContextMenu:calcWidth's own formula around the widest option text.
local function widthFor(menu, maxWidth)
    local iconSize = menu.itemHgt - 12
    local iconShiftX = 2
    local textForIconShift = iconSize + iconShiftX * 2 + 2
    return math.max(textForIconShift + maxWidth + 24 + getTextManager():MeasureStringX(menu.font, ">") + 4, 100)
end

local vanillaCalcWidth = ISContextMenu.calcWidth
function ISContextMenu:calcWidth(...)
    if not isEnabled() then
        return vanillaCalcWidth(self, ...)
    end
    local n = self.numOptions - 1
    local textManager = getTextManager()
    if self.zfixAdding and n > BIG_MENU and self.zfixWidthCount == n - 1 and self.zfixWidthFont == self.font
        and self.options[n] then
        -- One option added since the last measure: only it can be wider.
        local w = textManager:MeasureStringX(self.font, self.options[n].name)
        if w > self.zfixWidthMax then self.zfixWidthMax = w end
    else
        local maxWidth = 0
        for _, option in ipairs(self.options) do
            local w = textManager:MeasureStringX(self.font, option.name)
            if w > maxWidth then maxWidth = w end
        end
        self.zfixWidthMax = maxWidth
    end
    self.zfixWidthCount = n
    self.zfixWidthFont = self.font
    return widthFor(self, self.zfixWidthMax)
end

local vanillaAddOption = ISContextMenu.addOption
function ISContextMenu:addOption(...)
    self.zfixAdding = true
    local ok, result = pcall(vanillaAddOption, self, ...)
    self.zfixAdding = nil
    if not ok then error(result) end
    return result
end

local vanillaGetActualItems = ISInventoryPane.getActualItems
ISInventoryPane.getActualItems = function(items, ...)
    if not isEnabled() or type(items) ~= "table" then
        return vanillaGetActualItems(items, ...)
    end
    -- Only whole stacks, each once: their items are all different (one row of a
    -- container each, items[1] a copy of items[2]), so no deduplication needed.
    local seen = {}
    for _, entry in ipairs(items) do
        if type(entry) ~= "table" or type(entry.items) ~= "table" or seen[entry] then
            return vanillaGetActualItems(items, ...)
        end
        seen[entry] = true
    end
    local ret = {}
    local n = 0
    for _, group in ipairs(items) do
        local list = group.items
        for i = 2, #list do
            n = n + 1
            ret[n] = list[i]
        end
    end
    return ret
end

-- [full type] = true when the item script has a world model
local scriptHasModel = {}

local function hasWorldModelByScript(item)
    local fullType = item:getFullType()
    local known = scriptHasModel[fullType]
    if known == nil then
        local script = item:getScriptItem()
        local ok, model = pcall(function() return script and script:getWorldStaticModel() end)
        known = ok and model ~= nil and model ~= ""
        scriptHasModel[fullType] = known
    end
    return known
end

local vanillaPlace3D = ISInventoryPaneContextMenu.doPlace3DItemOption
ISInventoryPaneContextMenu.doPlace3DItemOption = function(items, player, context, ...)
    if not isEnabled() then
        return vanillaPlace3D(items, player, context, ...)
    end
    if player:getVehicle() then return end
    local all3D = true
    local noFavourites = true
    items = ISInventoryPane.getActualItems(items)
    for _, item in ipairs(items) do
        -- getWorldStaticItem falls back to the script's world model, so with one
        -- it is never nil.
        if not hasWorldModelByScript(item) and not item:getWorldStaticItem()
            and not instanceof(item, "HandWeapon") and not instanceof(item, "Clothing") then
            all3D = false
        end
        if item:getType() == "CarBatteryCharger" then
            all3D = false
        end
        if all3D and instanceof(item, "Clothing") then
            all3D = item:canBe3DRender()
        end
        if item:isFavorite() then
            noFavourites = false
        end
        -- Without all3D nothing is added, so the rest cannot matter.
        if not all3D then return end
    end
    if all3D then
        local placeOption = context:addOption(getText("ContextMenu_PlaceItemOnGround"), items, ISInventoryPaneContextMenu.onPlaceItemOnGround, player)
        if noFavourites == false then
            placeOption.notAvailable = true
            local tooltip = ISInventoryPaneContextMenu.addToolTip()
            tooltip.description = getText("Tooltip_CantPlaceFavoriteItems")
            placeOption.toolTip = tooltip
        end
        local testItem = items[1]
        if testItem and #items > 1 and (testItem:getContainer() ~= player:getInventory()) then
            placeOption.onSelect = nil
            local subMenu = context:getNew(context)
            context:addSubMenu(placeOption, subMenu)
            subMenu:addOption(getText("ContextMenu_PlaceOne"), { items[1] }, ISInventoryPaneContextMenu.onPlaceItemOnGround, player)
            if #items > 2 then
                subMenu:addOption(getText("ContextMenu_PlaceHalf"), { unpack(items, 1, math.ceil(#items / 2)) }, ISInventoryPaneContextMenu.onPlaceItemOnGround, player)
            end
            subMenu:addOption(getText("ContextMenu_PlaceAll"), items, ISInventoryPaneContextMenu.onPlaceItemOnGround, player)
        end
    end
end

local vanillaCanUnpack = ISInventoryPaneContextMenu.canUnpack
ISInventoryPaneContextMenu.canUnpack = function(items, player, ...)
    if not isEnabled() then
        return vanillaCanUnpack(items, player, ...)
    end
    local inventory = getSpecificPlayer(player):getInventory()
    local checked = {}
    for _, item in ipairs(items) do
        -- Every item of one container gets the same answer.
        local container = item:getContainer()
        if not container or not checked[container] then
            if inventory:contains(item) then return false end
            if not inventory:contains(item, true) then return false end
            if container then checked[container] = true end
        end
    end
    return true
end

local vanillaReloadForBullets = ISInventoryPaneContextMenu.doReloadMenuForBullets
ISInventoryPaneContextMenu.doReloadMenuForBullets = function(playerObj, bullet, context, ...)
    if not isEnabled() then
        return vanillaReloadForBullets(playerObj, bullet, context, ...)
    end
    local bulletType = bullet:getFullType()
    local bulletScript = bullet:getScriptItem()
    local inventory = playerObj:getInventory()
    local items = inventory:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        -- The rounds themselves are neither magazines nor guns.
        local ammoType = item:getScriptItem() ~= bulletScript and item:getAmmoType() or nil
        if ammoType then
            local itemKey = ammoType:getItemKey()
            if not instanceof(item, "HandWeapon") and itemKey == bulletType then
                if item:getCurrentAmmoCount() < item:getMaxAmmo() then
                    local ammoCount = inventory:getItemCountRecurse(itemKey)
                    if ammoCount > item:getMaxAmmo() then
                        ammoCount = item:getMaxAmmo()
                    end
                    if ammoCount > item:getMaxAmmo() - item:getCurrentAmmoCount() then
                        ammoCount = item:getMaxAmmo() - item:getCurrentAmmoCount()
                    end
                    local insertOption = context:addOption(getText("ContextMenu_InsertBulletsInMagazine", ammoCount), playerObj, ISInventoryPaneContextMenu.onLoadBulletsInMagazine, item, ammoCount)
                    local tooltip = ISInventoryPaneContextMenu.addToolTip()
                    tooltip.description =
                        (getText("ContextMenu_Magazine") .. ": " .. getText(item:getDisplayName()) .. "\n" ..
                        getText("ContextMenu_GunType") .. ": " .. item:getGunTypeString() .. "\n" ..
                        getText("Tooltip_weapon_AmmoCount") .. ": " .. item:getCurrentAmmoCount() .. "/" .. item:getMaxAmmo())
                    insertOption.toolTip = tooltip
                end
            elseif instanceof(item, "HandWeapon") and not item:getMagazineType() and itemKey == bulletType then
                ISInventoryPaneContextMenu.doBulletMenu(playerObj, item, context)
            end
        end
    end
end

-- ---------------------------------------------------------------------------

Events.OnTick.Add(function()
    if dirtyPending and getTimestampMs() >= dirtyDueMs then
        dirtyPending = false
        ISInventoryPage.renderDirty = true
    end
end)
