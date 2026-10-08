--[[
    Zomboid Fixes B42.20 -- client, God Vehicle admin power

    Adds God Vehicle to the Admin Powers window and the admin hotbar. While an admin
    with it on sits in a vehicle, that vehicle does not wear down; the server does
    the work (server/ZomboidFixesB42_AdminGodVehicle.lua explains where vehicles
    lose condition, fuel and charge, and how each is stopped or put back). The power
    itself is kept by the server (shared/ZomboidFixesB42_ServerPowers.lua).

    Every multiplayer client also holds its own copy of each vehicle the server
    holds: a zombie thumping a car door (AttackVehicleState) lowers the condition
    only on the clients animating it and sends nothing, so without this the car
    would look dented to them while the server's stays whole. The server
    broadcasts the held vehicle IDs whenever they change (CMD_GOD_VEHICLES, and with
    every answer about the power); a client starts holding a vehicle SETTLE_MS
    after it shows up there, so the conditions the server sends when it starts
    holding (its real values) arrive first.
--]]

require "ISUI/AdminPanel/ISAdminPowerUI"

local GodVehicle = ZomboidFixesB42.GodVehicle

-- A newly held vehicle is held on this client from this long after the server
-- named it, in ms.
local SETTLE_MS = 1500

-- [vehicle id] = getTimestampMs() when the server named it
local named = {}
-- [vehicle id] = { vehicle = BaseVehicle, parts = snapshot }
local mirrored = {}

local function setNamed(ids)
    if not isClient() or type(ids) ~= "table" then return end
    local now = getTimestampMs()
    local fresh = {}
    for _, id in ipairs(ids) do
        id = math.floor(tonumber(id) or -1)
        if id >= 0 then fresh[id] = named[id] or now end
    end
    named = fresh
    local gone = {}
    for id in pairs(mirrored) do
        if not named[id] then gone[#gone + 1] = id end
    end
    for _, id in ipairs(gone) do
        mirrored[id] = nil
    end
end

ZomboidFixesB42.ServerPowers.addOption(GodVehicle.power)

GodVehicle.power.onState = function(args)
    setNamed(args.ids)
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_GOD_VEHICLES then return end
    if type(args) == "table" then setNamed(args.ids) end
end)

local function onTick()
    local now = getTimestampMs()
    for id, since in pairs(named) do
        if now - since >= SETTLE_MS then
            local vehicle = getVehicleById(id)
            local entry = mirrored[id]
            if not vehicle then
                mirrored[id] = nil
            elseif not entry or entry.vehicle ~= vehicle then
                -- First seen, or streamed in again as a new object.
                mirrored[id] = { vehicle = vehicle, parts = GodVehicle.readVehicle(vehicle) }
            else
                GodVehicle.holdVehicle(vehicle, entry.parts, false)
            end
        end
    end
end

if isClient() then
    Events.OnTick.Add(onTick)
end

Events.OnInitWorld.Add(function()
    named = {}
    mirrored = {}
end)
