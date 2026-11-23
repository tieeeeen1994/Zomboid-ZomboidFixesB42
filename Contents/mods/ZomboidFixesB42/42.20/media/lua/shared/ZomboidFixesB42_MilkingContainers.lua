--[[
    Zomboid Fixes B42.20 -- shared, milking moves on to the next container that has room

    Every way to start milking (the animal's Milk submenu and its "All" entry, the radial
    menu, the animal window's Milk button, the contextual action key) picks its first
    container with ItemContainer.getAvailableFluidContainer / getFirstAvailableFluidContainer
    (42.22.2, Java ~2811). Both test InventoryItem.isAvailableFluidContainer (~5447):
    a fluid container that is empty, or whose primary fluid is this milk. A container
    already **full** of that milk passes, and so does one whose whitelist refuses milk.

    ISMilkAnimal:milk (shared/TimedActions/Animals, ~59) runs once per 0.1 L step (single
    player from `update`, a server from the emulated "update" anim event; the client's
    update skips it). When its container is full it looks for another only:
      - with "All": getFirstAvailableFluidContainer again, i.e. the first container of
        the inventory that holds this milk or nothing, full ones included, so a full
        bottle earlier in the inventory is taken again and again;
      - then, either way, another container of the **same full type** that is not full.
    Anything else stops the action. So milking ends as soon as the chosen kind of
    container is full (empty bottles and buckets of another kind are ignored), "All"
    stops at once whenever a full container comes first, and starting on a full
    container (the menu lists them, the radial and the window can pick one) does nothing.
    A container that refuses milk but is not full is worse: FluidContainer.addFluid adds
    nothing (canAddFluid, ~903), the animal's milk never drops, and the action loops.

    This wraps milk(): before vanilla's step, if the current container is missing, full or
    refuses this milk, it switches to the next usable one in the main inventory (vanilla
    only looks there too): the same kind first, then any container that is empty or holds
    this milk, has room, and accepts it. With none it stops as vanilla does, without
    vanilla's stress roll first (which could spill the container that just filled) and
    without looping on a refusing container. Runs where milk() runs: on the
    server in multiplayer, locally in single player. The client half
    (client/ZomboidFixesB42_MilkingContainers.lua) drops full and refusing containers from
    the Milk submenu and rounds the litres it shows (it printed a float's double value,
    "0.2/0.20000000298023224L"). Option MilkingContainers.
--]]

require "TimedActions/Animals/ISMilkAnimal"

ZomboidFixesB42 = ZomboidFixesB42 or {}
local MilkingContainers = {}
ZomboidFixesB42.MilkingContainers = MilkingContainers

function MilkingContainers.isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MilkingContainers == true
end

--- True when the item can take more of this milk right now.
function MilkingContainers.usable(item, milkType)
    if not item or not milkType then return false end
    local fc = item:getFluidContainer()
    if not fc or fc:isFull() then return false end
    if not item:isAvailableFluidContainer(milkType) then return false end
    local fluid = Fluid.Get(milkType)
    if fluid and not fc:canAddFluid(fluid) then return false end
    return true
end

--- The next container for this milk in the character's main inventory: the same kind
--- as `current` first, then any. nil when none has room.
function MilkingContainers.nextContainer(character, current, milkType)
    local list = character:getInventory():getAvailableFluidContainer(milkType)
    if not list then return nil end
    local fullType = current and current:getFullType()
    if fullType then
        for i = 0, list:size() - 1 do
            local item = list:get(i)
            if item ~= current and item:getFullType() == fullType and MilkingContainers.usable(item, milkType) then
                return item
            end
        end
    end
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if item ~= current and MilkingContainers.usable(item, milkType) then
            return item
        end
    end
    return nil
end

local vanillaMilk = ISMilkAnimal.milk

function ISMilkAnimal:milk()
    if not MilkingContainers.isEnabled() or not self.animal or not self.character
        or self.character:hasFullInventory() then
        return vanillaMilk(self)
    end
    local data = self.animal:getData()
    local breed = data and data:getBreed()
    local milkType = breed and breed:getMilkType()
    if not milkType or MilkingContainers.usable(self.bucket, milkType) then
        return vanillaMilk(self)
    end

    local nextBucket = MilkingContainers.nextContainer(self.character, self.bucket, milkType)
    if nextBucket then
        if self.bucket then
            self.bucket:setJobDelta(0.0)
        end
        self.bucket = nextBucket
        if not isServer() then
            nextBucket:setJobType(getText("ContextMenu_Milk"))
            nextBucket:setJobDelta(0.0)
        end
        return vanillaMilk(self)
    end

    -- Nothing with room: stop the way vanilla does. Not through vanillaMilk, whose stress
    -- roll comes before its container check and could spill a full container (or index a
    -- nil one), and which would loop forever on a container that refuses milk.
    if self.bucket then
        self.bucket:setJobDelta(0.0)
    end
    if isServer() then
        self.netAction:forceComplete()
    else
        self:forceStop()
    end
end
