--[[
    Zomboid Fixes B42.20 -- client, Refill Container fix and Reroll button

    Vanilla's "Refill container" often just empties the container on a server (why:
    shared/ZomboidFixesB42_RerollContainer.lua); the server now does the reroll
    (server/ZomboidFixesB42_RerollContainer.lua) from one command.

      - The menu option: ISInventoryPage:onBackpackRightMouseDown builds the
        container button's right-click menu; each button gets that function on
        every addContainerButton, so replacing the global reaches them all. The
        menu is caught as vanilla builds it (ISContextMenu.get wrapped for the
        call) and the option's onSelect pointed at the command. Multiplayer only:
        single player's own refill works and is left alone.
      - The Reroll button: the loot window's buttons under the item list (Take
        All, Take Same Type, Move To Floor, Remove All on the left; stove, washer,
        trunk and fire buttons on the right) are handlers registered with
        ISLootWindowContainerControls.AddHandler (42.21, ISUI/LootWindow), whose
        arrange asks every handler's shouldBeVisible on every page update and lays
        the visible ones out in list order. Reroll is added last on the left, after
        the vanilla buttons. Shown to the same people as vanilla's option (the
        LootZed cheat on, or the admin role), for the same containers. Joypad
        players get it in the window's context menu.
--]]

require "ISUI/ISInventoryPage"
require "ISUI/LootWindow/ISLootWindowContainerControls"

local RerollContainer = ZomboidFixesB42.RerollContainer

--- Vanilla's rule for offering Refill container.
local function mayReroll()
    return RerollContainer.isEnabled() and ((ISLootZed ~= nil and ISLootZed.cheat) or isAdmin())
end

local function request(playerObj, object, container)
    local args = RerollContainer.address(object, container)
    if not args or not playerObj then return end
    sendClientCommand(playerObj, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_REROLL_CONTAINER, args)
    -- Single player rerolls on the spot; make the windows show it.
    if not isClient() then ISInventoryPage.renderDirty = true end
end

-- The Reroll button -----------------------------------------------------------------

local Handler = ISLootWindowObjectControlHandler:derive("ISLootWindowObjectControlHandler_ZomboidFixesB42_Reroll")

function Handler:shouldBeVisible()
    if self.lootWindow.onCharacter or not mayReroll() then return false end
    return RerollContainer.isRerollable(self.object, self.container)
end

function Handler:getControl()
    self.control = self:getButtonControl(getText("IGUI_ZomboidFixesB42_Reroll"))
    self.control.tooltip = getText("IGUI_ZomboidFixesB42_Reroll_tooltip")
    return self.control
end

function Handler:handleJoypadContextMenu(context)
    self:addJoypadContextMenuOption(context, getText("IGUI_ZomboidFixesB42_Reroll"))
end

function Handler:perform()
    if isGamePaused() then return end
    request(self.playerObj, self.object, self.container)
end

function Handler:new()
    return ISLootWindowObjectControlHandler.new(self)
end

ISLootWindowContainerControls.AddHandler(Handler)

-- Vanilla's Refill container, multiplayer -------------------------------------------

local vanillaRightMouseDown = ISInventoryPage.onBackpackRightMouseDown

function ISInventoryPage.onBackpackRightMouseDown(button, x, y, ...)
    if not isClient() or not RerollContainer.isEnabled() then
        return vanillaRightMouseDown(button, x, y, ...)
    end
    local menus = {}
    local vanillaGet = ISContextMenu.get
    ISContextMenu.get = function(...)
        local menu = vanillaGet(...)
        menus[#menus + 1] = menu
        return menu
    end
    local ok, err = pcall(vanillaRightMouseDown, button, x, y, ...)
    ISContextMenu.get = vanillaGet
    if not ok then error(err) end

    local refill = getText("ContextMenu_RefillContainer")
    for _, menu in ipairs(menus) do
        local option = menu:getOptionFromName(refill)
        if option then
            -- target = the container, param1 = the player, as vanilla adds it.
            option.onSelect = function(container, playerObj)
                request(playerObj, container:getParent(), container)
            end
        end
    end
end
