--[[
    Zomboid Fixes B42.20 -- server, God Vehicle admin power

    While an admin with God Vehicle on sits in a vehicle (any seat), that vehicle,
    and a trailer it tows, does not wear down: part conditions, windows, fuel, tire
    pressure and the battery charge never drop. Anything that raises them still
    works (repairs, refuelling, charging, a pump); see
    shared/ZomboidFixesB42_AdminGodVehicle.lua for exactly what is held.

    Where a vehicle loses those in 42.21 (all on the server or in single player
    unless said otherwise):
      - Part updates (VehicleParts.updatePart, once a game minute, by function name
        through LuaManager.getFunctionObject, which caches the function it finds the
        first time): Vehicles.Update.GasTank burns fuel and leaks from a tank under
        70 condition; Vehicles.Update.Brakes wears the brakes; Vehicles.LowerCondition
        (suspension, muffler, tires) wears them while driving; Vehicles.Update.Tire
        also lets air out and blows a tire (VehicleUtils.RemoveTire) at no air or
        under 15 condition; VehicleUtils.chargeBattery is every battery drain
        (lights, radio, lightbar, siren, heater). Wrapped here at load, before the
        first part update caches them, to do nothing for a held vehicle (the battery
        only for drains: charging comes through it too).
      - Crashes: a client's BaseVehicle.crash only sends vehicle.crash; the server's
        VehicleCommands calls vehicle:crash(amount, front), which damages the front
        or rear parts (addDamageFront / addDamageRear, skipped by vanilla only when
        the driver is in god mode) and the occupants (damagePlayers), and passes the
        crash on to a towed trailer. Running down zombies: the driver's client sends
        vehicle.damageFromHitChr, the server calls vehicle:damageFromHitChr. Both
        Lua calls are wrapped through BaseVehicle's class metatable, so a held
        vehicle takes no crash at all: its occupants are not hurt by crashes
        either. In single player Java calls crash directly; there only the hold
        below applies and occupants are hurt as usual.
      - Windows: VehicleCommands.damageWindow (sent by every client whose zombie
        thumps a window, VehicleWindow.damage on a client) and ISSmashVehicleWindow
        (VehicleWindow.hit) call into VehicleWindow from Lua; wrapped the same way.
        At 0 VehicleWindow.damage drops the glass item.
      - Java only, not reachable from Lua: BaseVehicle.applyDamageToPart (weapons
        and bullets on the car, server), BaseVehicle.Thump (lightbar and the part a
        thumper uses), tryStartEngine (-0.025 battery per start). These are put back
        by the hold every tick, and sent to the clients (transmitPart*: the server
        only flags the part; the vehicle update packet carries it).
      - Client only: AttackVehicleState's ThumpFrame lowers a door or body part's
        condition on every client animating the zombie and sends nothing, so the
        server never sees it. Every client holds its own copy of each held vehicle
        for that (the list of held vehicle IDs is broadcast whenever it changes).

    The power is kept by the server per admin, saved with the world
    (shared/ZomboidFixesB42_ServerPowers.lua: gate, protocol, admin log), and
    checked every tick. Option AdminGodVehicle.
--]]

if isClient() then return end

require "Vehicles/Vehicles"
-- That file replaces VehicleUtils.chargeBattery outright; wrap its version.
require "ZomboidFixesB42_VehicleBattery"

local ServerPowers = ZomboidFixesB42.ServerPowers
local GodVehicle = ZomboidFixesB42.GodVehicle
local power = GodVehicle.power

-- How many trailers deep a held vehicle's tow chain is followed.
local MAX_TOW_CHAIN = 4

-- [vehicle id] = { vehicle = BaseVehicle, parts = snapshot }
local held = {}

local function isHeld(vehicle)
    return vehicle ~= nil and held[vehicle:getId()] ~= nil and ServerPowers.isEnabled(power)
end

