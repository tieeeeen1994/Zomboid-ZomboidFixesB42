--[[
    Zomboid Fixes B42.20 -- client, barricading with no plank left

    The right-click Barricade option (ISWorldObjectContextMenu.onBarricade, 42.21)
    puts up an ISBuildIsoEntity cursor with dragNilAfterPlace = false, so it stays
    after each barricade. Unlike the build panel's cursor (blockAfterPlace, and the
    panel re-checks canPerformCurrentRecipe), nothing re-checks the materials:
    ISBuildingObject:haveMaterial only looks at "need:" entries in modData, which an
    entity recipe has none of, so ISBuildIsoEntity:isValid stays true. With the last
    plank used, the cursor still places, the build action runs to the end, and the
    server's create() then fails in performCurrentRecipe ("consume failed"): nothing
    is built (forum 100313). Placing several barricades in a row queues several
    actions while the first plank is still in the inventory, which ends the same way.

    So the plank barricade's cursor turns red, and its queued build action stops
    before it starts, once the inventory and nearby containers (the crafting
    window's ISInventoryPaneContextMenu.getContainers) no longer hold a plank and the
    nails it takes (2 with this option, see shared/ZomboidFixesB42_Barricade.lua).
    The action is checked while it runs too, since the server only takes the
    materials when it ends. Counts are re-read at most every 300 ms. Metal
    barricades use the same cursor but other materials and are left alone. The
    build cheat skips the check, as vanilla does.

    ISBuildIsoEntity lives in media/lua/server, which is not loaded (nor on the
    require paths) when the client files first load at the main menu, so its
    isValid is wrapped at OnGameStart, after the game has loaded the server folder.
--]]

require "ISUI/ISWorldObjectContextMenu"
require "BuildingObjects/TimedActions/ISBuildAction"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local PLANK_SPRITE = "carpentry_01_8"
local RECHECK_MS = 300

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.BarricadeFixes == true
end

local function isCheat(character)
    return character:isBuildCheat() or (ISBuildMenu ~= nil and ISBuildMenu.cheat == true)
end

local function countIn(containers, fullType)
    local count = 0
    for i = 0, containers:size() - 1 do
        count = count + containers:get(i):getCountTypeRecurse(fullType)
    end
    return count
end

--- True while the character can still pay for one plank barricade.
local function hasMaterials(character)
    local containers = ISInventoryPaneContextMenu.getContainers(character)
    if not containers then return true end
    local nails = ZomboidFixesB42.barricadeNailsNeeded and ZomboidFixesB42.barricadeNailsNeeded() or 1
    return countIn(containers, "Base.Plank") >= 1 and countIn(containers, "Base.Nails") >= nails
end

--- `holder.zfixMaterialsOk`, re-read every RECHECK_MS.
local function materialsOk(holder, character)
    local now = getTimestampMs()
    if holder.zfixMaterialsMs == nil or now - holder.zfixMaterialsMs >= RECHECK_MS then
        holder.zfixMaterialsMs = now
        holder.zfixMaterialsOk = hasMaterials(character)
    end
    return holder.zfixMaterialsOk
end

--- Wraps ISBuildIsoEntity.isValid once per class table (Lua reloads rebuild it).
local wrappedCursorClass = nil

local function wrapCursorIsValid()
    if ISBuildIsoEntity == nil or wrappedCursorClass == ISBuildIsoEntity then return end
    wrappedCursorClass = ISBuildIsoEntity
    local vanillaIsValid = ISBuildIsoEntity.isValid

    function ISBuildIsoEntity:isValid(square, ...)
        local valid = vanillaIsValid(self, square, ...)
        if not valid or not self.zfixPlankBarricade or not isEnabled() then return valid end
        local character = self.character
        if not character or isCheat(character) then return valid end
        -- Only the cursor itself: create() calls isValid on the copy the build action
        -- carries, after the materials it is about to use were counted.
        if getCell():getDrag(character:getPlayerNum()) ~= self then return valid end
        return materialsOk(self, character)
    end
end

Events.OnGameStart.Add(wrapCursorIsValid)

local vanillaOnBarricade = ISWorldObjectContextMenu.onBarricade

function ISWorldObjectContextMenu.onBarricade(spriteName, playerObj, ...)
    wrapCursorIsValid()
    local result = vanillaOnBarricade(spriteName, playerObj, ...)
    if spriteName == PLANK_SPRITE and playerObj then
        local drag = getCell():getDrag(playerObj:getPlayerNum())
        if drag then drag.zfixPlankBarricade = true end
    end
    return result
end

local vanillaActionIsValid = ISBuildAction.isValid

function ISBuildAction:isValid(...)
    local valid = vanillaActionIsValid(self, ...)
    if not valid or not self.item or not self.item.zfixPlankBarricade or not isEnabled() then return valid end
    if isCheat(self.character) then return valid end
    -- Checked for the whole action: the materials are only taken when it ends
    -- (create() on the server), so a plank that is gone by then means a build that
    -- would fail. In multiplayer that also catches the previous barricade's plank
    -- leaving the inventory a moment after its action ended.
    return materialsOk(self, self.character)
end
