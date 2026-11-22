--[[
    Zomboid Fixes B42.20 -- shared, mod items with no item type

    B42 reads an item's kind only from `ItemType = base:normal` (42.22
    Item.DoParam: `ItemType.get(ResourceLocation.of(value))`). The B41 key
    `Type = Normal` is no longer read at all, so a mod item still written that way
    has a null item type. Two things then break:

    - Item.InstanceItem picks the Java class (Food, Clothing, MapItem, plain
      InventoryItem...) by item type and has no fallback, so with a null type
      `item` stays null and the next line (`item.setColor` / `setAlcoholPower`)
      throws a NullPointerException. Every spawn of that item fails: loot rolls,
      /additem, the Item List's add buttons.
    - The admin Item List (ISItemsListTable:initList ~244) calls
      `v:getItemType():toString()` on every item of a module, so one untyped item
      stops the whole list from opening with a Lua error.

    Seen 2026-11-22 with Slocan Lake (Arcadia, workshop 3840538932): its five map
    items (GolfCardMap, NewDenverMap, RoseberyMap, SilvertonMap, SLRegionMap) say
    `Type = Normal`, with `Map =` a PNG path rather than a map ID, and are added to
    the MagazineRackMaps loot list.

    At world load (OnLoadMapZones, through ScriptFixes, so a changed option waits
    for the next load) every item script whose type is still null gets
    `ItemType = base:normal`, a plain item, which is what such ports declared in
    B41 in most cases and never crashes. The real kind cannot be read back (the
    old value is dropped at parse time), so each item fixed is named in the log
    (console.txt / the server log) for the mod's author to correct.
]]

require "ZomboidFixesB42_ScriptFixes"

local ScriptFixes = ZomboidFixesB42.ScriptFixes

ScriptFixes.register("UntypedModItems", "UntypedModItems",
    function()
        local items = getScriptManager():getAllItems()
        local fixed = 0
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and item:getItemType() == nil then
                item:DoParam("ItemType", "base:normal")
                fixed = fixed + 1
                ScriptFixes.log("item " .. tostring(item:getFullName())
                    .. " has no ItemType (B41 `Type =`?), now base:normal")
            end
        end
        if fixed > 0 then
            ScriptFixes.log(string.format("%d item(s) without an ItemType given base:normal", fixed))
        end
    end)
