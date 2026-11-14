--[[
    Zomboid Fixes B42.20 -- server / single player, a craft is not lost by walking away
    from containers it does not use

    A handcraft keeps the list of containers that was nearby when it was queued
    (ISInventoryPaneContextMenu.OnNewCraft and the crafting window pass
    getContainers(player): the main inventory, worn bags, the loot window's floor,
    every crate, shelf, fridge, corpse and vehicle part in reach). In multiplayer
    that list travels with the action and the server rebuilds the craft from it
    (ISHandcraftAction:serverStart); single player keeps the client's.

    When the craft finishes, ISHandcraftAction:performRecipe calls
    HandcraftLogic.performCurrentRecipe (42.22 ~139), which first runs
    BaseCraftingLogic.isContainersAccessible (~769) over that whole list and gives up
    when ANY container in it is a vehicle part the player can no longer reach, a
    padlocked crate, or more than 2.5 tiles from the player:

        if (!this.isContainersAccessible(this.containers)) return false;

    Nothing is consumed or made, and nothing says so: ISHandcraftAction:complete
    still returns true, so the action ends normally. The floor counts too: the
    client's loot window floor goes to the server addressed by the square it was
    built on (ContainerID.setFloor).

    Every recipe tagged CanBeDoneWhileWalking can run while the player walks, and
    42.22 gave the tag to vanilla's ammo box openings (Guns of Tien adds it to
    Guns of Marz's). So walking more than a couple of tiles from a crate, a shelf,
    a car or anything lying on the floor while opening ammo boxes made the opening
    "complete" with the box still unopened, and any mod queueing them (Tien's
    Ammo Bags' Reload / Fetch (Open Boxes)) saw a box that refused to open.

    So just before performRecipe, if the list as a whole fails that check, every
    container that fails it on its own and holds none of the craft's input items
    is taken out of the list, and vanilla runs on the rest. A container that holds
    an input stays, so walking away from a crate whose items the craft uses still
    refuses the craft, as vanilla means it to. A dropped floor container is rebuilt
    by vanilla's updateFloorContainer around where the player stands now.
    getContainers() is the logic's live list; with manual inputs (a craft from an
    item's right-click menu) the list is edited in place, otherwise setContainers
    is called with the kept containers so the items it picks from are recounted.
--]]

if isClient() then return end

require "Entity/TimedActions/ISHandcraftAction"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.CraftOutOfReach == true
end

local function outermost(container)
    if not container then return nil end
    return container:getOutermostContainer() or container
end

-- Every item the craft will use, as outermost containers (and whether any lies on
-- the floor, where an item has no container of its own).
local function inputPlaces(action)
    local places, onFloor = {}, false

    local function addItem(item)
        if not item or not instanceof(item, "InventoryItem") then return end
        if item:getWorldItem() then onFloor = true end
        local outer = outermost(item:getContainer())
        if outer then places[outer] = true end
    end
    local function addList(list)
        if not list then return end
        for i = 0, list:size() - 1 do addItem(list:get(i)) end
    end

    local data = action.logic:getRecipeData()
    if data then addList(data:getAllInputItems()) end
    if action.items and instanceof(action.items, "ArrayList") then addList(action.items) end
    if type(action.manualInputs) == "table" then
        for _, items in pairs(action.manualInputs) do
            if instanceof(items, "ArrayList") then addList(items) end
        end
    end
    addItem(action.recipeItem)
    return places, onFloor
end

local function dropUnreachable(action)
    local logic = action.logic
    local containers = logic:getContainers()
    if not containers or containers:isEmpty() or logic:isContainersAccessible(containers) then return end

    local places, onFloor = inputPlaces(action)
    local kept, one, dropped = ArrayList.new(), ArrayList.new(), 0
    for i = 0, containers:size() - 1 do
        local container = containers:get(i)
        one:clear()
        one:add(container)
        local holdsInput = places[outermost(container)]
            or (onFloor and container:getType() == "floor")
        if holdsInput or logic:isContainersAccessible(one) then
            kept:add(container)
        else
            dropped = dropped + 1
        end
    end
    if dropped == 0 then return end

    if logic:isManualSelectInputs() then
        containers:clear()
        for i = 0, kept:size() - 1 do containers:add(kept:get(i)) end
    else
        logic:setContainers(kept)
    end
end

local vanillaPerformRecipe = ISHandcraftAction.performRecipe

function ISHandcraftAction:performRecipe(...)
    if self.logic and isEnabled() then
        local ok, err = pcall(dropUnreachable, self)
        if not ok then print("[ZomboidFixesB42] CraftOutOfReach: " .. tostring(err)) end
    end
    return vanillaPerformRecipe(self, ...)
end
