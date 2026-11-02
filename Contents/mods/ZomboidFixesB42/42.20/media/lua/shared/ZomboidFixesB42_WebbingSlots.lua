--[[
    Zomboid Fixes B42.20 -- shared, chest rigs and ALICE suspenders in slots of their own

    The Chest Rig, the Tarp Chest Rig and the three ALICE Belt and Suspenders are
    all worn at base:webbing (items/container.txt, 42.21), so putting one on takes
    the other off, although a rig over webbing suspenders is a common military
    load. With the ChestRigOverSuspenders option on, the suspenders are worn at
    zomboidfixesb42:suspenders and the rigs at zomboidfixesb42:chestrig. Each
    follows every rule webbing has, exclusivity with webbing itself included (an
    item another mod still wears there clashes with both, as before), but the two
    are not exclusive with each other.

    Body locations (Java, 42.21) ------------------------------------------------

    A location is an ItemBodyLocation from Registries.ITEM_BODY_LOCATION.
    RegistryReset.resetAll (start-up, every Lua reset, joining a server, leaving a
    game) drops every one outside the base namespace, then ModRegistries.init runs
    each active mod's media/registries.lua, then the item scripts load (a
    `BodyLocation = ns:name` line resolves through the registry, an unknown name
    gives null). So the locations are registered in ../../registries.lua, every
    time, and this file only uses them.

    The rules live in BodyLocations.getGroup("Human"), rebuilt from scratch by
    vanilla's shared/NPCs/BodyLocations.lua on the same resets (BodyLocations.reset
    clears every group). Each BodyLocation keeps three lists of other locations:
    exclusive (WornItems.setItem takes off any worn item whose location is
    exclusive with the new one; setExclusive writes both sides), hideModel (a worn
    item at the first hides the model of one at the second) and altModel (an item
    draws its clothing XML's m_AltMaleModel / m_AltFemaleModel when another worn
    item's location lists its own, PopTemplateManager.isItemModelAlt). None has a
    getter for its list, so the copy asks group:isExclusive / isHideModel /
    isAltModel for webbing against every location, both ways, and sets the same
    for each new location. Webbing is exclusive with the shoulder holster, fanny
    packs, bulky jackets, full suits, the SCBA, sport and armor shoulder pads;
    jackets, sweaters, cuirasses and bulletproof vests make webbing items draw
    their jacket model; a full robe hides webbing. WornItems keeps worn items in
    the group's order, which is also the order they are drawn and the order a
    zombie hit looks for the outermost layer, so the new locations follow webbing
    as webbing, suspenders, chest rig: the rig is the outer of the two.

    The rules are copied when this file loads (after vanilla's BodyLocations.lua:
    vanilla's shared files load before mods' in the same folder) and again at
    OnLoadMapZones, for rules another mod adds later; every set call ignores a
    rule already there.

    Items: Item.DoParam("BodyLocation" | "CanBeEquipped", name) resolves the name
    in the registry. InventoryContainer.canBeEquipped (what ISWearClothing wears a
    bag at) is copied from the script when an item is created and not saved, so
    the scripts are changed at OnLoadMapZones, before the player and the chunks
    load (IsoWorld.init), and every rig or belt loaded after that wears at its new
    location. The worn location itself is saved with the player (the location
    string, IsoGameCharacter.readInventory), so one already worn at webbing stays
    there until it is taken off and put on again, and one worn at a new location
    stays worn there when the option is turned off later. SyncClothingPacket
    carries each worn item's location, so the server and the other clients wear
    it at the same place. Hotbar slots come from the item script's
    AttachmentsProvided, not from the location, so the belts' knife and walkie
    slots are unchanged.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local OPTION = "ChestRigOverSuspenders"

-- In wearing order: each slot goes right after the one before it, the first after webbing.
local SLOTS = {
    {
        location = "zomboidfixesb42:suspenders",
        items = { "Base.Bag_ALICE_BeltSus", "Base.Bag_ALICE_BeltSus_Camo", "Base.Bag_ALICE_BeltSus_Green" },
    },
    {
        location = "zomboidfixesb42:chestrig",
        items = { "Base.Bag_ChestRig", "Base.Bag_ChestRig_Tarp" },
    },
}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars[OPTION] == true
end

local function log(text)
    print("[ZomboidFixesB42] webbing slots: " .. text)
end

local function bodyLocation(name)
    local ok, location = pcall(function() return ItemBodyLocation.get(ResourceLocation.of(name)) end)
    if ok then return location end
    return nil
end

-- moveLocationToIndex removes the location first, which shifts `after` down when it sat before it.
local function placeAfter(group, location, after)
    local index, afterIndex = group:indexOf(location), group:indexOf(after)
    if index > afterIndex + 1 then
        group:moveLocationToIndex(location, afterIndex + 1)
    elseif index < afterIndex then
        group:moveLocationToIndex(location, afterIndex)
    end
end

-- Gives `location` every rule webbing has, exclusivity with webbing included.
local function copyWebbingRules(group, location, webbing, skip)
    group:getOrCreateLocation(location)
    local locations = group:getAllLocations()
    for i = 0, locations:size() - 1 do
        local other = locations:get(i):getId()
        if other ~= location and not skip[other] then
            if group:isExclusive(webbing, other) or group:isExclusive(other, webbing) then
                group:setExclusive(location, other)
            end
            if group:isHideModel(webbing, other) then group:setHideModel(location, other) end
            if group:isHideModel(other, webbing) then group:setHideModel(other, location) end
            if group:isAltModel(webbing, other) then group:setAltModel(location, other) end
            if group:isAltModel(other, webbing) then group:setAltModel(other, location) end
        end
    end
    group:setExclusive(location, webbing)
    group:setMultiItem(location, group:isMultiItem(webbing))
end

-- Returns the slots' locations, or nil when one is missing.
local function setUpLocations()
    local webbing = ItemBodyLocation.WEBBING
    local group = BodyLocations.getGroup("Human")
    if not group:getLocation(webbing) then return nil end

    local locations, skip = {}, {}
    for i, slot in ipairs(SLOTS) do
        locations[i] = bodyLocation(slot.location)
        if not locations[i] then
            log(slot.location .. " is not registered (media/registries.lua did not run)")
            return nil
        end
        skip[locations[i]] = true
    end
    local after = webbing
    for i = 1, #locations do
        copyWebbingRules(group, locations[i], webbing, skip)
        placeAfter(group, locations[i], after)
        after = locations[i]
    end
    return locations
end

setUpLocations()

local function onLoadMapZones()
    if not setUpLocations() or not isEnabled() then return end
    for _, slot in ipairs(SLOTS) do
        for _, fullType in ipairs(slot.items) do
            local item = ScriptManager.instance:getItem(fullType)
            if item then
                item:DoParam("BodyLocation", slot.location)
                item:DoParam("CanBeEquipped", slot.location)
            else
                log("item not found: " .. fullType)
            end
        end
    end
end

Events.OnLoadMapZones.Add(onLoadMapZones)
