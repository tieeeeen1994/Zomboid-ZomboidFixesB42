--[[
    Zomboid Fixes B42.20 -- server, No Wear admin power

    Keeps the items of every admin with No Wear on at full (what that means:
    shared/ZomboidFixesB42_AdminNoWear.lua). The server's copy is the one saved,
    so the work is done here: the items in hand every tick, everything in scope
    every SCAN_MS.

    Getting the changes to the owner: item:syncItemFields() on the server sends a
    SyncItemFieldsPacket to the owner (InventoryItem.syncItemFields: the item's
    outermost container belongs to a player), which carries condition, head
    condition, sharpness and, for clothing, the whole ItemVisual (holes included)
    both ways. A worn item's holes are also part of the player's look, which other
    players get through player:syncVisuals() (on the server: SyncVisuals and
    HumanVisual to everyone, the owner included). Wear made on the owner's client
    (combat) reaches the server through the client's own SyncItemFields and is put
    back on the next pass; the client file also refills the items in hand on the
    spot, so a weapon cannot break between two passes.

    The clothing wear rework (server/ZomboidFixesB42_ClothingWear.lua) asks
    NoWear.isActive before it wears anyone's clothing, so it neither wears these
    clothes nor puts holes back that this file took away.
--]]

if isClient() then return end

local ServerPowers = ZomboidFixesB42.ServerPowers
local NoWear = ZomboidFixesB42.NoWear
local power = NoWear.power

-- How often everything in scope is filled, in ms (the items in hand every tick).
local SCAN_MS = 500

function NoWear.isActive(player)
    return ServerPowers.isOn(power, player)
end

--- Fills what `each` walks and sends the changes.
local function fill(player, each)
    local lookChanged = false
    each(player, function(item)
        local changed, holes = NoWear.fillItem(item)
        if changed then
            item:syncItemFields()
            if holes and item:isWorn() then lookChanged = true end
        end
    end)
    if lookChanged then
        if isServer() then
            player:syncVisuals()
        else
            player:resetModelNextFrame()
        end
    end
end

local lastScan = 0

local function onTick()
    local players = ServerPowers.activePlayers(power)
    if #players == 0 then return end
    local now = getTimestampMs()
    local scan = now - lastScan >= SCAN_MS
    if scan then lastScan = now end
    for _, player in ipairs(players) do
        fill(player, scan and NoWear.eachItem or NoWear.eachHandItem)
    end
end

Events.OnTick.Add(onTick)
