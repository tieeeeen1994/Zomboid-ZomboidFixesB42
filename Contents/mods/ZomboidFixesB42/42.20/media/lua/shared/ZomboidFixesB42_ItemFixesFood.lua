--[[
    Zomboid Fixes B42.20 -- shared, food, cooking recipe and other item data fixes

    Mistakes in items/food.txt, recipes_cooking.txt, recipes_baking.txt,
    recipes_farming.txt and a few other items (42.21), each behind its own sandbox
    option; the machinery is in ZomboidFixesB42_ScriptFixes.lua.

    ForgedPotPasta: WaterPotForgedPasta (pasta cooked in a forged pot) has
    `ReplaceOnUse = Base.Pot`, so eating it gives back a normal cooking pot; the
    forged rice, stew and soup pots give back Base.PotForged. A food copies
    ReplaceOnUse when it is created and that copy is not saved, so pots already
    loaded are also corrected just before they are eaten or emptied.

    FoodNutrition: Leek has 140 g of carbohydrates for 54 kcal (a real leek of the
    same kcal has 12.6 g; lipids and proteins already match), and CannedLeek, four
    leeks' worth, carries 560. Grapefruit has 15 kcal with 101 g carbohydrates,
    3.8 g lipids and 17.6 g proteins; it now has a 300 g grapefruit's values. Food
    saves its nutrition, so only food created from now on changes.

    CopperSaucepanBowls: "Split into 2/4 bowls" (Make2Bowls / Make4Bowls) takes any
    tags[base:canbedividedinbowls] pot and maps it through two itemMappers, bowlType
    (the bowl food) and potType (the empty pot given back). Pasta in a copper
    saucepan (PastaPanCopper) has the tag and a bowlType entry but no potType entry,
    so the recipe has no pot to give back; rice in one (RicePanCopper) has neither
    the tag nor a bowlType entry. The fix adds the tag (and so the recipe input),
    RicePanCopper -> RiceBowl, and PastaPanCopper / RicePanCopper -> SaucepanCopper.

    ClayBowlPortions: the bowlType mapper lists `PastaBowl = PastaPan` before
    `PastaBowlClay = PastaPan` and only the pot input is registered in it, so the
    first entry always wins and clay bowls come back as normal bowls (Make4Bowls
    even has only `StewBowlClay = PotForgedStew`, so there normal bowls come back as
    clay ones). The fix registers the bowl input in the mapper too and puts an
    entry for each pot with each bowl ([pot, ClayBowl] -> the Clay food, [pot, Bowl]
    -> the plain one) in front. With mixed bowls the last bowl put in decides.
    Bowl of beans, oatmeal and cereal (MakeBowlOfBeans / Oatmeal / Cereal) have no
    clay variant, so they give back a normal bowl when eaten. ISHandcraftAction
    records every consumed type in a single result's modData
    (modData["Base.ClayBowl"] = 1), so such a food's ReplaceOnUse is set to the clay
    bowl just before it is eaten, emptied or added to a recipe. Cake batter made in
    a clay bowl carries the same record, and PlaceCakeInBakingPan's plain Bowl
    output is swapped for a clay bowl then (an OnCreate this fix gives the recipe).

    SeedPacketCount: PutSeedsInPacket takes 5 seeds of every kind but 25 pumpkin or
    sunflower seeds (`25:Base.PumpkinSeed`, `25:Base.SunflowerSeeds`), while
    OpenPacketOfSeeds always gives 5, so 20 seeds vanish every time. An input's
    per-item amounts cannot be changed from Lua, so opening a pumpkin or sunflower
    packet now gives 25 (an OnCreate adds the missing 20).

    ItemWeights: every pie slice (Pie is the cherry slice, PieApple...) weighs 0.5,
    as much as the raw whole pie it is cut from (PieWholeRaw 0.5 plus its
    ingredients); cake slices weigh 0.2, and so do pie slices now. A slice's weight
    still grows with how filling it is (Food.getActualWeight scales the script
    weight by hunger / script hunger), which is also why bowls from a very filling
    pot weigh a lot; that is engine code. The .44 Magnum box holds 20 rounds of
    0.03 (0.6) but weighs 1.2; every other box weighs 75-100% of its rounds and
    every carton ten boxes, so it is 0.48 and its carton 4.8.

    MinorItemFixes: HotDrinkRed gives back `Base.MugRed`, which does not exist
    (red mugs are Base.Mugl, a mug with several colours); the Rangers baseball shirt
    covers UpperBody while the other two baseball shirts cover Shirt (arms too);
    the red baseball cap falls off at 80 while the other 69 caps use 60; the
    seafood cooler has no open, close or put-in sounds (the other coolers use
    OpenCooler / CloseCooler / StoreItemCooler). Missing English names
    (HotDrinkMetal, Copper, Gold, Silver, Tumbler, FruitSaladClay) are in
    Translate/EN/ItemName.json.
--]]

