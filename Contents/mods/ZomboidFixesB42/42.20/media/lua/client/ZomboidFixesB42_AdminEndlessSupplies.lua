--[[
    Zomboid Fixes B42.20 -- client, Endless Supplies admin power

    Adds Endless Supplies to the Admin Powers window and so to the admin hotbar
    (ZomboidFixesB42_AdminHotbarActions.lua). The server keeps the
    admin's charges full (server/ZomboidFixesB42_AdminEndlessSupplies.lua).

    Charges used up on the admin's own client (an item in hand drained by the
    client, then sent with SyncItemFields) could run an item out before the
    server's next pass, so while the power is on this client also refills the items
    in its hands every tick and sends them. Single player: the server file does all
    of it.
--]]

require "ISUI/AdminPanel/ISAdminPowerUI"

local ServerPowers = ZomboidFixesB42.ServerPowers
local EndlessSupplies = ZomboidFixesB42.EndlessSupplies
local power = EndlessSupplies.power

ServerPowers.addOption(power)

local function onTick()
    if not power.active or not ServerPowers.isEnabled(power) then return end
    local player = getPlayer()
    if not ServerPowers.isAllowed(power, player) then return end
    EndlessSupplies.eachHandItem(player, function(item)
        if EndlessSupplies.fillItem(item) then item:syncItemFields() end
    end)
end

if isClient() then
    Events.OnTick.Add(onTick)
end
