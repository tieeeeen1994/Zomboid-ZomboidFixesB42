--[[
    Zomboid Fixes B42.20 -- shared, no max item size for bags (off by default)

    MaxItemSize in an item script limits the weight of any single item a bag takes
    (ItemContainer.hasRoomFor; InventoryContainer.getMaxItemSize reads it live from
    the script, and the tooltip's "max item size" row is shown while it is not 0).
    Vanilla 42.21 gives it to the ALICE belt and suspenders and the chest rigs (1.3),
    totes, purses, handbags, toolboxes and briefcases (2), first aid kits, lunchboxes,
    the tackle box, cash box and tool rolls (1), hollow books (1.6), sewing kits,
    jewellery boxes and small first aid kits (0.3), wallets and photo albums (0.2).

    With this option on, every item script with a MaxItemSize gets 0 (no limit) at
    world load, on the client and the server alike (ScriptFixes, re-checked every ten
    game minutes), so the bag's own capacity is the only limit, in every check:
    dragging, the transfer action, floor pickups and the server's transaction checks.
    Mods' bags are included. Switching it off puts each value back.
--]]

require "ZomboidFixesB42_ScriptFixes"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local ScriptFixes = ZomboidFixesB42.ScriptFixes

-- [Item script] = the MaxItemSize it had.
local original = {}

ScriptFixes.register("RemoveMaxItemSize", "RemoveMaxItemSize",
    function()
        original = {}
        local items = ScriptManager.instance:getAllItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            local size = item:getMaxItemSize()
            if size and size > 0 then
                original[item] = size
                item:DoParam("MaxItemSize", "0")
            end
        end
    end,
    function()
        for item, size in pairs(original) do
            item:DoParam("MaxItemSize", tostring(size))
        end
        original = {}
    end)