require "ZomboidFixesB42_ScriptFixes"

local ScriptFixes = ZomboidFixesB42.ScriptFixes

-- ForgedPotPasta --------------------------------------------------------------------

ScriptFixes.register("ForgedPotPasta",
    function()
        ScriptFixes.setParams({ ["Base.WaterPotForgedPasta"] = { ReplaceOnUse = "Base.PotForged" } })
    end,
    function()
        ScriptFixes.setParams({ ["Base.WaterPotForgedPasta"] = { ReplaceOnUse = "Base.Pot" } })
    end)

ScriptFixes.onBeforeUse(function(item)
    if item:getFullType() == "Base.WaterPotForgedPasta" and item:getReplaceOnUse() == "Base.Pot"
            and ScriptFixes.isEnabled("ForgedPotPasta") then
        item:setReplaceOnUse("Base.PotForged")
    end
end)

-- FoodNutrition ---------------------------------------------------------------------

ScriptFixes.register("FoodNutrition",
    function()
        ScriptFixes.setParams({
            ["Base.Leek"] = { Carbohydrates = "12.6" },
            ["Base.CannedLeek"] = { Carbohydrates = "50.4" },
            ["Base.Grapefruit"] = { Calories = "126.0", Carbohydrates = "32.1", Lipids = "0.42", Proteins = "2.31" },
        })
    end,
    function()
        ScriptFixes.setParams({
            ["Base.Leek"] = { Carbohydrates = "140.0" },
            ["Base.CannedLeek"] = { Carbohydrates = "560.0" },
            ["Base.Grapefruit"] = { Calories = "15.0", Carbohydrates = "101.11", Lipids = "3.78", Proteins = "17.56" },
        })
    end)

-- Splitting a pot into bowls ------------------------------------------------------

local SPLIT_RECIPES = { "Base.Make2Bowls", "Base.Make4Bowls" }

--- The bowl food mapper, the empty pot mapper and the bowl input of a split recipe.
local function splitRecipeParts(recipe)
    local bowlMapper, potMapper
    local pastaBowl = ScriptFixes.getItem("Base.PastaBowl")
    local saucepan = ScriptFixes.getItem("Base.Saucepan")
    local outputs = recipe:getOutputs()
    for i = 0, outputs:size() - 1 do
        local mapper = outputs:get(i):getOutputMapper()
        if mapper then
            local results = mapper:getResultItems()
            if results:contains(pastaBowl) then bowlMapper = mapper end
            if results:contains(saucepan) then potMapper = mapper end
        end
    end
    local bowlInput
    local clayBowl = ScriptFixes.getItem("Base.ClayBowl")
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        if input:getPossibleInputItems():contains(clayBowl) then bowlInput = input end
    end
    return bowlMapper, potMapper, bowlInput
end

