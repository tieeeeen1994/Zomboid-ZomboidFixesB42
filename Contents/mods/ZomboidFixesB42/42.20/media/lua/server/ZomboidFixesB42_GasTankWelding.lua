--[[
    Zomboid Fixes B42.20 -- server, welding an installed gas tank

    Repairing a part still on a vehicle runs ISFixVehiclePartAction
    (shared/TimedActions/ISFixVehiclePartAction.lua, 42.21). Its complete() fixes
    the part's item with FixingManager.fixItem (uses up the blowtorch and the sheet
    metal), copies the new condition to the part, and then, for a part that is a
    container without an item container, clamps the content to the capacity:

        self.vehiclePart:setContainerContentAmount(part:getContainerContentAmount())

    `part` is an undefined global, so this line errors (~41). Of the vanilla
    vehicle repairs only "Fix Gas Tank Welding" reaches it (trunks, glove boxes and
    seats have item containers, tires have no repair). Everything before the
    error stays done: the materials are gone and the server's part has its new
    condition. Everything after it is skipped: updatePartStats, updateBulletStats
    and transmitPartItem. VehiclePart.setCondition sends nothing by itself, so in
    multiplayer the client never sees the repair (until the vehicle is sent to it
    again), and the Lua error makes ActionManager reject the action. Single player
    gets the same error, with the new condition but without the part stats update.

    complete() only runs on the server and in single player (NetTimedAction calls
    it on the server; Java LuaTimedActionNew.complete only off a client), so this
    replaces it there with vanilla's code, reading the part's own content amount.
--]]

if isClient() then return end

require "TimedActions/ISFixVehiclePartAction"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.GasTankWelding == true
end

local vanillaComplete = ISFixVehiclePartAction.complete

function ISFixVehiclePartAction:complete()
    if not isEnabled() then
        return vanillaComplete(self)
    end

    local part = self.vehiclePart
    FixingManager.fixItem(self.item, self.character, self.fixing, self.fixer)
    part:setCondition(self.item:getCondition())
    part:doInventoryItemStats(self.item, part:getMechanicSkillInstaller())
    if part:isContainer() and not part:getItemContainer() then
        -- Changing condition might change capacity; this limits the content to it.
        part:setContainerContentAmount(part:getContainerContentAmount())
    end
    local vehicle = part:getVehicle()
    vehicle:updatePartStats()
    vehicle:updateBulletStats()
    vehicle:transmitPartItem(part)
    return true
end
