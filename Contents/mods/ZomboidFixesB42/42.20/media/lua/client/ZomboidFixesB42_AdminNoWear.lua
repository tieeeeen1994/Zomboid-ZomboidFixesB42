--[[
    Zomboid Fixes B42.20 -- client, No Wear admin power

    Adds No Wear to the Admin Powers window and so to the admin hotbar
    (ZomboidFixesB42_AdminHotbarActions.lua). The server keeps the admin's
    items at full (server/ZomboidFixesB42_AdminNoWear.lua).

    Combat wear happens on the attacker's own client (CombatManager damageCheck,
    then SyncItemFields to the server), and a weapon at 0 breaks right there, before
    the server's copy has heard of it. So while the power is on, this client also
    refills the items in its hands every tick and sends them (item:syncItemFields
    on a client goes to the server, which takes the values as they are). Single
    player: the server file does all of it.
--]]

require "ISUI/AdminPanel/ISAdminPowerUI"

local ServerPowers = ZomboidFixesB42.ServerPowers
local NoWear = ZomboidFixesB42.NoWear
local power = NoWear.power

ServerPowers.addOption(power)

local function onTick()
    if not power.active or not ServerPowers.isEnabled(power) then return end
    local player = getPlayer()
    if not ServerPowers.isAllowed(power, player) then return end
    NoWear.eachHandItem(player, function(item)
        if NoWear.fillItem(item) then item:syncItemFields() end
    end)
end

if isClient() then
    Events.OnTick.Add(onTick)
end
