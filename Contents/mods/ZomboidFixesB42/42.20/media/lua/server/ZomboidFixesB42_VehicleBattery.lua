--[[
    Zomboid Fixes B42.20 -- server, vehicle battery drain

    Everything that runs a car battery down goes through VehicleUtils.chargeBattery
    (server/Vehicles/Vehicles.lua ~1306 in 42.21): headlights, the radio, the
    lightbar and the siren while the engine is off, and the heater while it runs.
    The clamp in it adds the change twice:

        charge = math.max(charge + delta, 0.0)
        charge = math.min(charge + delta, 1.0)

    so every drain is twice what its caller asked for. Charging from a running
    engine does not come through here (Vehicles.Update.Battery adds its own 0.001 a
    minute with a single clamp), so only the drains are doubled.

    Clamping once is not quite enough on its own. A battery's charge is stored as
    a whole number of uses (DrainableComboItem.setCurrentUsesFloat rounds
    newUses / useDelta, and car batteries have UseDelta 0.00001), and part updates
    come about once a game minute (VehicleParts.updatePart only calls the Lua once
    a whole minute has passed). One headlight asks for 0.000025 a minute, which is
    2.5 uses: rounded, that is 2 or 3 depending on float error and how far past the
    minute the update landed. Vanilla's doubled 5 uses happened to be whole. So the
    part of each change the rounding drops is carried to the battery's next change,
    and over time the drain is exactly what the callers ask for.

    Part updates only run where the vehicle is simulated (VehicleParts.update does
    nothing on a client), so this is only needed on the server and in single
    player. The charge reaches clients as vanilla sends it.
--]]

if isClient() then return end

require "Vehicles/Vehicles"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.VehicleBatteryDrain ~= false
end

-- Battery item ID -> the fraction of a use the last change rounded away. Never
-- more than half a use per battery, so a battery that was swapped out or
-- destroyed leaves nothing worth cleaning up.
local carry = {}

local vanillaChargeBattery = VehicleUtils.chargeBattery

function VehicleUtils.chargeBattery(vehicle, delta)
    if not isEnabled() then
        return vanillaChargeBattery(vehicle, delta)
    end

    local battery = vehicle:getBattery()
    if not battery then return end
    local item = battery:getInventoryItem()
    if not item then return end

    local id = item:getID()
    local chargeOld = item:getCurrentUsesFloat()
    local target = chargeOld + delta + (carry[id] or 0)

    if target <= 0.0 or target >= 1.0 then
        -- Empty or full: nothing to carry past the end.
        carry[id] = nil
        target = math.max(math.min(target, 1.0), 0.0)
        if target ~= chargeOld then
            item:setUsedDelta(target)
        end
    else
        item:setUsedDelta(target)
        carry[id] = target - item:getCurrentUsesFloat()
    end

    local charge = item:getCurrentUsesFloat()
    if charge ~= chargeOld and VehicleUtils.compareFloats(chargeOld, charge, 2) then
        vehicle:transmitPartUsedDelta(battery)
    end
end
