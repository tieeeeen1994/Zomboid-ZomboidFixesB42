--[[
    Zomboid Fixes B42.20 -- client, server and single player, the shoulder holster
    stores any item (off by default)

    The shoulder holster (Base.HolsterShoulder, items/container.txt) is a container
    (Capacity 1, WeightReduction 85) as well as the provider of the HolsterShoulder
    hotbar slot that the pistol hangs on. Its script names
    AcceptItemFunction = AcceptItemFunction.HolsterShoulder
    (server/Items/AcceptItemFunction.lua, 42.22):

        return item:hasTag(ItemTag.PISTOL_MAGAZINE) and container:getItems():size() < 2

    so the container takes pistol magazines only, two at most, whatever room is
    left; its tooltip says "Can be used to store two pistol magazines."

    Java (ItemContainer.isItemAllowed, 42.22) looks the function up by name with
    LuaManager.getFunctionObject, which caches the function object on its first
    lookup (cleared on a Lua reload), and calls it for every check: dragging, the
    transfer action, floor pickups and the server's transaction checks, on the
    client and the server alike. So the function is replaced here at file load,
    before any container is checked. This file must run on both sides (the client
    refuses the drag first, the server the transaction), hence no isClient() guard;
    it lives in the server folder because vanilla's table is defined there (the
    shared folder loads first and `AcceptItemFunction = {}` would wipe a shared
    copy), and this folder also loads on clients and in single player.

    With the option on, anything goes in; the holster's capacity (1, checked by
    ItemContainer.hasRoomFor against the items' own weights) stays the only limit,
    so two magazines still fit, and so do other small things, but not a pistol
    (1.2 to 2). The option is read live at every check. The item tooltip is swapped
    for one that says so with Item:DoParam("Tooltip", key) at world load
    (ScriptFixes, OnLoadMapZones): every holster created afterwards, loaded ones
    included, copies its tooltip from the script at InstanceItem, so a changed
    option shows in the tooltip after a restart. The tooltip key is a mod
    translation, which a dedicated server lacks, but only clients draw it.
    Off by default: a balance change, not a bug.
--]]

require "Items/AcceptItemFunction"
require "ZomboidFixesB42_ScriptFixes"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local ScriptFixes = ZomboidFixesB42.ScriptFixes

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ShoulderHolsterAnyItem == true
end

if AcceptItemFunction and AcceptItemFunction.HolsterShoulder then
    local vanillaHolsterShoulder = AcceptItemFunction.HolsterShoulder

    function AcceptItemFunction.HolsterShoulder(container, item)
        if isEnabled() then return true end
        return vanillaHolsterShoulder(container, item)
    end
end

ScriptFixes.register("ShoulderHolsterAnyItem", "ShoulderHolsterTooltip",
    function()
        ScriptFixes.setParams({
            ["Base.HolsterShoulder"] = { Tooltip = "Tooltip_item_ZomboidFixesB42_HolsterShoulder" },
        })
    end)
