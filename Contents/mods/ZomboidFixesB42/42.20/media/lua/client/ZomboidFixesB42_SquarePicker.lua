--[[
    Zomboid Fixes B42.20 -- client, square pickers no longer walk the character

    The debug Horde Manager's "Pick new square" (ISSpawnHordeUI:onSelectNewSquare,
    ISSpawnHordeUI.lua:361) and the Tile Picker's (ISTilesPickerDebugUI.lua:116) put an
    ISSelectCursor on the map. ISSelectCursor (server/BuildingObjects/ISSelectCursor.lua)
    is an ISBuildingObject, so a click goes through ISBuildingObject:tryBuild, which runs
    `ISBuildMenu.cheat or self:walkTo(x, y, z)` (ISBuildingObject.lua:208) before it calls
    create. walkTo walks the player next to the square (luautils.walkAdj) unless the
    cursor has skipWalk2 set (ISBuildingObject.lua:299). ISSelectCursor sets
    skipBuildAction and noNeedHammer but never skipWalk2, so picking a square sends the
    admin's character walking over to it, sometimes across the map. Only the build
    cheat hides it. ISBrushToolTileCursor, the other admin-only cursor, does set it.

    ISSelectCursor is only ever used as a picker (vanilla's two debug windows, and the
    admin hotbar, which already sets skipWalk2 itself), so set skipWalk2 on every one
    it creates. Picking then just selects the square, as with the build cheat on.

    ISSelectCursor lives in media/lua/server, which loads after client files, so the
    wrapper is installed from OnGameStart. The option is read on every new cursor, so
    changing it mid-game takes effect with the next pick.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.NoWalkOnSquarePick == true
end

local function install()
    if ISSelectCursor == nil then return end

    local previousNew = ISSelectCursor.new

    function ISSelectCursor:new(...)
        local o = previousNew(self, ...)
        if o and isEnabled() then
            o.skipWalk2 = true
        end
        return o
    end
end

Events.OnGameStart.Add(install)
