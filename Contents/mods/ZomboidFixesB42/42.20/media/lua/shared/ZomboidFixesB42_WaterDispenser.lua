--[[
    Zomboid Fixes B42.20 -- shared, water dispenser bottle duplication

    Taking the bottle off an office water dispenser, or putting one on, is
    ISAddTakeDispenserBottle (shared/TimedActions/ISAddTakeDispenserBottle.lua,
    42.21). complete() swaps the dispenser object for the other kind
    (WaterDispenser has a FluidContainer, WaterDispenserNoBottle has none) and
    hands over the bottle with its water. Nothing checks that the swap still makes
    sense:

      * isValid (~6) is `hasComponent(ComponentType.FluidContainer) ~= bottle`,
        with `bottle` an undefined global: a boolean is never nil, so it is always
        true. A second "Take bottle" queued before the first ends (two right-clicks
        are enough, single player too) still holds the old dispenser object, which
        is off the square by then but still has its full FluidContainer: it adds
        another full bottle and places a second empty dispenser on the square.
        Putting two bottles on stacks two full dispensers the same way.
      * isValid only runs on the client; the server's complete() checks nothing,
        so two players taking the same bottle at once duplicate it too.
      * The bottle to put on is picked from every bottle in the inventory
        (ContextMenuCode.lua ~22, getAllTypeRecurse), but complete() removes it
        with self.character:getInventory():Remove, and ItemContainer.Remove only
        looks at that one container: a bottle in a bag fills the dispenser and
        stays in the bag, water and all.

    So isValid (client and single player) and complete (server and single player)
    check that the dispenser is still on its square, has a bottle when taking one
    and none when putting one on, and that the bottle is still somewhere in the
    inventory. complete() returning false makes the server reject the action
    (ActionManager), so nothing changes and the client's action ends. The bottle put
    on is removed from the container it is really in.
--]]

require "TimedActions/ISAddTakeDispenserBottle"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.WaterDispenserCheck == true
end

--- True while the action still matches the dispenser and the inventory.
local function stillValid(action)
    local dispenser = action.waterdispenser
    if not dispenser or dispenser:getObjectIndex() == -1 then return false end
    local hasBottle = dispenser:hasComponent(ComponentType.FluidContainer)
    if action.bottle then
        return not hasBottle and action.character:getInventory():containsRecursive(action.bottle)
    end
    return hasBottle
end

local vanillaIsValid = ISAddTakeDispenserBottle.isValid

function ISAddTakeDispenserBottle:isValid()
    if not isEnabled() then
        return vanillaIsValid(self)
    end
    return stillValid(self)
end

-- Sprites of the dispenser with a bottle, by facing (vanilla complete()).
local SPRITE_WITH_BOTTLE = {
    N = "location_business_office_generic_01_57",
    S = "location_business_office_generic_01_49",
    W = "location_business_office_generic_01_56",
}

local vanillaComplete = ISAddTakeDispenserBottle.complete

function ISAddTakeDispenserBottle:complete()
    if not isEnabled() then
        return vanillaComplete(self)
    end
    if not stillValid(self) then
        return false
    end
    if not self.bottle then
        -- Taking the bottle: vanilla is right once the dispenser is checked.
        return vanillaComplete(self)
    end

    -- Putting a bottle on: vanilla's code, removing the bottle from its own
    -- container instead of only the main inventory.
    self.square:transmitRemoveItemFromSquare(self.waterdispenser)
    self.square:RemoveTileObject(self.waterdispenser)
    local facing = self.waterdispenser:getFacing()
    local sprite = (facing and SPRITE_WITH_BOTTLE[tostring(facing)]) or "location_business_office_generic_01_48"
    local newdispenser = self.square:addWorkstationEntity("WaterDispenser", sprite)
    if newdispenser and newdispenser:hasComponent(ComponentType.FluidContainer) then
        newdispenser:getFluidContainer():setInputLocked(false)
        newdispenser:getFluidContainer():copyFluidsFrom(self.bottle:getFluidContainer())
        newdispenser:getFluidContainer():setInputLocked(true)
    end
    -- addWorkstationEntity has already sent the object to clients.
    if newdispenser then
        newdispenser:sync()
    end
    local container = self.bottle:getContainer() or self.character:getInventory()
    sendRemoveItemFromContainer(container, self.bottle)
    container:Remove(self.bottle)
    return true
end
