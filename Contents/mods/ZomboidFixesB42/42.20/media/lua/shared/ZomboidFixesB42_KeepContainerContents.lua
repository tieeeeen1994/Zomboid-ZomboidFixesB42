--[[
    Zomboid Fixes B42.20 -- shared, scrapping a container no longer deletes what is in it

    A craft input that is consumed destroys the item, and an InventoryContainer goes
    with everything inside it. Recipes that take containers mark the input
    flags[IsEmpty] (InputScript.doesItemPassIsOrNotEmptyAndFullTests: a container
    with items fails), and the separate IsEmptyContainer flag does nothing
    (CraftRecipeManager.consumeInputItemInternal ~800 only logs it, the return false
    is missing). These 42.21 recipes consume a container without either:

      * Scrap_Smaller_Gold_Object / Scrap_Smaller_Silver_Object: tags
        smallergoldscrap / smallersilverscrap, which include the forged gold and
        silver key rings (KeyRing_Forged_Gold / _Silver). Scrapping one used as a
        key ring deletes every key on it (forum 101057: all of a player's car keys).
      * ScrapSack, ScrapSackLarge (burlap sacks, sandbags, laundry and mail bags),
        CutHeadSack (sacks among holddirt / cutheadsack), MakeHollowBook (a hollow
        book, with whatever was hidden in it, is accepted as the book).

    The list comes from every craftRecipe input that is not mode:keep and accepts an
    item of ItemType base:container, minus those already flagged IsEmpty. Input
    flags cannot be added from Lua, so each of these recipes gets an OnTest
    (CraftRecipe.OnTestItem, asked for every candidate input item, on the client for
    the crafting window and on the server for the craft) that turns down a
    container with something in it. None of them had an OnTest; their tools are
    never containers, so the test only ever applies to the consumed input. The
    player empties it first, like a bag in the recipes vanilla flags.
--]]

require "ZomboidFixesB42_ScriptFixes"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local ScriptFixes = ZomboidFixesB42.ScriptFixes

local OPTION = "KeepContainerContents"

local RECIPES = {
    "Scrap_Smaller_Gold_Object",
    "Scrap_Smaller_Silver_Object",
    "ScrapSack",
    "ScrapSackLarge",
    "CutHeadSack",
    "MakeHollowBook",
}

--- OnTest for the recipes above: no container that still holds something.
-- Reads the option itself, so switching it off needs no change to the recipes.
function ZomboidFixesB42.RecipeOnTestEmptyContainer(item, character)
    if not ScriptFixes.isEnabled(OPTION) then return true end
    if instanceof(item, "InventoryContainer") then
        local inventory = item:getInventory()
        if inventory and not inventory:isEmpty() then return false end
    end
    return true
end

ScriptFixes.register(OPTION, "ScrapFullContainers",
    function()
        for _, name in ipairs(RECIPES) do
            local recipe = ScriptFixes.getRecipe(name)
            if recipe then
                ScriptFixes.setRecipeCall(recipe, "OnTest", "ZomboidFixesB42.RecipeOnTestEmptyContainer")
            end
        end
    end,
    function()
        -- The test passes everything while the option is off.
    end)
