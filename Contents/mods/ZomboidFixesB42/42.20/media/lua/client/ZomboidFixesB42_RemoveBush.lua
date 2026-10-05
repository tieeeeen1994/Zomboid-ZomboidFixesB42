--[[
    Zomboid Fixes B42.20 -- client, the inventory refreshes when the server swaps
    a broken tool

    When the server swaps a broken tool for another (ItemUtils.checkWeapon, from
    removing a bush, breaking up rocks or stumps, destroying with a sledgehammer,
    building) or uses up building
    materials (ISBuildUtil, ISMultiStageBuild, GraveHelper), it asks the player's
    client to refresh its inventory windows with

        sendServerCommand(player, 'ui', 'dirtyUI', {})

    but the client's handler is Commands.ui.DirtyUI (client/ServerCommands.lua ~145)
    with a capital D, and ServerCommands.OnServerCommand looks commands up by exact
    name, so nothing happens. The command is answered here under its lower-case
    name. The server side of the tool fixes is in server/ZomboidFixesB42_RemoveBush.lua
    and server/ZomboidFixesB42_PickAxeWear.lua (same option).
--]]

if not isClient() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.RemoveBushToolWear == true
end

local function onServerCommand(module, command, args)
    if module ~= "ui" or command ~= "dirtyUI" or not isEnabled() then return end
    ISInventoryPage.dirtyUI()
end

Events.OnServerCommand.Add(onServerCommand)
