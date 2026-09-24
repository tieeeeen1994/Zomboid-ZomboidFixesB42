--[[
    Zomboid Fixes B42.20 -- client, admin chopper controls

    Puts Send Chopper and Stop Chopper in the right-click admin Tools menu, which
    admins and moderators have on a server without -debug. The debug menu's Game
    panel buttons, Add Chopper and Remove Chopper, go the same way. Both ask the
    server file, which explains what vanilla's /chopper stop gets wrong.

    Needs MakeEventsAlarmGunshot, the same as the /chopper command. Single player is
    left alone: there the debug buttons run the chopper directly and nothing is
    sent anywhere.
--]]

if not isClient() then return end

require "ISUI/ISContextMenu"
require "ISUI/ISWorldObjectContextMenu"
-- Required so that its Tools menu is built before this file adds to it: handlers
-- for the same event run in the order they were added.
require "DebugUIs/AdminContextMenu"
require "DebugUIs/DebugMenu/General/ISGameDebugPanel"

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- The debug panel's own button ids, ID_START_CHOPPER and ID_END_CHOPPER, which
-- are locals in ISGameDebugPanel.lua.
local DEBUG_START_CHOPPER = 1
local DEBUG_END_CHOPPER = 2

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ChopperControls == true
end

local function canUse(player)
    local role = player and player:getRole()
    return role ~= nil and role:hasCapability(Capability.MakeEventsAlarmGunshot)
end

local function send(player, action)
    sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_CHOPPER, { action = action })
end

local function addOption(menu, player, textKey, tooltipKey, action)
    local option = menu:addOption(getText(textKey), player, send, action)
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip.description = getText(tooltipKey)
    option.toolTip = tooltip
    return option
end

-- Admin Tools menu ---------------------------------------------------------------

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    if not isEnabled() then return end

    local player = getSpecificPlayer(playerNum)
    if not canUse(player) then return end

    -- AdminContextMenu.doMenu's Tools submenu. A role that may use /chopper but is
    -- neither admin nor moderator does not get that menu, so the chopper gets a
    -- debug entry of its own. addDebugOption drops it again when debug context
    -- menu options are hidden, as it does Tools.
    local tools = context:getOptionFromName("Tools")
    local parent = tools and tools.subOption and context:getSubMenu(tools.subOption)
    local option
    if parent then
        option = parent:addOption(getText("IGUI_ZomboidFixesB42_Chopper"), worldobjects, nil)
    else
        parent = context
        option = context:addDebugOption(getText("IGUI_ZomboidFixesB42_Chopper"), worldobjects, nil)
    end

    local menu = parent:getNew(parent)
    parent:addSubMenu(option, menu)
    addOption(menu, player, "IGUI_ZomboidFixesB42_Chopper_Send", "IGUI_ZomboidFixesB42_Chopper_SendTooltip", "start")
    addOption(menu, player, "IGUI_ZomboidFixesB42_Chopper_Stop", "IGUI_ZomboidFixesB42_Chopper_StopTooltip", "stop")
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

-- Debug menu Game panel ----------------------------------------------------------

-- The panel's buttons look this function up when the panel is opened, so they
-- pick up this version.
local vanillaGameDebugClick = ISGameDebugPanel.onClick

function ISGameDebugPanel:onClick(button)
    local command = button and button.customData and button.customData.command
    if (command == DEBUG_START_CHOPPER or command == DEBUG_END_CHOPPER) and isEnabled() then
        local player = getPlayer()
        if canUse(player) then
            send(player, command == DEBUG_START_CHOPPER and "start" or "stop")
            return
        end
    end
    return vanillaGameDebugClick(self, button)
end

-- Replies ------------------------------------------------------------------------

local RESULT_TEXT = {
    sent = "IGUI_ZomboidFixesB42_Chopper_Sent",
    stopped = "IGUI_ZomboidFixesB42_Chopper_Stopped",
    denied = "IGUI_ZomboidFixesB42_Chopper_Denied",
    disabled = "IGUI_ZomboidFixesB42_Chopper_Disabled",
}

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_CHOPPER_RESULT then return end
    if type(args) ~= "table" then return end

    local key = RESULT_TEXT[args.result]
    local player = getPlayer()
    if not key or not player then return end

    if args.result == "sent" or args.result == "stopped" then
        HaloTextHelper.addText(player, getText(key))
    else
        HaloTextHelper.addBadText(player, getText(key))
    end
end

Events.OnServerCommand.Add(onServerCommand)
