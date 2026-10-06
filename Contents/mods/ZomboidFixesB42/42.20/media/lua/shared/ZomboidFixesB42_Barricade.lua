--[[
    Zomboid Fixes B42.20 -- shared, plank barricades take two nails

    Barricading with planks is no longer a timed action of its own in 42.21:
    ISWorldObjectContextMenu.onBarricade puts up a build cursor for the entity
    BarricadePlanks (scripts/generated/entities/barricades/entity_barricade_planks.txt),
    whose CraftRecipe takes a hammer, 1 plank and 1 nail. The right-click menu that
    offers it (ISWorldObjectContextMenuLogic.doBarricadeMenu, Java) still asks for 2
    nails, as barricading did in 41, so a player with one nail is told nothing and
    one with two keeps one (forum 100019). The sprite shows four.

    The menu cannot be changed from Lua, so the recipe follows it: a second
    `item 1 [Base.Nails] flags[DontRecordInput]` input is appended. Each input takes
    its own nail, the build panel lists both and checks for two, and BuildRecipeCode
    .barricade.OnCreate still finds the plank first among the recorded inputs
    (nails are not recorded). Client and server both run this file with the same
    sandbox option, so the recipe's inputs, which the network addresses by index,
    stay the same on both.

    How: CraftRecipe.Load on a loaded recipe appends an inputs block (LoadIO), and
    InputScript.OnPostWorldDictionaryInit, which resolves the item, is protected, so
    the whole recipe's runs again. That is safe to repeat: items are only added when
    missing (the sealed fluid filter logs one "attempting setFilterType on sealed
    filter" line per input), but every input adds the recipe's name to its items'
    getUsedInRecipes again, so the copies are taken out. Load also resets the
    display name, which the entity had overridden, so it is put back.

    The cursor half of this fix (barricading on with no plank left) is in
    client/ZomboidFixesB42_Barricade.lua, under the same option.
--]]

require "ZomboidFixesB42_ScriptFixes"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local ScriptFixes = ZomboidFixesB42.ScriptFixes

local OPTION = "BarricadeFixes"
local NAILS_LINE = "item 1 [Base.Nails] flags[DontRecordInput]"

local function barricadeRecipe()
    local manager = ScriptManager.instance
    local script = manager:getGameEntityScript("Base.BarricadePlanks") or manager:getGameEntityScript("BarricadePlanks")
    local component = script and script:getComponentScriptFor(ComponentType.CraftRecipe)
    local recipe = component and component:getCraftRecipe()
    if not recipe then ScriptFixes.log("BarricadePlanks recipe not found") end
    return recipe
end

--- Nails a plank barricade takes with the fix in place.
function ZomboidFixesB42.barricadeNailsNeeded()
    return ScriptFixes.isEnabled(OPTION) and 2 or 1
end

--- Leaves one copy of `name` in each input item's used-in list.
local function dedupeUsedIn(recipe)
    local name = recipe:getName()
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local items = inputs:get(i):getPossibleInputItems()
        for j = 0, items:size() - 1 do
            local used = items:get(j):getUsedInRecipes()
            local count = 0
            for k = 0, used:size() - 1 do
                if used:get(k) == name then count = count + 1 end
            end
            while count > 1 do
                used:remove(name)
                count = count - 1
            end
        end
    end
end

local added = nil

ScriptFixes.register(OPTION, "BarricadeTwoNails",
    function()
        added = nil
        local recipe = barricadeRecipe()
        if not recipe then return end
        local inputs = recipe:getInputs()
        local before = inputs:size()
        local displayName = recipe:getTranslationName()
        recipe:Load(recipe:getName(), "craftRecipe " .. recipe:getName() .. " { inputs { " .. NAILS_LINE .. ", } }")
        recipe:overrideTranslationName(displayName)
        if inputs:size() ~= before + 1 then
            ScriptFixes.log("BarricadeTwoNails: the nails input was not added")
            return
        end
        added = inputs:get(before)
        recipe:OnPostWorldDictionaryInit()
        dedupeUsedIn(recipe)
    end,
    function()
        local recipe = added and barricadeRecipe()
        if recipe then
            recipe:getInputs():remove(added)
            recipe:getIoLines():remove(added)
        end
        added = nil
    end)
