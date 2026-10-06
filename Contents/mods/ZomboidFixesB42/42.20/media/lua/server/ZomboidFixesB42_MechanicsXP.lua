--[[
    Zomboid Fixes B42.20 -- server, the once-a-day Mechanics XP per part survives reloads

    Taking a part off, putting it on, and repairing an engine or a lightbar give
    Mechanics XP only once per part and vehicle per in-game day:
    IsoPlayer.addMechanicsItem(key, part, time) gives XP when `key` is not in the
    player's mechanicsItem map, and entries expire after 24 game hours
    (updateMechanicsItems). The keys are built in Lua from the vehicle's mechanical
    ID, e.g. ISInstallVehiclePart:complete:

        self.character:addMechanicsItem(self.item:getID() .. self.vehicle:getMechanicalID() .. "1", ...)

    The map, the item IDs and the vehicle's mechanicalId are all saved. But
    BaseVehicle.createPhysics, which runs every time a vehicle is added to the world
    (world load, server restart, its chunk loading again), ends with

        this.mechanicalId = Rand.Next(100000);
        LuaEventManager.triggerEvent("OnSpawnVehicleEnd", this);

    whether the vehicle is new or was just loaded with its saved ID. Every key made
    before then stops matching, so the same parts give XP again after a reload, or
    after walking away and back (forum 97845, single player and dedicated servers).

    createPhysics fires OnSpawnVehicleStart before it does anything (unless the
    vehicle already has physics, or it is a script swap), so the ID the vehicle
    came with is noted there and put back on OnSpawnVehicleEnd. A new vehicle has
    no ID yet (0) and keeps the random one it is given. Runs where the XP is given:
    the server, and the game in single player. Keys already lost to earlier
    reloads are not recovered; from now on they hold.
--]]

if isClient() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MechanicsXPLimit == true
end

-- [vehicle] = the mechanical ID it had when createPhysics started.
local pending = {}

local function onSpawnVehicleStart(vehicle)
    if not vehicle or not isEnabled() then return end
    local id = vehicle:getMechanicalID()
    if id and id ~= 0 then
        pending[vehicle] = id
    else
        pending[vehicle] = nil
    end
end

local function onSpawnVehicleEnd(vehicle)
    if not vehicle then return end
    local id = pending[vehicle]
    pending[vehicle] = nil
    if id and isEnabled() and vehicle:getMechanicalID() ~= id then
        vehicle:setMechanicalID(id)
    end
end

Events.OnSpawnVehicleStart.Add(onSpawnVehicleStart)
Events.OnSpawnVehicleEnd.Add(onSpawnVehicleEnd)
