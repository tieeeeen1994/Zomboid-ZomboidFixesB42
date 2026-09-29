--[[
    Zomboid Fixes B42.20 -- shared, item and recipe script fixes (the machinery)

    Vanilla ships a number of plain data mistakes in its item, recipe and repair
    scripts. The ZomboidFixesB42_ItemFixes*.lua files correct them, one sandbox
    option each; this file holds what they share: turning each fix on and off
    with its option, and the helpers that edit the loaded scripts in place. Both
    sides run it, since the client and the server each use their own copy of the
    scripts (the client to show and test a craft, the server to perform it).

    When the edits are made (Java, 42.21) ---------------------------------------

    IsoWorld.init loads the sandbox options (SandboxOptions.load, a client already
    has the server's), fires OnInitGlobalModData, then runs WorldDictionary.init and
    ScriptManager.PostWorldDictionaryInit, and only then fires OnLoadMapZones (on a
    client, a server and in single player alike). PostWorldDictionaryInit is where
    every craftRecipe resolves its inputs and output mappers, so recipe edits have
    to come after it: an output mapper entry added before it would be resolved a
    second time. Everything here therefore starts from OnLoadMapZones. There is no
    event for the sandbox options changing mid-game, so the options are checked
    again every ten game minutes and a fix switched off is undone.

    ScriptManager.Reset + Load runs when a game is left (IngameState.exit) and when
    Lua is reset, so every game starts from fresh vanilla scripts. Lua itself is not
    always reloaded with them, so each fix's "applied" flag is cleared at
    OnLoadMapZones before anything is applied.

    Item properties: Item.DoParam(param, value) is the script parser's own setter.
    Most properties are replaced (Weight, ReplaceOnUse, ClothingItemExtra,
    BloodLocation, MountOn, sounds...); an empty value clears a string property.
    Item instances copy many of them when they are created (weight, nutrition,
    clothing stats, container sounds, a weapon part's MountOn, a food's
    ReplaceOnUse), and those copies are not saved (except food nutrition and a
    custom weight), so items already loaded keep the old value until they are next
    loaded, and new items get the new one. Some are read from the script every time
    (ClothingItemExtra, SpawnWith, BloodLocation's covered parts, weapon sounds).

    Tags: DoParam("Tags") only adds, and the tag is resolved in several caches that
    are built before Lua can touch them:
      * ItemTags.tagItemMap, built when the scripts load (not exposed to Lua), read
        only by InputScript.OnPostWorldDictionaryInit;
      * every craftRecipe input written tags[...] copies the tag's items into its
        itemScriptCache (InputScript.getPossibleInputItems() returns that list, and
        CraftRecipeManager matches items with input.containsItem = that list);
      * ScriptManager.tagToItemMap, filled lazily by getItemsTag;
      * Item.usedInRecipes, the recipe names the item appears in.
    ScriptFixes.addTag / removeTag update the item's own set and every one of those
    Lua can reach. The per-item amount of an input (`25:Base.X`) is looked up in a
    private list of names, so an item added this way counts with the input's
    default amount; the fixes only use inputs of amount 1.

    Output mappers: OutputMapper.getOutputItem walks its entries in order and takes
    the first whose pattern items all match the most recent item put in one of the
    mapper's registered inputs (the ones written mappers[...]). An entry holds
    resolved script items, so a new one is built in a throwaway OutputMapper
    (addOutputEntree + OnPostWorldDictionaryInit, which only resolves when no recipe
    name is given) and the resolved entry object is moved into the recipe's list.
    registerInputScript is public, so another input can be made to count in a
    mapper's patterns.

    Recipe Lua calls: CraftRecipe.Load(name, body) run again on a loaded recipe adds
    to it (keys are set, blocks are appended); a body holding only
    `OnCreate = Some.function` sets that call. CraftRecipeData looks the function
    up by name every time a craft finishes, so it may be set at any time.

    Repairs: FixingManager.getFixes(item) matches Fixing.getRequiredItem() (a
    mutable list of full types) against the item's full type; Fixing.getFixers() is
    a mutable list. A Fixer is built by loading a throwaway Fixing.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local ScriptFixes = {}
ZomboidFixesB42.ScriptFixes = ScriptFixes

local fixes = {}
local beforeUse = {}

local function log(text)
    print("[ZomboidFixesB42] script fixes: " .. text)
end
ScriptFixes.log = log

--- True when the ZomboidFixesB42 sandbox option `option` is ticked.
function ScriptFixes.isEnabled(option)
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars[option] == true
end

--- Registers a fix: `apply` runs when its option is on (at world load or when the
-- option is ticked mid-game), `revert` when a fix already applied is switched off.
function ScriptFixes.register(option, apply, revert)
    fixes[#fixes + 1] = { option = option, apply = apply, revert = revert, applied = false }
end

--- Registers `fn(item)`, called just before a food item is eaten, emptied or used in
-- an evolved recipe, where its per-instance ReplaceOnUse decides what it leaves.
function ScriptFixes.onBeforeUse(fn)
    beforeUse[#beforeUse + 1] = fn
end

function ScriptFixes.beforeUse(item)
    if not item then return end
    for i = 1, #beforeUse do
        beforeUse[i](item)
    end
end

-- Items -----------------------------------------------------------------------

function ScriptFixes.getItem(fullType)
    local item = ScriptManager.instance:getItem(fullType)
    if not item then log("item not found: " .. fullType) end
    return item
end

--- Sets script properties: { ["Base.X"] = { Param = "value", ... }, ... }.
function ScriptFixes.setParams(params)
    for fullType, values in pairs(params) do
        local item = ScriptFixes.getItem(fullType)
        if item then
            for param, value in pairs(values) do
                item:DoParam(param, value)
            end
        end
    end
end

-- Tags ------------------------------------------------------------------------

local addedTags = {}

local function getTag(name)
    return ItemTag.get(ResourceLocation.of(name))
end

local function eachTagInput(tag, fn)
    local recipes = ScriptManager.instance:getAllCraftRecipes()
    for i = 0, recipes:size() - 1 do
        local recipe = recipes:get(i)
        local inputs = recipe:getInputs()
        for j = 0, inputs:size() - 1 do
            local input = inputs:get(j)
            if input:getItemTags():contains(tag) then
                fn(recipe, input)
            end
        end
    end
end

--- Gives an item a tag, including in the recipe inputs that accept that tag.
function ScriptFixes.addTag(fullType, tagName)
    local item, tag = ScriptFixes.getItem(fullType), getTag(tagName)
    if not item or not tag then return end
    local tags = item:getTags()
    if tags:contains(tag) then return end
    tags:add(tag)
    addedTags[fullType .. "|" .. tagName] = true

    local byTag = ScriptManager.instance:getItemsTag(tag)
    if not byTag:contains(item) then byTag:add(item) end

    local used = item:getUsedInRecipes()
    eachTagInput(tag, function(recipe, input)
        local list = input:getPossibleInputItems()
        if not list:contains(item) then list:add(item) end
        if not used:contains(recipe:getName()) then used:add(recipe:getName()) end
    end)
end

--- Takes back a tag given by addTag (never one vanilla gave).
function ScriptFixes.removeTag(fullType, tagName)
    if not addedTags[fullType .. "|" .. tagName] then return end
    addedTags[fullType .. "|" .. tagName] = nil
    local item, tag = ScriptFixes.getItem(fullType), getTag(tagName)
    if not item or not tag then return end
    item:getTags():remove(tag)
    ScriptManager.instance:getItemsTag(tag):remove(item)

    local used = item:getUsedInRecipes()
    eachTagInput(tag, function(recipe, input)
        input:getPossibleInputItems():remove(item)
        used:remove(recipe:getName())
    end)
end

-- Recipes ---------------------------------------------------------------------

function ScriptFixes.getRecipe(name)
    local recipe = ScriptManager.instance:getCraftRecipe(name)
    if not recipe then log("recipe not found: " .. name) end
    return recipe
end

--- A resolved output mapper entry: `result` when every item of `pattern` matches.
-- Returns nil when one of the items does not exist.
function ScriptFixes.newMapperEntry(result, pattern)
    local list = ArrayList.new()
    for _, fullType in ipairs(pattern) do
        if not ScriptFixes.getItem(fullType) then return nil end
        list:add(fullType)
    end
    if not ScriptFixes.getItem(result) then return nil end
    local mapper = OutputMapper.new("ZomboidFixesB42")
    mapper:addOutputEntree(result, list)
    mapper:OnPostWorldDictionaryInit()
    return mapper:getEntrees():get(0)
end

--- Sets one of a recipe's Lua calls (OnCreate, OnTest...) to a global function name.
function ScriptFixes.setRecipeCall(recipe, key, functionName)
    local name = recipe:getName()
    recipe:Load(name, "craftRecipe " .. name .. " { " .. key .. " = " .. functionName .. ", }")
end

-- Repairs ---------------------------------------------------------------------

--- The repair recipe named `name` ("Fix DoubleBarrelShotgun").
function ScriptFixes.getFixing(name)
    local fixing = ScriptManager.instance:getFixing("Base." .. name)
    if not fixing then log("repair recipe not found: " .. name) end
    return fixing
end

--- A Fixer from a script line such as "Base.X; Aiming=2".
function ScriptFixes.newFixer(line)
    local fixing = Fixing.new()
    fixing:Load("ZomboidFixesB42", "fixing ZomboidFixesB42 { Fixer = " .. line .. ", }")
    return fixing:getFixers():get(0)
end

-- Switching fixes on and off ------------------------------------------------------

local function run(fix, enabled)
    local fn = enabled and fix.apply or fix.revert
    local ok, err = pcall(fn)
    if not ok then log(fix.option .. " failed: " .. tostring(err)) end
    -- Marked either way: a fix that errors is not retried every ten minutes.
    fix.applied = enabled
end

local function update()
    for i = 1, #fixes do
        local fix = fixes[i]
        local enabled = ScriptFixes.isEnabled(fix.option)
        if enabled ~= fix.applied then run(fix, enabled) end
    end
end

local function onWorldLoad()
    -- The scripts are fresh vanilla ones at every world load.
    for i = 1, #fixes do fixes[i].applied = false end
    update()
end

Events.OnLoadMapZones.Add(onWorldLoad)
Events.EveryTenMinutes.Add(update)

-- Hooks where a food item's ReplaceOnUse is used ------------------------------------
-- Each runs where the action completes: the server in multiplayer, the game in
-- single player.

require "TimedActions/ISEatFoodAction"
require "TimedActions/ISDumpContentsAction"
require "TimedActions/ISAddItemInRecipe"

local originalEatComplete = ISEatFoodAction.complete
function ISEatFoodAction:complete()
    ScriptFixes.beforeUse(self.item)
    return originalEatComplete(self)
end

-- Eating cut short (serverStop) goes through eat().
local originalEat = ISEatFoodAction.eat
function ISEatFoodAction:eat(food, percentage)
    ScriptFixes.beforeUse(self.item)
    return originalEat(self, food, percentage)
end

local originalDumpComplete = ISDumpContentsAction.complete
function ISDumpContentsAction:complete()
    ScriptFixes.beforeUse(self.item)
    return originalDumpComplete(self)
end

local originalAddInRecipeComplete = ISAddItemInRecipe.complete
function ISAddItemInRecipe:complete()
    ScriptFixes.beforeUse(self.usedItem)
    return originalAddInRecipeComplete(self)
end
