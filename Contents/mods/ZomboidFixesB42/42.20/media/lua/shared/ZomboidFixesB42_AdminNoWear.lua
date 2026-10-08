--[[
    Zomboid Fixes B42.20 -- shared, No Wear admin power

    While an admin has No Wear on, their items never wear down: every item in scope
    (sandbox AdminNoWearItems: what they hold, wear and have attached, or everything
    they carry, bags included) is kept at full condition, full head condition and
    full sharpness, and clothing has no holes. It fills them up when it is turned
    on, too. Kept by the server per admin (shared/ZomboidFixesB42_ServerPowers.lua);
    the capability is the item editor's (EditItem), since it rewrites the admin's
    items.

    The values (InventoryItem, 42.21):
      - condition 0..getConditionMax(); setCondition(int, false) clamps and clears
        the broken flag (Clothing's setCondition(int) would also take a worn item
        off at 0, the two-argument one never does).
      - head condition (weapons with a separate head, hasHeadCondition):
        0..getHeadConditionMax(), an item attribute.
      - sharpness (hasSharpness): 0..getMaxSharpness(), which is head condition (or
        condition) over its max, so it is filled after both, to 1.
      - clothing holes: ItemVisual holes per BloodBodyPartType (getHole > 0;
        removeHole(index)). A patch removes the hole under it (Clothing.addPatch),
        so every hole there is an open one; patches are left on.
    Where wear happens (all of these are put back): damageCheck / sharpnessCheck /
    headConditionCheck from combat (CombatManager, on the attacker's client, then
    SyncItemFields), tree chopping, crafting tools (CraftRecipeData, server), building
    (BuildAction hammer), Lua tool wear in timed actions, repairs (FixingManager
    lowers the item used), zombie attacks on clothing (holes and condition, client
    and server), clothing patches torn off by a hit (Clothing.removePatch).
--]]

require "ZomboidFixesB42_ServerPowers"

local NoWear = {}
ZomboidFixesB42.NoWear = NoWear

NoWear.power = ZomboidFixesB42.ServerPowers.define({
    id = "ZomboidFixesB42_NoWear",
    option = "AdminNoWear",
    capability = Capability.EditItem,
    side = "right",
    logName = "No Wear",
})

-- Smaller gaps than this are float noise.
local SHARPNESS_EPSILON = 0.0001

--- Fills one item. Returns whether anything changed, and whether clothing holes
-- were removed (a worn item's look then has to be synced).
function NoWear.fillItem(item)
    local changed = false

    local max = item:getConditionMax()
    if item:getCondition() < max then
        item:setConditionNoSound(max)
        changed = true
    end

    if item:hasHeadCondition() then
        local headMax = item:getHeadConditionMax()
        if item:getHeadCondition() < headMax then
            item:setHeadCondition(headMax)
            changed = true
        end
    end

    if item:hasSharpness() then
        local sharpMax = item:getMaxSharpness()
        if item:getSharpness() < sharpMax - SHARPNESS_EPSILON then
            item:setSharpness(sharpMax)
            changed = true
        end
    end

    local holes = false
    if instanceof(item, "Clothing") then
        local visual = item:getVisual()
        if visual and visual:getHolesNumber() > 0 then
            for i = 0, BloodBodyPartType.MAX:index() - 1 do
                if visual:getHole(BloodBodyPartType.FromIndex(i)) > 0 then
                    visual:removeHole(i)
                    holes = true
                end
            end
            if holes then changed = true end
        end
    end

    return changed, holes
end

--- The items in hand: wear from combat lands on these first and fastest.
function NoWear.eachHandItem(player, fn)
    local primary = player:getPrimaryHandItem()
    if primary then fn(primary) end
    local secondary = player:getSecondaryHandItem()
    if secondary and secondary ~= primary then fn(secondary) end
end

--- Every item in scope: held, worn and attached (scope 1), or everything carried,
-- bags included (scope 2, the default).
function NoWear.eachItem(player, fn)
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    if vars and vars.AdminNoWearItems == 1 then
        NoWear.eachHandItem(player, fn)
        local worn = player:getWornItems()
        for i = 0, worn:size() - 1 do
            local item = worn:getItemByIndex(i)
            if item then fn(item) end
        end
        local attached = player:getAttachedItems()
        for i = 0, attached:size() - 1 do
            local item = attached:getItemByIndex(i)
            if item then fn(item) end
        end
    else
        ZomboidFixesB42.ServerPowers.eachCarriedItem(player, fn)
    end
end
