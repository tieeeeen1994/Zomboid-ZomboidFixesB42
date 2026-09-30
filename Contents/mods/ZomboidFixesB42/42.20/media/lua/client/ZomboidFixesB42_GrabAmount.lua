--[[
    Zomboid Fixes B42.20 -- client, "Grab amount..." between Grab one and Grab all

    Right-clicking a stack in a loot window (ISInventoryPaneContextMenu.doGrabMenu,
    ISInventoryPaneContextMenu.lua ~4204) offers Grab one, Grab half and Grab all as soon
    as the stack holds two items or more, and the world item icons of search mode
    (ISBaseIcon:doGrabSubMenu, Foraging/ISBaseIcon.lua ~68) offer Grab one, Grab half
    (from three) and Grab all in their "Put in inventory" submenu. There is no way to
    take, say, 7 nails out of 50 short of dragging them one by one.

    This adds "Grab amount..." right after Grab one in both menus, whenever there are at
    least three items to take from. It asks how many (1 to all, remembering the last
    number typed; Enter confirms) and then hands exactly that many items to the vanilla
    handler of Grab all -- ISInventoryPaneContextMenu.onGrabItems for loot windows, the
    icon's own onClickContext for search mode icons -- so walking to the container,
    transfer actions, multiplayer transactions and anything other mods hook into those
    work exactly as they do for Grab one / half / all. The items are taken in the same
    order vanilla's Grab one and Grab half take them. Items that moved while the dialog
    was open are skipped; if fewer are left, it grabs what is left.

    Both wraps are installed from OnGameStart (the foraging files load after this one),
    once per Lua load. With the option off, the menus are vanilla.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.GrabAmount == true
end

-- Below this many items the menus already say everything (one / all).
local MIN_ITEMS = 3

-- Last amount confirmed, offered again next time (clamped to what is there).
local lastAmount = nil

local function parseAmount(text, max)
    local n = tonumber(text)
    if n == nil or n ~= math.floor(n) or n < 1 or n > max then return nil end
    return n
end

--- Asks for a number from 1 to max, then calls onAmount(n).
local function askAmount(playerNum, max, onAmount)
    local default = lastAmount or math.ceil(max / 2)
    if default > max then default = max end

    local title = getText("IGUI_ZomboidFixesB42_GrabAmount_Prompt", string.format("%d", max))
    local function onClick(_, button)
        if button.internal ~= "OK" then return end
        local n = parseAmount(button.parent.entry:getText(), max)
        if n == nil then return end
        lastAmount = n
        onAmount(n)
    end

    local modal = ISTextBox:new(0, 0, 280, 180, title, string.format("%d", default), nil, onClick, playerNum)
    modal:initialise()
    modal:setOnlyNumbers(true)
    modal:setValidateFunction(nil, function(_, text) return parseAmount(text, max) ~= nil end)
    modal:setValidateTooltipText(getText("IGUI_ZomboidFixesB42_GrabAmount_Invalid", string.format("%d", max)))
    modal:addToUIManager()

    -- Enter confirms, as long as the number is valid.
    modal.entry.onCommandEntered = function()
        if parseAmount(modal.entry:getText(), max) ~= nil then
            modal:onClick(modal.yes)
        end
    end

    if JoypadState.players[playerNum + 1] then
        setJoypadFocus(playerNum, modal)
    else
        modal.entry:focus()
        modal.entry:selectAll()
    end
end

-- Loot windows ---------------------------------------------------------------

--- The selected items not already on the player, in vanilla's Grab one / half order.
local function grabbableItems(items, playerNum)
    local playerInv = getPlayerInventory(playerNum).inventory
    local list = {}
    for _, item in ipairs(ISInventoryPane.getActualItems(items)) do
        local container = item:getContainer()
        if container ~= nil and container ~= playerInv then
            table.insert(list, item)
        end
    end
    return list
end

local function onGrabAmount(items, playerNum)
    local list = grabbableItems(items, playerNum)
    if #list == 0 then return end
    askAmount(playerNum, #list, function(n)
        -- Re-read the selection: items may have moved while the dialog was open.
        local now = grabbableItems(list, playerNum)
        local take = {}
        for i = 1, math.min(n, #now) do
            take[i] = now[i]
        end
        if #take > 0 then
            ISInventoryPaneContextMenu.onGrabItems(take, playerNum)
        end
    end)
end

local function installLootWindows()
    local previousDoGrabMenu = ISInventoryPaneContextMenu.doGrabMenu

    function ISInventoryPaneContextMenu.doGrabMenu(context, items, player, ...)
        local result = previousDoGrabMenu(context, items, player, ...)
        if isEnabled() then
            -- Grab one is only there when vanilla found a stack it may grab from.
            local grabOne = getText("ContextMenu_Grab_one")
            if context:getOptionFromName(grabOne) and #grabbableItems(items, player) >= MIN_ITEMS then
                context:insertOptionAfter(grabOne, getText("IGUI_ZomboidFixesB42_GrabAmount"), items, onGrabAmount, player)
            end
        end
        return result
    end
end

-- Search mode icons ------------------------------------------------------------

--- The icon's world items still on the ground, the same list vanilla builds.
local function iconItems(icon)
    local list = {}
    if icon.itemObjTable then
        for _, itemObj in pairs(icon.itemObjTable) do
            if itemObj and itemObj:getWorldItem() then
                table.insert(list, itemObj)
            end
        end
    end
    return list
end

local function onGrabAmountIcon(icon, inventory)
    local list = iconItems(icon)
    if #list == 0 then return end
    askAmount(icon.player, #list, function(n)
        local now = iconItems(icon)
        local take = {}
        for i = 1, math.min(n, #now) do
            take[i] = now[i]
        end
        if #take > 0 then
            icon:onClickContext(0, 0, nil, inventory, take)
        end
    end)
end

local function installSearchIcons()
    local previousDoGrabSubMenu = ISBaseIcon.doGrabSubMenu

    function ISBaseIcon:doGrabSubMenu(context, contextOption, inventory, ...)
        local result = previousDoGrabSubMenu(self, context, contextOption, inventory, ...)
        if isEnabled() and contextOption.subOption and #iconItems(self) >= MIN_ITEMS then
            local subMenu = context:getSubMenu(contextOption.subOption)
            local grabOne = getText("ContextMenu_Grab_one")
            if subMenu and subMenu:getOptionFromName(grabOne) then
                subMenu:insertOptionAfter(grabOne, getText("IGUI_ZomboidFixesB42_GrabAmount"), self, onGrabAmountIcon, inventory)
            end
        end
        return result
    end
end

local installed = false

Events.OnGameStart.Add(function()
    if installed then return end
    installed = true
    installLootWindows()
    if ISBaseIcon and ISBaseIcon.doGrabSubMenu then
        installSearchIcons()
    end
end)
