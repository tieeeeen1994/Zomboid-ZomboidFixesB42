--[[
    Zomboid Fixes B42.20 -- shared, God Vehicle admin power

    The part both sides need: a snapshot of what wears down on a vehicle and the
    code that puts it back. The server (and single player) holds the real vehicle
    (server/ZomboidFixesB42_AdminGodVehicle.lua); every multiplayer client holds its
    own copy of the vehicles the server names as held
    (client/ZomboidFixesB42_AdminGodVehicle.lua), because some damage is only ever
    made on clients (zombies thumping a car, AttackVehicleState, runs on every client
    that animates the zombie and sends nothing for parts without a window).

    What is held, per part (VehiclePart):
      - condition (getCondition; windows keep their health in it too, VehicleWindow
        getHealth = part condition);
      - the content of a part that holds a liquid or air rather than items
        (isContainer() with no getItemContainer(): the gas tank, tire pressure).
        Trunks, seats and the glove box also report a content amount, but it is the
        weight of the items in them (ItemUser / the container packets set it), so
        those are left alone;
      - the charge of a drainable part item (the battery: DrainableComboItem,
        getCurrentUsesFloat).
    Values only go up: a lower value is put back, a higher one (a repair, a refuel,
    charging from the engine, a pump) becomes the value held from then on. A part
    whose item is taken off or swapped is held afresh from what it has now, so a
    mechanic can still work on the car; a window smashed to 0 (VehicleWindow.damage
    drops its item, VehiclePart.setInventoryItem(null)) gets its own glass back.
--]]

require "ZomboidFixesB42_ServerPowers"

local GodVehicle = {}
ZomboidFixesB42.GodVehicle = GodVehicle

-- Kept by the server per admin (shared/ZomboidFixesB42_ServerPowers.lua); the
-- same capability as vanilla's Mechanics Cheat.
GodVehicle.power = ZomboidFixesB42.ServerPowers.define({
    id = "ZomboidFixesB42_GodVehicle",
    option = "AdminGodVehicle",
    capability = Capability.UseMechanicsCheat,
    side = "right",
    logName = "God Vehicle",
})

-- Smaller drops than these are float noise, not wear.
local CONTENT_EPSILON = 0.0001
local CHARGE_EPSILON = 0.000001

local function holdsFluid(part)
    return part:isContainer() and part:getItemContainer() == nil
end

--- What a part has now.
function GodVehicle.readPart(part)
    local item = part:getInventoryItem()
    local snap = {
        condition = part:getCondition(),
        item = item,
        itemId = item and item:getID() or nil,
    }
    if holdsFluid(part) then
        snap.content = part:getContainerContentAmount()
    end
    if item and instanceof(item, "DrainableComboItem") then
        snap.charge = item:getCurrentUsesFloat()
    end
    return snap
end

--- A snapshot of every part, keyed by part id.
function GodVehicle.readVehicle(vehicle)
    local parts = {}
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        if part then
            parts[part:getId()] = GodVehicle.readPart(part)
        end
    end
    return parts
end

--- Puts back what one part lost since `snap`. `onServer`: the real vehicle, so
-- item changes are allowed and every change is sent to the clients; otherwise a
-- client's own copy, changed locally only. Returns the snapshot to keep and
-- whether anything was put back.
local function holdPart(vehicle, part, snap, onServer)
    local item = part:getInventoryItem()
    local itemId = item and item:getID() or nil

    if snap.item and not item then
        if onServer and part:getWindow() and part:getCondition() <= 0 then
            -- Smashed: VehicleWindow.damage dropped the glass at 0. Put it back.
            part:setInventoryItem(snap.item, part:getMechanicSkillInstaller())
            part:setCondition(snap.condition)
            vehicle:transmitPartItem(part)
            vehicle:transmitPartWindow(part)
            return snap, true
        end
        -- Taken off by a mechanic (or, on a client, not here yet).
        return GodVehicle.readPart(part), false
    end
    if itemId ~= snap.itemId then
        -- Installed or swapped: hold the new item as it is.
        return GodVehicle.readPart(part), false
    end

    local restored = false

    local condition = part:getCondition()
    if condition < snap.condition then
        part:setCondition(snap.condition)
        if onServer then
            -- As vanilla does after damaging a part (AttackVehicleState,
            -- VehicleCommands.setPartCondition): capacity and handling follow it.
            if item then part:doInventoryItemStats(item, part:getMechanicSkillInstaller()) end
            vehicle:transmitPartCondition(part)
            if item then vehicle:transmitPartItem(part) end
            if part:getWindow() then vehicle:transmitPartWindow(part) end
        end
        restored = true
    elseif condition > snap.condition then
        snap.condition = condition
    end

    if snap.content and holdsFluid(part) then
        local content = part:getContainerContentAmount()
        if content < snap.content - CONTENT_EPSILON then
            -- force: tires may be held above their nominal pressure (setTirePressure).
            part:setContainerContentAmount(snap.content, true, true)
            local wheel = part:getWheelIndex()
            local capacity = part:getContainerCapacity()
            if wheel >= 0 and capacity > 0 then
                vehicle:setTireInflation(wheel, snap.content / capacity)
            end
            if onServer then vehicle:transmitPartModData(part) end
            restored = true
        elseif content > snap.content then
            snap.content = content
        end
    end

    if snap.charge and item then
        local charge = item:getCurrentUsesFloat()
        if charge < snap.charge - CHARGE_EPSILON then
            item:setUsedDelta(snap.charge)
            if onServer then vehicle:transmitPartUsedDelta(part) end
            restored = true
        elseif charge > snap.charge then
            snap.charge = charge
        end
    end

    return snap, restored
end

--- Puts back everything the vehicle lost since `parts` (from readVehicle), which is
-- updated in place. Returns true if anything was put back.
function GodVehicle.holdVehicle(vehicle, parts, onServer)
    local restoredAny = false
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        if part then
            local id = part:getId()
            local snap = parts[id]
            if not snap then
                parts[id] = GodVehicle.readPart(part)
            else
                local kept, restored = holdPart(vehicle, part, snap, onServer)
                parts[id] = kept
                if restored then restoredAny = true end
            end
        end
    end
    if restoredAny then
        vehicle:updatePartStats()
    end
    return restoredAny
end
