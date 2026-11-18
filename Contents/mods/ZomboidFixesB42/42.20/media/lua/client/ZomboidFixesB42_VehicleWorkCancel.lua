--[[
    Zomboid Fixes B42.20 -- client, moving cancels work on a car

    Two vanilla vehicle actions done standing at a car set stopOnWalk and
    stopOnRun to false in their new (shared/Vehicles/TimedActions, 42.22). Java
    reads both flags once, in the LuaTimedActionNew constructor that
    ISBaseTimedAction:create builds (client and single player; an MP server never
    reads them), and BaseAction stops an action on walking or running only when
    they are true. So moving never cancelled them:
    - ISRemoveBurntVehicle (taking a burnt or smashed car apart with a blowtorch):
      800 ticks minus 20 a Welding level. Its isValid only wants a blowtorch with
      10 uses in the primary hand and the car still there, so once started the
      character kept the torch going (and kept facing the car) until the bar was
      full, or until the torch was taken out of their hand.
    - ISWashVehicle: looped (-1), it ends when that side's blood is gone or the
      water runs out, then perform queues the next dirty side (walk + wash). Its
      isValid ends it only once the character leaves that side's area, so moving
      about inside it washed on. Blood is removed a little at a time (the server's
      emulated WashUpdate events, single player's update), so a cancel keeps what
      was cleaned.

    Vanilla's other vehicle actions with these flags off are done from a seat
    (doors, windows, engine, hotwire, locks) or are short; the long work outside
    a car (installing and removing parts, engine repair) stops on walking. This
    file puts both flags back to true in create, right before the Java action is
    built, so walking or running cancels these two the way it cancels other work.
    A cancel in MP goes the usual way (the client's stop tells the server), and
    ISBaseTimedAction.stop clears the rest of the queue (a wash's next sides).

    Neither class has a create of its own, so the base class's is called at call
    time, and other mods' wrappers of ISBaseTimedAction.create still run.
--]]

require "TimedActions/ISBaseTimedAction"
require "Vehicles/TimedActions/ISRemoveBurntVehicle"
require "Vehicles/TimedActions/ISWashVehicle"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.VehicleWorkCancel == true
end

local function wrap(class)
    if not class then return end
    local ownCreate = rawget(class, "create")
    class.create = function(self, ...)
        if isEnabled() then
            self.stopOnWalk = true
            self.stopOnRun = true
        end
        return (ownCreate or ISBaseTimedAction.create)(self, ...)
    end
end

wrap(ISRemoveBurntVehicle)
wrap(ISWashVehicle)
