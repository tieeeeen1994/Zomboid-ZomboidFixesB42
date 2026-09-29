--[[
    Zomboid Fixes B42.20 -- client, watering a plant waters it once

    ISWaterPlantAction (shared/Farming/TimedActions/ISWaterPlantAction.lua) was
    written for single player, where one table runs the whole action: its update
    waters one use at a time as the bar fills (the farming 'water' command, one
    use each) and takes it from the can, counting self.uses down, and complete
    waters whatever is left.

    In multiplayer the action runs twice. The client's copy still waters use by
    use from update and takes the water from its own can (a fluid container's new
    amount reaches the server through SyncItemFieldsPacket, which it trusts). The
    server's copy is built from new's arguments when the action is sent, so its
    self.uses is the full count, and its complete (the only part a server runs)
    waters the plant again with every use and takes the water from the can again.
    So every watering gave the plant twice the water and emptied the can twice as
    fast.

    With the fix on, the server does all of it (server/ZomboidFixesB42_WaterPlant.lua):
    here update only keeps the bar, the facing and the metabolics, and no longer
    sends 'water' or touches the can. The plant and the can change when the
    action ends, and the server's item sync brings the can's new level back.
--]]

if not isClient() then return end

require "Farming/TimedActions/ISWaterPlantAction"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.WaterPlantOnce ~= false
end

local vanillaUpdate = ISWaterPlantAction.update

function ISWaterPlantAction:update()
    if not isEnabled() then
        return vanillaUpdate(self)
    end
    self.item:setJobDelta(self:getJobDelta())
    self.character:faceLocation(self.sq:getX(), self.sq:getY())
    self.character:setMetabolicTarget(Metabolics.LightWork)
end
