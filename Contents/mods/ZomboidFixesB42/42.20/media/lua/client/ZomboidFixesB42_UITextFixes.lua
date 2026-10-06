--[[
    Zomboid Fixes B42.20 -- client, small text and menu typos

    Three vanilla UI functions read a global that was meant to be a local or a
    field (42.21), each nil:

      * Faction invitation. ISFactionUI.ReceiveFactionInvite(faction, host, username)
        (client/ISUI/UserPanel/ISFactionUI.lua ~410) builds the dialog with
        getText("IGUI_FactionUI_Invitation", host, factionName): the parameter is
        `faction` (the Faction object acceptFactionInvite takes), so the dialog
        reads "<host> is inviting you to null faction". The handler is registered
        on Events.ReceiveFactionInvite by reference, so it is swapped there.
      * Manage inventory title. ISPlayerStatsManageInvUI:prerender (~215) centres
        "Manage <name>'s Inventory" by measuring
        getText("IGUI_PlayerStats_ManageInventory", playerUsername) instead of
        self.playerUsername, so the title is measured without the name and drawn off
        centre.
      * The Gardening menu's "Not enough soil to plant here." ISFarmingMenu.doDigMenu
        (~141) adds it, greyed out, when a digging tool is in the inventory and the
        square cannot be dug, `and not currentPlant` -- a local of doFarmingMenu2,
        nil here. A square with a crop or a plowed furrow cannot be dug
        (canDigHereSquare), so right-clicking any crop with a trowel or shovel
        anywhere in the inventory showed it next to the crop's own options (single
        player too).

    The last two are fixed by giving the global the value vanilla meant for the
    duration of the call (and putting the old value back), so the rest of each
    function stays vanilla's.
--]]

require "ISUI/UserPanel/ISFactionUI"
require "ISUI/PlayerStats/ISPlayerStatsManageInvUI"
require "Farming/ISUI/ISFarmingMenu"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.UITextFixes == true
end

-- ---------------------------------------------------------------------------
-- Faction invitation
-- ---------------------------------------------------------------------------

local vanillaReceiveFactionInvite = ISFactionUI.ReceiveFactionInvite

local function receiveFactionInvite(faction, host, username)
    if not isEnabled() then
        return vanillaReceiveFactionInvite(faction, host, username)
    end

    if ISFactionUI.inviteDialogs[host] then
        if ISFactionUI.inviteDialogs[host]:isReallyVisible() then return end
        ISFactionUI.inviteDialogs[host] = nil
    end
    if Faction.getPlayerFaction(getPlayer()) then return end

    local name = faction
    if faction and type(faction) ~= "string" then name = faction:getName() end

    local modal = ISModalDialog:new(getCore():getScreenWidth() / 2 - 175, getCore():getScreenHeight() / 2 - 75, 350, 150,
        getText("IGUI_FactionUI_Invitation", host, tostring(name)), true, nil, ISFactionUI.onAnswerFactionInvite)
    modal:initialise()
    modal:addToUIManager()
    modal.faction = faction
    modal.host = host
    modal.username = username
    modal.moveWithMouse = true
    ISFactionUI.inviteDialogs[host] = modal
end

Events.ReceiveFactionInvite.Remove(vanillaReceiveFactionInvite)
Events.ReceiveFactionInvite.Add(receiveFactionInvite)
ISFactionUI.ReceiveFactionInvite = receiveFactionInvite

-- ---------------------------------------------------------------------------
-- Manage inventory title
-- ---------------------------------------------------------------------------

local vanillaManageInvPrerender = ISPlayerStatsManageInvUI.prerender

function ISPlayerStatsManageInvUI:prerender(...)
    if not isEnabled() then
        return vanillaManageInvPrerender(self, ...)
    end
    local saved = playerUsername
    playerUsername = self.playerUsername
    local ok, err = pcall(vanillaManageInvPrerender, self, ...)
    playerUsername = saved
    if not ok then error(err) end
end

-- ---------------------------------------------------------------------------
-- "Not enough soil to plant here." on crops
-- ---------------------------------------------------------------------------

local function plantOn(worldobjects)
    if not CFarmingSystem or not CFarmingSystem.instance then return nil end
    for _, obj in ipairs(worldobjects or {}) do
        local square = obj and obj:getSquare()
        local plant = square and CFarmingSystem.instance:getLuaObjectOnSquare(square)
        if plant then return plant end
    end
    return nil
end

local vanillaDoDigMenu = ISFarmingMenu.doDigMenu

ISFarmingMenu.doDigMenu = function(playerObj, context, worldobjects, test, ...)
    if not isEnabled() then
        return vanillaDoDigMenu(playerObj, context, worldobjects, test, ...)
    end
    local saved = currentPlant
    currentPlant = plantOn(worldobjects)
    local ok, result = pcall(vanillaDoDigMenu, playerObj, context, worldobjects, test, ...)
    currentPlant = saved
    if not ok then error(result) end
    return result
end
