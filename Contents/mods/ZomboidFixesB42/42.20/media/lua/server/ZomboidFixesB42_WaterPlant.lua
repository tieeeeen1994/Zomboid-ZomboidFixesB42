--[[
    Zomboid Fixes B42.20 -- server, watering a plant waters it once

    In multiplayer both copies of ISWaterPlantAction watered the plant and used
    the can: the client's update use by use, then the server's complete with the
    full count (see client/ZomboidFixesB42_WaterPlant.lua). The client no longer
    does, so the server's copy is the only one:

      * complete (vanilla's, which waters self.uses and takes one use from the
        can for each while the plant is below 100) first cuts self.uses down to
        the water the can really holds now. The client counted it when the menu
        was opened, and a second watering queued with the same can, or a drink in
        between, left the server's can with less than that.
      * serverStop (the player cancelled, walked off or disconnected) waters the
        uses the bar had passed, like vanilla's update did before the cancel:
        use n is poured once the bar reaches n / uses. Java calls it only for a
        cancelled action (ActionManager.remove), never after complete.

    The client's 'water' command handler (farmingCommands.lua) is left as it is:
    nothing of vanilla sends it any more while this is on.

    Single player keeps vanilla's action as it is: update and complete run on
    the same table there, and complete only waters what update had not.
--]]

if isClient() then return end

require "Farming/TimedActions/ISWaterPlantAction"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.WaterPlantOnce ~= false
end

-- ISFarmingMenu.getWaterUsesInteger, which is client-only (client/Farming/ISUI).
local function waterUsesIn(item)
    if not item then return 0 end
    if item:hasComponent(ComponentType.FluidContainer) then
        local fluidContainer = item:getFluidContainer()
        local fluid = fluidContainer and fluidContainer:getPrimaryFluid()
        if not fluid then return 0 end
        local fluidType = fluid:getFluidTypeString()
        if fluidType == "Water" or fluidType == "TaintedWater" then
            local millilitres = fluidContainer:getAmount() * 1000
            return math.floor(millilitres / ZomboidGlobals.farmingFluidContainerMillilitresPerUse)
        end
    end
    if item:IsDrainable() and item:isWaterSource() then
        return item:getCurrentUses()
    end
    return 0
end

-- The uses the server can pour now, at most `uses`: none when the plant is gone
-- (vanilla's complete would error on it and have the action rejected).
local function usesAvailable(action, uses)
    if not SFarmingSystem.instance:getLuaObjectOnSquare(action.sq) then return 0 end
    return math.max(math.min(uses, waterUsesIn(action.item)), 0)
end

local vanillaComplete = ISWaterPlantAction.complete
local vanillaServerStop = ISWaterPlantAction.serverStop

function ISWaterPlantAction:complete()
    if isServer() and isEnabled() then
        self.uses = usesAvailable(self, self.uses or 0)
    end
    return vanillaComplete(self)
end

function ISWaterPlantAction:serverStop()
    if isEnabled() and self.netAction and (self.uses or 0) > 0 then
        local progress = math.max(math.min(self.netAction:getProgress(), 1), 0)
        local poured = math.floor(progress * self.uses + 0.0001)
        self.uses = usesAvailable(self, poured)
        if self.uses > 0 then
            vanillaComplete(self)
        end
    end
    if vanillaServerStop then
        return vanillaServerStop(self)
    end
end
