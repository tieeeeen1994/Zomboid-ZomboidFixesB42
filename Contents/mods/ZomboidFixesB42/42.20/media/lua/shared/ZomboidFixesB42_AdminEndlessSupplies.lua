--[[
    Zomboid Fixes B42.20 -- shared, Endless Supplies admin power

    While an admin has Endless Supplies on, every item with charges they carry
    (main inventory, held, worn and attached items, and everything in their bags)
    stays at full charges: batteries, lighters, propane torches, thread, duct tape,
    glue, paint and the rest. Turning it on fills them all up at once. Kept by the
    server per admin (shared/ZomboidFixesB42_ServerPowers.lua); the capability is
    AddItem, the item spawning one, since endless charges make materials out of
    nothing.

    Charges (42.21): a DrainableComboItem keeps whole uses, 0..getMaxUses() =
    floor(1 / useDelta) (getCurrentUses; setCurrentUses also updates the weight).
    Use() takes one; at 0 the item is replaced by its ReplaceOnDeplete item, kept
    (KeepOnDeplete) or removed, so an item can only be refilled before it runs
    out: the server refills often enough that ordinary use never gets there, and a
    KeepOnDeplete item at 0 (a lighter) is filled again. Other items' uses (the
    base InventoryItem, getMaxUses() = 1) are whole items, not charges, and are
    left alone, as are fluids. SyncItemFieldsPacket carries the uses both ways.
--]]

require "ZomboidFixesB42_ServerPowers"

local EndlessSupplies = {}
ZomboidFixesB42.EndlessSupplies = EndlessSupplies

EndlessSupplies.power = ZomboidFixesB42.ServerPowers.define({
    id = "ZomboidFixesB42_EndlessSupplies",
    option = "AdminEndlessSupplies",
    capability = Capability.AddItem,
    side = "right",
    logName = "Endless Supplies",
})

--- Fills one item's charges. Returns whether it changed.
function EndlessSupplies.fillItem(item)
    if not instanceof(item, "DrainableComboItem") then return false end
    local max = item:getMaxUses()
    if item:getCurrentUses() >= max then return false end
    item:setCurrentUses(max)
    return true
end

--- The items in hand: charges used every tick (a torch, a lit lighter) go first.
function EndlessSupplies.eachHandItem(player, fn)
    local primary = player:getPrimaryHandItem()
    if primary then fn(primary) end
    local secondary = player:getSecondaryHandItem()
    if secondary and secondary ~= primary then fn(secondary) end
end
