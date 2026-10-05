--[[
    Zomboid Fixes B42.20 -- client, world map admin tools by capability

    The world map's admin extras are gated on the access level name, not on the
    role's capabilities (client/ISUI/Maps, 42.21):

      * ISWorldMap:onRightMouseUp (~911): the right-click menu with Teleport Here
        (`/teleportto x,y,0`), the cell and tile grids, Hide Unvisited Areas,
        isometric view and the virtual animal tools;
      * WorldMapOptions:createChildren / synchUI (~36, ~166) and
        ISMiniMapOptionsPanel:synchUI (~130): every map render option instead of
        the short player list.

    all behind `getDebug() or (isClient() and getAccessLevel() == "admin")`. So a
    moderator, or any custom role, gets none of it even with the capability the
    server checks for /teleportto (TeleportToCoordinates). Which remote players the
    map shows is decided in Java by capabilities already
    (UIWorldMap.isAdminSeeRemotePlayers: CanSeeAll), so that part needs nothing.

    While those four functions run, getAccessLevel answers "admin" for a role with
    TeleportToCoordinates or UseDebugContextMenu (what the debug context menu asks
    for). The server still checks /teleportto itself. Only on a client: in single
    player vanilla's getDebug() rule stays, and getAccessLevel() would throw there.
--]]

if not isClient() then return end

require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.MapAdminCapabilities ~= false
end

local function hasMapAdminTools()
    local player = getSpecificPlayer(0)
    local role = player and player:getRole()
    if not role then return false end
    return role:hasCapability(Capability.TeleportToCoordinates) or role:hasCapability(Capability.UseDebugContextMenu)
end

--- Wrap fn so that, for such a role, vanilla's access level test passes.
local function asMapAdmin(fn)
    return function(...)
        if not isEnabled() or not hasMapAdminTools() then
            return fn(...)
        end
        local vanillaGetAccessLevel = getAccessLevel
        getAccessLevel = function() return "admin" end
        local ok, result = pcall(fn, ...)
        getAccessLevel = vanillaGetAccessLevel
        if not ok then error(result) end
        return result
    end
end

WorldMapOptions.createChildren = asMapAdmin(WorldMapOptions.createChildren)
WorldMapOptions.synchUI = asMapAdmin(WorldMapOptions.synchUI)
ISMiniMapOptionsPanel.synchUI = asMapAdmin(ISMiniMapOptionsPanel.synchUI)
ISWorldMap.onRightMouseUp = asMapAdmin(ISWorldMap.onRightMouseUp)
