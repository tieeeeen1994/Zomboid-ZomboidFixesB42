--[[
    Zomboid Fixes B42.20 -- server, Endless Supplies admin power

    Keeps the charges of every admin with Endless Supplies on at full (what that
    means: shared/ZomboidFixesB42_AdminEndlessSupplies.lua). The server's copy is
    the one saved and the one crafting, building and other server-run actions use
    up, so the work is done here: the items in hand every tick, everything carried
    every SCAN_MS, each change sent to the owner with item:syncItemFields() (on the
    server: a SyncItemFieldsPacket to the player whose inventory holds it, which
    carries the uses).
--]]

if isClient() then return end

local ServerPowers = ZomboidFixesB42.ServerPowers
local EndlessSupplies = ZomboidFixesB42.EndlessSupplies
local power = EndlessSupplies.power

-- How often everything carried is filled, in ms (the items in hand every tick).
local SCAN_MS = 500

local function fill(item)
    if EndlessSupplies.fillItem(item) then item:syncItemFields() end
end

local lastScan = 0

local function onTick()
    local players = ServerPowers.activePlayers(power)
    if #players == 0 then return end
    local now = getTimestampMs()
    local scan = now - lastScan >= SCAN_MS
    if scan then lastScan = now end
    for _, player in ipairs(players) do
        if scan then
            ServerPowers.eachCarriedItem(player, fill)
        else
            EndlessSupplies.eachHandItem(player, fill)
        end
    end
end

Events.OnTick.Add(onTick)