--- Adds resolved mapper entries and remembers them in `added` for removeEntries.
-- `front` puts them at the start of the list, in order.
local function addEntries(added, mapper, entries, front)
    local list = mapper:getEntrees()
    local index = 0
    for _, entry in ipairs(entries) do
        local resolved = ScriptFixes.newMapperEntry(entry[1], entry[2])
        if resolved then
            if front then
                list:add(index, resolved)
                index = index + 1
            else
                list:add(resolved)
            end
            added[#added + 1] = { mapper = mapper, entry = resolved }
        end
    end
end

local function removeEntries(added)
    for _, a in ipairs(added) do
        a.mapper:getEntrees():remove(a.entry)
    end
end

-- CopperSaucepanBowls ---------------------------------------------------------------

local copperAdded = {}

ScriptFixes.register("CopperSaucepanBowls",
    function()
        copperAdded = {}
        ScriptFixes.addTag("Base.RicePanCopper", "base:canbedividedinbowls")
        for _, name in ipairs(SPLIT_RECIPES) do
            local recipe = ScriptFixes.getRecipe(name)
            local bowlMapper, potMapper
            if recipe then bowlMapper, potMapper = splitRecipeParts(recipe) end
            if bowlMapper and potMapper then
                addEntries(copperAdded, bowlMapper, {
                    { "Base.RiceBowl", { "Base.RicePanCopper" } },
                })
                addEntries(copperAdded, potMapper, {
                    { "Base.SaucepanCopper", { "Base.PastaPanCopper" } },
                    { "Base.SaucepanCopper", { "Base.RicePanCopper" } },
                })
            elseif recipe then
                ScriptFixes.log("CopperSaucepanBowls: mappers not found in " .. name)
            end
        end
    end,
    function()
        removeEntries(copperAdded)
        copperAdded = {}
        ScriptFixes.removeTag("Base.RicePanCopper", "base:canbedividedinbowls")
    end)

-- ClayBowlPortions ------------------------------------------------------------------

-- Every pot the split recipes take, and the plain bowl food it becomes.
local POT_TO_BOWL = {
    { "Base.PastaPan", "Base.PastaBowl" },
    { "Base.PastaPanCopper", "Base.PastaBowl" },
    { "Base.PastaPot", "Base.PastaBowl" },
    { "Base.PastaPotForged", "Base.PastaBowl" },
    { "Base.WaterPotPasta", "Base.PastaBowl" },
    { "Base.WaterPotForgedPasta", "Base.PastaBowl" },
    { "Base.WaterSaucepanPasta", "Base.PastaBowl" },
    { "Base.WaterSaucepanPastaCopper", "Base.PastaBowl" },
    { "Base.RicePan", "Base.RiceBowl" },
    { "Base.RicePanCopper", "Base.RiceBowl" },
    { "Base.RicePot", "Base.RiceBowl" },
    { "Base.RicePotForged", "Base.RiceBowl" },
    { "Base.WaterPotRice", "Base.RiceBowl" },
    { "Base.WaterPotForgedRice", "Base.RiceBowl" },
    { "Base.WaterSaucepanRice", "Base.RiceBowl" },
    { "Base.WaterSaucepanRiceCopper", "Base.RiceBowl" },
    { "Base.PotOfSoup", "Base.SoupBowl" },
    { "Base.PotOfSoupRecipe", "Base.SoupBowl" },
    { "Base.PotForgedSoupRecipe", "Base.SoupBowl" },
    { "Base.PotOfStew", "Base.StewBowl" },
    { "Base.PotForgedStew", "Base.StewBowl" },
}

local clayAdded = {}
-- Mappers the bowl input was registered in, this game (never undone: with only the
-- vanilla single-pot entries it matches nothing).
local clayRegistered = {}
local cakeCallSet = {}

local function clayEnabled()
    return ScriptFixes.isEnabled("ClayBowlPortions")
end

ScriptFixes.register("ClayBowlPortions",
    function()
        clayAdded = {}
        for _, name in ipairs(SPLIT_RECIPES) do
            local recipe = ScriptFixes.getRecipe(name)
            local bowlMapper, _, bowlInput
            if recipe then bowlMapper, _, bowlInput = splitRecipeParts(recipe) end
            if bowlMapper and bowlInput then
                if not clayRegistered[bowlMapper] then
                    bowlMapper:registerInputScript(bowlInput)
                    clayRegistered[bowlMapper] = true
                end
                local entries = {}
                for _, pair in ipairs(POT_TO_BOWL) do
                    entries[#entries + 1] = { pair[2] .. "Clay", { pair[1], "Base.ClayBowl" } }
                    entries[#entries + 1] = { pair[2], { pair[1], "Base.Bowl" } }
                end
                addEntries(clayAdded, bowlMapper, entries, true)
            elseif recipe then
                ScriptFixes.log("ClayBowlPortions: bowl mapper or input not found in " .. name)
            end
        end

        local cake = ScriptFixes.getRecipe("Base.PlaceCakeInBakingPan")
        if cake and not cakeCallSet[cake] then
            ScriptFixes.setRecipeCall(cake, "OnCreate", "ZomboidFixesB42.OnCreateCakeInPan")
            cakeCallSet[cake] = true
        end
    end,
    function()
        removeEntries(clayAdded)
        clayAdded = {}
    end)

local function madeWithClayBowl(item)
    return item:hasModData() and item:getModData()["Base.ClayBowl"] ~= nil
end

ScriptFixes.onBeforeUse(function(item)
    local replace = item:getReplaceOnUse()
    if (replace == "Base.Bowl" or replace == "Bowl") and clayEnabled() and madeWithClayBowl(item) then
        item:setReplaceOnUse("Base.ClayBowl")
    end
end)

--- OnCreate of PlaceCakeInBakingPan: batter made in a clay bowl gives the clay bowl back.
-- Runs where the craft is performed (the server, or single player).
function ZomboidFixesB42.OnCreateCakeInPan(data, character)
    if not clayEnabled() then return end
    local fromClay = false
    local consumed = data:getAllConsumedItems()
    for i = 0, consumed:size() - 1 do
        local item = consumed:get(i)
        if item:getFullType() == "Base.CakeBatter" and madeWithClayBowl(item) then fromClay = true end
    end
    if not fromClay then return end

    local created = data:getAllCreatedItems()
    for i = 0, created:size() - 1 do
        local bowl = created:get(i)
        local container = bowl:getContainer()
        if bowl:getFullType() == "Base.Bowl" and container then
            container:DoRemoveItem(bowl)
            sendRemoveItemFromContainer(container, bowl)
            local clay = container:AddItem("Base.ClayBowl")
            if clay then sendAddItemToContainer(container, clay) end
            return
        end
    end
end

-- SeedPacketCount -------------------------------------------------------------------

local PACKET_SEEDS = {
    ["Base.PumpkinBagSeed"] = "Base.PumpkinSeed",
    ["Base.SunflowerBagSeed"] = "Base.SunflowerSeeds",
}
-- What PutSeedsInPacket takes for these two.
local SEEDS_PER_PACKET = 25
local seedCallSet = {}

ScriptFixes.register("SeedPacketCount",
    function()
        local recipe = ScriptFixes.getRecipe("Base.OpenPacketOfSeeds")
        if recipe and not seedCallSet[recipe] then
            ScriptFixes.setRecipeCall(recipe, "OnCreate", "ZomboidFixesB42.OnCreateSeedPacket")
            seedCallSet[recipe] = true
        end
    end,
    function()
        -- The call cannot be unset; it checks the option itself.
    end)

--- OnCreate of OpenPacketOfSeeds: a pumpkin or sunflower packet gives all 25 seeds.
-- Runs where the craft is performed (the server, or single player).
function ZomboidFixesB42.OnCreateSeedPacket(data, character)
    if not character or not ScriptFixes.isEnabled("SeedPacketCount") then return end
    local consumed = data:getAllConsumedItems()
    for i = 0, consumed:size() - 1 do
        local seedType = PACKET_SEEDS[consumed:get(i):getFullType()]
        if seedType then
            local given = 0
            local created = data:getAllCreatedItems()
            for j = 0, created:size() - 1 do
                if created:get(j):getFullType() == seedType then given = given + 1 end
            end
            for _ = given + 1, SEEDS_PER_PACKET do
                Actions.addOrDropItem(character, instanceItem(seedType))
            end
        end
    end
end

-- ItemWeights -----------------------------------------------------------------------

local PIE_SLICES = { "Base.Pie", "Base.PieApple", "Base.PieBlueberry", "Base.PieKeyLime",
    "Base.PieLemonMeringue", "Base.PiePumpkin" }

local function setWeights(slice, box, carton)
    local params = {
        ["Base.Bullets44Box"] = { Weight = box },
        ["Base.Bullets44Carton"] = { Weight = carton },
    }
    for _, fullType in ipairs(PIE_SLICES) do params[fullType] = { Weight = slice } end
    ScriptFixes.setParams(params)
end

ScriptFixes.register("ItemWeights",
    function() setWeights("0.2", "0.48", "4.8") end,
    function() setWeights("0.5", "1.2", "12.0") end)

-- MinorItemFixes --------------------------------------------------------------------

ScriptFixes.register("MinorItemFixes",
    function()
        ScriptFixes.setParams({
            ["Base.HotDrinkRed"] = { ReplaceOnUse = "Base.Mugl" },
            ["Base.Shirt_Baseball_Rangers"] = { BloodLocation = "Shirt" },
            ["Base.Hat_BaseballCapRed"] = { ChanceToFall = "60" },
            ["Base.Cooler_Seafood"] = { OpenSound = "OpenCooler", CloseSound = "CloseCooler", PutInSound = "StoreItemCooler" },
        })
    end,
    function()
        ScriptFixes.setParams({
            ["Base.HotDrinkRed"] = { ReplaceOnUse = "Base.MugRed" },
            ["Base.Shirt_Baseball_Rangers"] = { BloodLocation = "UpperBody" },
            ["Base.Hat_BaseballCapRed"] = { ChanceToFall = "80" },
            ["Base.Cooler_Seafood"] = { OpenSound = "", CloseSound = "", PutInSound = "" },
        })
    end)

ScriptFixes.onBeforeUse(function(item)
    if item:getFullType() == "Base.HotDrinkRed" and item:getReplaceOnUse() == "Base.MugRed"
            and ScriptFixes.isEnabled("MinorItemFixes") then
        item:setReplaceOnUse("Base.Mugl")
    end
end)