--- The vehicles to hold now: each one a powered admin sits in, and what it tows.
local function wantedVehicles()
    local wanted = {}
    for _, player in ipairs(ServerPowers.activePlayers(power)) do
        local vehicle = player:getVehicle()
        local depth = 0
        while vehicle and depth <= MAX_TOW_CHAIN and not wanted[vehicle:getId()] do
            wanted[vehicle:getId()] = vehicle
            vehicle = vehicle:getVehicleTowing()
            depth = depth + 1
        end
    end
    return wanted
end

local function heldIds()
    local ids = {}
    for id in pairs(held) do
        ids[#ids + 1] = id
    end
    return ids
end

-- Every answer about the power also carries the held vehicles.
power.replyExtra = function()
    return { ids = heldIds() }
end

local function onTick()
    local wanted = wantedVehicles()
    local changed = false

    local gone = {}
    for id, entry in pairs(held) do
        if wanted[id] ~= entry.vehicle then gone[#gone + 1] = id end
    end
    for _, id in ipairs(gone) do
        held[id] = nil
        changed = true
    end

    for id, vehicle in pairs(wanted) do
        local entry = held[id]
        if entry then
            GodVehicle.holdVehicle(vehicle, entry.parts, true)
        else
            held[id] = { vehicle = vehicle, parts = GodVehicle.readVehicle(vehicle) }
            changed = true
            if isServer() then
                -- Clients start holding from the server's values, not from damage
                -- only their own copy took earlier.
                for i = 0, vehicle:getPartCount() - 1 do
                    local part = vehicle:getPartByIndex(i)
                    if part then vehicle:transmitPartCondition(part) end
                end
            end
        end
    end

    if changed and isServer() then
        ServerPowers.send(nil, ZomboidFixesB42.CMD_GOD_VEHICLES, { ids = heldIds() })
    end
end

Events.OnTick.Add(onTick)

-- Single player: a new game keeps this file's state.
Events.OnInitWorld.Add(function()
    held = {}
end)

-- The wear and drains that go through Lua -------------------------------------

for _, name in ipairs({ "GasTank", "Tire", "Brakes" }) do
    local vanilla = Vehicles.Update[name]
    if vanilla then
        Vehicles.Update[name] = function(vehicle, part, elapsedMinutes, ...)
            if isHeld(vehicle) then return end
            return vanilla(vehicle, part, elapsedMinutes, ...)
        end
    end
end

local vanillaLowerCondition = Vehicles.LowerCondition
Vehicles.LowerCondition = function(vehicle, part, elapsedMinutes, ...)
    if isHeld(vehicle) then return 0 end
    return vanillaLowerCondition(vehicle, part, elapsedMinutes, ...)
end

local vanillaChargeBattery = VehicleUtils.chargeBattery
VehicleUtils.chargeBattery = function(vehicle, delta, ...)
    if delta < 0 and isHeld(vehicle) then return end
    return vanillaChargeBattery(vehicle, delta, ...)
end

local function wrapMethod(class, name, makeWrapper)
    local meta = __classmetatables and class and __classmetatables[class.class]
    local index = meta and meta.__index
    local vanilla = index and index[name]
    if not vanilla then
        print("[ZomboidFixesB42] GodVehicle: " .. name .. " is not reachable, crashes and smashed windows are only put back")
        return
    end
    index[name] = makeWrapper(vanilla)
end

local function skipWhenHeld(vanilla)
    return function(vehicle, ...)
        if isHeld(vehicle) then return end
        return vanilla(vehicle, ...)
    end
end

wrapMethod(BaseVehicle, "crash", skipWhenHeld)
wrapMethod(BaseVehicle, "damageFromHitChr", skipWhenHeld)

local function skipWindowWhenHeld(vanilla)
    return function(window, ...)
        local part = window and window:getPart()
        if part and isHeld(part:getVehicle()) then return end
        return vanilla(window, ...)
    end
end

wrapMethod(VehicleWindow, "damage", skipWindowWhenHeld)
wrapMethod(VehicleWindow, "hit", skipWindowWhenHeld)
