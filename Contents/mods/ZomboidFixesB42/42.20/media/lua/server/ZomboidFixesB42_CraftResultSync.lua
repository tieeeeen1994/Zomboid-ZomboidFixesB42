--[[
    Zomboid Fixes B42.20 -- server, crafted items show their real values in multiplayer

    ISHandcraftAction:performRecipe (shared/Entity/TimedActions, 42.21; on the
    server in multiplayer) adds each crafted item with Actions.addOrDropItem, which
    sends it to the owner there and then, and only afterwards runs the recipe's
    OnCreate and writes the "made from" record into the item's modData:

        Actions.addOrDropItem(self.character, item)
        ...
        self.logic:getRecipeData():luaCallOnCreate(self.character)

    Whatever OnCreate changes on the server's copy never reaches the owner. The plain
    case is fish fillets: RecipeCodeOnCreate.cutFish (Java) gives each fillet half the
    fish's calories, hunger, nutrients and weight, but the owner's copies keep the
    FishFillet script's 205 kcal whatever the fish was, until the fillet is dropped
    and comes back from the floor (forum 100231). The same goes for every OnCreate
    that adjusts its outputs (food values, conditions, names, modData), and for the
    modData record.

    So after performRecipe each crafted item that ended up in a player's inventory is
    sent again with sendReplaceItemInContainer (the whole item, same ID; the client
    swaps its copy for it). At most 20 per craft, so a large batch cannot flood the
    connection. Items addOrDropItem had to drop on the floor are left as they are.
--]]

if isClient() then return end

require "Entity/TimedActions/ISHandcraftAction"

local MAX_PER_CRAFT = 20

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.CraftResultSync == true
end

local vanillaPerformRecipe = ISHandcraftAction.performRecipe

function ISHandcraftAction:performRecipe(...)
    local result = vanillaPerformRecipe(self, ...)
    if not isServer() or not isEnabled() or not self.logic then return result end

    -- The list vanilla handed to addOrDropItem a moment ago.
    local created = ArrayList.new()
    self.logic:getCreatedOutputItems(created)

    local sent = 0
    for i = 0, created:size() - 1 do
        if sent >= MAX_PER_CRAFT then break end
        local item = created:get(i)
        local container = item and item:getContainer()
        if container and container:getCharacter() then
            sendReplaceItemInContainer(container, item, item)
            sent = sent + 1
        end
    end
    return result
end
