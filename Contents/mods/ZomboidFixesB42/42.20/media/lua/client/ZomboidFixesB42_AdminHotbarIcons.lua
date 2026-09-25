--[[
    Zomboid Fixes B42.20 -- client, admin hotbar icons

    Every hotbar icon is an image the game already has; the mod ships none. An icon
    is stored as a reference and drawn with the game's own texture:

      sym:<id>        a map symbol (MapSymbolDefinitions: the 91 pictograms of the
                      map's marker tool, plus any a mod adds). White, so they tint.
      item:<type>     an item's icon, found the way Item List finds it: the script
                      item's icon (or the first of getIconsForTexture) as Item_<icon>.
      tex:<name>      any texture by name: a media/ui image, a trait or profession
                      icon (Texture:getName()), a tile sprite.

    All three resolve through tryGetTexture, which loads loose files and texture
    pack entries alike and returns nil instead of failing for a missing one, so an
    icon a later build removes just falls back to the action's default.

    Lua cannot list folders, so the media/ui images are a list of paths generated
    once from the game install (icon-sized files only; one size of the moodle and
    sidebar sets; the map symbols are left out because they have a tab of their own).
    Everything else is listed at runtime: map symbols, every script item (modded ones
    too), CharacterTraitDefinition / CharacterProfessionDefinition, and the tile sets
    from getWorld():getAllTilesName() the way the Tile Picker walks them.
--]]

if not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISColorPicker"
require "ZomboidFixesB42_AdminHotbar"

local Hotbar = ZomboidFixesB42.AdminHotbar
local Icons = {}
Hotbar.Icons = Icons

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6
local CELL = 44

local txt = Hotbar.txt

-- media/ui images, relative to media/ui/. Generated from the 42.20.4 install.
local UI_IMAGES = {
    "Admin_Icon.png", "Admin_Icon_On.png", "BugIcon.png", "Build_Tool.png",
    "Build_Tool_Off.png", "Client_Icon_Off.png", "Client_Icon_On.png", "Container_ClothingDryer.png",
    "Container_ClothingWasher.png", "Container_Composter.png", "Container_MailBox.png", "Container_Mannequin.png",
    "Container_ToolCabinet.png", "Debug_Icon_Off.png", "Debug_Icon_On.png", "FirearmRadial_BulletsFromFirearm.png",
    "FirearmRadial_BulletsIntoFirearm.png", "FirearmRadial_BulletsIntoMagazine.png", "FirearmRadial_ChamberRound.png", "FirearmRadial_EjectMagazine.png",
    "FirearmRadial_InsertMagazine.png", "FirearmRadial_Rack.png", "FirearmRadial_Unjam.png", "Icon_RecipeGroup_Closed_48x48.png",
    "Icon_RecipeGroup_Open_48x48.png", "Icon_RecipeGroup_Partial_48x48.png", "Item_SheepWhite_Lamb.png", "LightSourceRadial_InsertBattery.png",
    "LightSourceRadial_RemoveBattery.png", "Moodle_Icon_CantSprint.png", "Moodle_Icon_Windchill.png", "NinePatch1.png",
    "NinePatch2.png", "NinePatch3.png", "NinePatch4.png", "PointTensionN.png",
    "RadioButtonCircle.png", "RadioButtonIndicator.png", "ResizeIcon.png", "ScaleTensionN.png",
    "Search_Icon_Off.png", "Search_Icon_On.png", "Skull1.png", "Skull2.png",
    "Tick_Mark-10.png", "ZoomIn.png", "ZoomOut.png", "arrow_left.png",
    "arrow_right.png", "avatarBackgroundWhite.png", "back.png", "circle.png",
    "cursor_blank.png", "cursor_normal.png", "cursor_white.png", "dragModIcon.png",
    "gears.png", "group.png", "safetyOffLocked.png", "safetyOnLocked.png",
    "thumbdown.png", "thumbup.png", "war_active.png", "war_inactive.png",
    "war_soon.png", "wave.png", "wavebye.png", "zomboidDefaultMPIcon.png",
    "zomboidIcon128.png", "zomboidIcon16.png", "zomboidIcon32.png", "zomboidIcon64.png",
    "Animals/ChickenSlot_empty.png", "Animals/ChickenSlot_occupied.png", "Animals/chicken.png", "Animals/egg.png",
    "ClockAssets/ClockAlarmLargeSet.png", "ClockAssets/ClockAlarmLargeSound.png", "ClockAssets/ClockAlarmMediumSet.png", "ClockAssets/ClockAlarmMediumSound.png",
    "ClockAssets/ClockDigitsLarge0.png", "ClockAssets/ClockDigitsLarge1.png", "ClockAssets/ClockDigitsLarge2.png", "ClockAssets/ClockDigitsLarge3.png",
    "ClockAssets/ClockDigitsLarge4.png", "ClockAssets/ClockDigitsLarge5.png", "ClockAssets/ClockDigitsLarge6.png", "ClockAssets/ClockDigitsLarge7.png",
    "ClockAssets/ClockDigitsLarge8.png", "ClockAssets/ClockDigitsLarge9.png", "Entity/BuildProperty_Consume.png", "Entity/BuildProperty_Drain.png",
    "Entity/Crafting_Drain_24.png", "Entity/Crafting_Drain_32.png", "Entity/Crafting_Drain_48.png", "Entity/Crafting_Keep_24.png",
    "Entity/Crafting_Keep_32.png", "Entity/Crafting_Keep_48.png", "Entity/Icon_Crafted_48x48.png", "Entity/Icon_ExpandArrow_Closed_48x48.png",
    "Entity/Icon_ExpandArrow_Open_48x48.png", "Entity/Icon_ItemConsumed_48x48.png", "Entity/Icon_Returned_48x48.png", "Entity/Icon_Tools_48x48.png",
    "Entity/blueprint_info.png", "Entity/blueprint_panel.png", "Entity/fluid_drop_icon.png", "Entity/icon_arrow_consume.png",
    "Entity/icon_arrow_consume_grey.png", "Entity/icon_arrow_create.png", "Entity/icon_arrow_create_grey.png", "Entity/icon_clear_fluids.png",
    "Entity/icon_link_io.png", "Entity/icon_transfer_fluids.png", "Entity/Energy/icon_energy_electric.png", "Entity/Energy/icon_energy_mechanical.png",
    "Entity/Energy/icon_energy_solar.png", "Entity/Energy/icon_energy_steam.png", "Entity/Energy/icon_energy_thermal.png", "Entity/Energy/icon_energy_wind.png",
    "Entity/SlotStatus/frozen_12.png", "Entity/SlotStatus/frozen_24.png", "Entity/SlotStatus/frozen_48.png", "Entity/SlotStatus/hot_12.png",
    "Entity/SlotStatus/hot_24.png", "Entity/SlotStatus/hot_48.png", "Entity/SlotStatus/wet_12.png", "Entity/SlotStatus/wet_24.png",
    "Entity/SlotStatus/wet_48.png", "Entity/Vending/Slot_left.png", "Entity/Vending/Slot_right.png", "Entity/Vending/vending_btn_alpha_0.png",
    "Entity/Vending/vending_btn_alpha_1.png", "Entity/Vending/vending_btn_alpha_2.png", "Entity/Vending/vending_btn_alpha_3.png", "Entity/Vending/vending_btn_alpha_4.png",
    "Entity/Vending/vending_btn_alpha_5.png", "Entity/Vending/vending_btn_alpha_6.png", "Entity/Vending/vending_btn_alpha_7.png", "Entity/Vending/vending_btn_alpha_8.png",
    "Entity/Vending/vending_internal_0.png", "Entity/Vending/vending_internal_2.png", "Entity/Vending/vending_internal_6.png", "Entity/Vending/vending_internal_8.png",
    "Entity/Vending/vending_internal_unlit_0.png", "Entity/Vending/vending_internal_unlit_2.png", "Entity/Vending/vending_internal_unlit_6.png", "Entity/Vending/vending_internal_unlit_8.png",
    "Entity/Vending/vending_spiral_back.png", "Entity/Vending/vending_spiral_front.png", "Fluids/bubbles_seamless.png", "Fluids/fluid_gradient.png",
    "LCD_Display/LCD_Background_Large.png", "LCD_Display/LCD_Background_Small.png", "MP/mp_ui_add_icon.png", "MP/mp_ui_allVersions.png",
    "MP/mp_ui_checkbox.png", "MP/mp_ui_droplist.png", "MP/mp_ui_emptyServer.png", "MP/mp_ui_filters_checkbox_checked.png",
    "MP/mp_ui_fullServer.png", "MP/mp_ui_internet.png", "MP/mp_ui_mods.png", "MP/mp_ui_offline.png",
    "MP/mp_ui_online.png", "MP/mp_ui_passwordOff.png", "MP/mp_ui_passwordOn.png", "MP/mp_ui_password_eye.png",
    "MP/mp_ui_ping.png", "MP/mp_ui_playerCount.png", "MP/mp_ui_servericonbg.png", "MP/mp_ui_star.png",
    "MP/mp_ui_star_outline.png", "MP/mp_ui_subitem_first.png", "MP/mp_ui_whitelist.png", "Moodles/64/Mood_Angry.png",
    "Moodles/64/Mood_Bored.png", "Moodles/64/Mood_Concentrating.png", "Moodles/64/Mood_Dead.png", "Moodles/64/Mood_Discomfort.png",
    "Moodles/64/Mood_Dizzy.png", "Moodles/64/Mood_Drunk.png", "Moodles/64/Mood_Exhausted.png", "Moodles/64/Mood_Happy.png",
    "Moodles/64/Mood_Hungover.png", "Moodles/64/Mood_Ill.png", "Moodles/64/Mood_Nauseous.png", "Moodles/64/Mood_NoxiousSmell.png",
    "Moodles/64/Mood_Pained.png", "Moodles/64/Mood_Panicked.png", "Moodles/64/Mood_Sad.png", "Moodles/64/Mood_Scared.png",
    "Moodles/64/Mood_Sleepy.png", "Moodles/64/Mood_Stressed.png", "Moodles/64/Mood_Zombified.png", "Moodles/64/Status_Bleeding.png",
    "Moodles/64/Status_DifficultyBreathing.png", "Moodles/64/Status_HearingImpaired.png", "Moodles/64/Status_HeavyLoad.png", "Moodles/64/Status_Hunger.png",
    "Moodles/64/Status_InjuredMajor.png", "Moodles/64/Status_InjuredMinor.png", "Moodles/64/Status_MovementRestricted.png", "Moodles/64/Status_Sedated.png",
    "Moodles/64/Status_TemperatureHot.png", "Moodles/64/Status_TemperatureLow.png", "Moodles/64/Status_Thirst.png", "Moodles/64/Status_VisionImpaired.png",
    "Moodles/64/Status_Wet.png", "Moodles/64/Status_Windchill.png", "Moodles/64/Status_Wired.png", "Moodles/64/_Moodles_BGoutline.png",
    "Moodles/64/_Moodles_BGsolid.png", "Properties/InventoryProperty_Research.png", "Properties/InventoryProperty_Research_16.png", "Reticle/crosshair00.png",
    "Reticle/crosshair01.png", "Reticle/crosshair02.png", "Reticle/crosshair03.png", "Reticle/crosshair10.png",
    "Reticle/crosshair11.png", "Reticle/crosshair12.png", "Reticle/crosshair13.png", "Reticle/crosshair20.png",
    "Reticle/crosshair21.png", "Reticle/crosshair22.png", "Reticle/crosshair23.png", "Sidebar/64/ARF_Icon_Off_64.png",
    "Sidebar/64/ARF_Icon_On_64.png", "Sidebar/64/Admin_Icon_Off_64.png", "Sidebar/64/Admin_Icon_On_64.png", "Sidebar/64/AnimalZone_Off_64.png",
    "Sidebar/64/AnimalZone_On_64.png", "Sidebar/64/Build_Off_64.png", "Sidebar/64/Build_On_64.png", "Sidebar/64/BuildingRoomsEditor_64.png",
    "Sidebar/64/Carpentry_Off_64.png", "Sidebar/64/Carpentry_On_64.png", "Sidebar/64/Client_Icon_Off_64.png", "Sidebar/64/Client_Icon_On_64.png",
    "Sidebar/64/Debug_Off_64.png", "Sidebar/64/Debug_On_64.png", "Sidebar/64/Furniture_Disassemble_64.png", "Sidebar/64/Furniture_Off_64.png",
    "Sidebar/64/Furniture_On_64.png", "Sidebar/64/Furniture_Pickup_64.png", "Sidebar/64/Furniture_Place_64.png", "Sidebar/64/Furniture_Repair_64.png",
    "Sidebar/64/Furniture_Rotate_64.png", "Sidebar/64/HandMain_Off_64.png", "Sidebar/64/HandSecondary_Off_64.png", "Sidebar/64/Heart_Off_64.png",
    "Sidebar/64/Heart_On_64.png", "Sidebar/64/Inventory_Off_64.png", "Sidebar/64/Inventory_On_64.png", "Sidebar/64/Map_Off_64.png",
    "Sidebar/64/Map_On_64.png", "Sidebar/64/Safety_Background_64.png", "Sidebar/64/Safety_Tintable_64.png", "Sidebar/64/Search_Off_64.png",
    "Sidebar/64/Search_On_64.png", "Sidebar/64/War_Off_64.png", "Sidebar/64/War_On_64.png", "SkillPanel/SkillUnit_border.png",
    "SkillPanel/SkillUnit_fill.png", "Traits/trait_artisan.png", "Traits/trait_athletic.png", "Traits/trait_burglar.png",
    "Traits/trait_crafty.png", "Traits/trait_herbalist_prof.png", "Traits/trait_inventive.png", "Traits/trait_inventive_prof.png",
    "Traits/trait_mason.png", "Traits/trait_mechanics2.png", "Traits/trait_speeddemon.png", "Traits/trait_sundaydriver.png",
    "Traits/trait_tailor.png", "Traits/trait_target_shooter.png", "Traits/trait_tinkerer.png", "Traits/trait_whittler.png",
    "Traits/trait_wildernessknowledge.png", "controller/PS4_A.png", "controller/PS4_AnalogueL.png", "controller/PS4_AnalogueL_LR.png",
    "controller/PS4_AnalogueL_UD.png", "controller/PS4_AnalogueR.png", "controller/PS4_AnalogueR_LR.png", "controller/PS4_AnalogueR_UD.png",
    "controller/PS4_B.png", "controller/PS4_DPad.png", "controller/PS4_DPad_Down.png", "controller/PS4_DPad_Left.png",
    "controller/PS4_DPad_Right.png", "controller/PS4_DPad_Up.png", "controller/PS4_LB.png", "controller/PS4_LeftTrigger.png",
    "controller/PS4_Menu.png", "controller/PS4_RB.png", "controller/PS4_RightTrigger.png", "controller/PS4_View.png",
    "controller/PS4_X.png", "controller/PS4_Y.png", "controller/STEAMDECK_A.png", "controller/STEAMDECK_AnalogueL.png",
    "controller/STEAMDECK_AnalogueL_LR.png", "controller/STEAMDECK_AnalogueL_UD.png", "controller/STEAMDECK_AnalogueR.png", "controller/STEAMDECK_AnalogueR_LR.png",
    "controller/STEAMDECK_AnalogueR_UD.png", "controller/STEAMDECK_B.png", "controller/STEAMDECK_DPad.png", "controller/STEAMDECK_DPad_Down.png",
    "controller/STEAMDECK_DPad_Left.png", "controller/STEAMDECK_DPad_Right.png", "controller/STEAMDECK_DPad_Up.png", "controller/STEAMDECK_LB.png",
    "controller/STEAMDECK_LeftTrigger.png", "controller/STEAMDECK_Menu.png", "controller/STEAMDECK_RB.png", "controller/STEAMDECK_RightTrigger.png",
    "controller/STEAMDECK_View.png", "controller/STEAMDECK_X.png", "controller/STEAMDECK_Y.png", "controller/XBOX_A.png",
    "controller/XBOX_AnalogueL.png", "controller/XBOX_AnalogueL_LR.png", "controller/XBOX_AnalogueL_UD.png", "controller/XBOX_AnalogueR.png",
    "controller/XBOX_AnalogueR_LR.png", "controller/XBOX_AnalogueR_UD.png", "controller/XBOX_B.png", "controller/XBOX_DPad.png",
    "controller/XBOX_DPad_Down.png", "controller/XBOX_DPad_Left.png", "controller/XBOX_DPad_Right.png", "controller/XBOX_DPad_Up.png",
    "controller/XBOX_LB.png", "controller/XBOX_LeftTrigger.png", "controller/XBOX_Menu.png", "controller/XBOX_RB.png",
    "controller/XBOX_RightTrigger.png", "controller/XBOX_View.png", "controller/XBOX_X.png", "controller/XBOX_Y.png",
    "craftingMenus/BuildProperty_Book.png", "craftingMenus/BuildProperty_Book_16.png", "craftingMenus/BuildProperty_Clock.png", "craftingMenus/BuildProperty_Clock_16.png",
    "craftingMenus/BuildProperty_Consume.png", "craftingMenus/BuildProperty_Consume_16.png", "craftingMenus/BuildProperty_Drain.png", "craftingMenus/BuildProperty_Drain_16.png",
    "craftingMenus/BuildProperty_Light.png", "craftingMenus/BuildProperty_Light_16.png", "craftingMenus/BuildProperty_Surface.png", "craftingMenus/BuildProperty_Surface_16.png",
    "craftingMenus/BuildProperty_Walking.png", "craftingMenus/BuildProperty_Walking_16.png", "craftingMenus/Icon_Grid.png", "craftingMenus/Icon_Learning_48x48.png",
    "craftingMenus/Icon_Learning_64x64.png", "craftingMenus/Icon_List.png", "craftingMenus/Icon_Moon_48x48.png", "craftingMenus/Icon_Moon_64x64.png",
    "craftingMenus/Icon_Surface_48x48.png", "craftingMenus/Icon_Surface_64x64.png", "craftingMenus/Icon_Walking_48x48.png", "craftingMenus/Icon_Walking_64x64.png",
    "debug/DebuggerResume.png", "debug/DebuggerStepInto.png", "debug/DebuggerStepOver.png", "emotes/autowalk_off.png",
    "emotes/autowalk_on.png", "emotes/back.png", "emotes/back_green.png", "emotes/back_red.png",
    "emotes/ceasefire.png", "emotes/clap.png", "emotes/comefromfront.png", "emotes/comehere.png",
    "emotes/crouch_off.png", "emotes/crouch_on.png", "emotes/fire.png", "emotes/followbehind.png",
    "emotes/followme.png", "emotes/freeze.png", "emotes/gears.png", "emotes/gears_green.png",
    "emotes/gears_red.png", "emotes/group.png", "emotes/group_green.png", "emotes/group_red.png",
    "emotes/insult.png", "emotes/moveout.png", "emotes/no.png", "emotes/salute.png",
    "emotes/shrug.png", "emotes/sit_off.png", "emotes/sit_on.png", "emotes/stop.png",
    "emotes/surrender.png", "emotes/thankyou.png", "emotes/thumbdown.png", "emotes/thumbdown_green.png",
    "emotes/thumbdown_red.png", "emotes/thumbsdown.png", "emotes/thumbsup.png", "emotes/thumbup.png",
    "emotes/thumbup_green.png", "emotes/thumbup_red.png", "emotes/undecided.png", "emotes/wave.png",
    "emotes/wave_green.png", "emotes/wave_red.png", "emotes/wavebye.png", "emotes/wavebye_green.png",
    "emotes/wavebye_red.png", "emotes/wavehello.png", "emotes/yes.png", "foraging/eyeconOff.png",
    "foraging/eyeconOn.png", "foraging/moon0.png", "foraging/moon1.png", "foraging/moon2.png",
    "foraging/moon3.png", "foraging/moon4.png", "foraging/moon5.png", "foraging/moon6.png",
    "foraging/moon7.png", "foraging/questionMark.png", "foraging/sun.png", "inventoryPanes/Button_Close.png",
    "inventoryPanes/Button_Collapse.png", "inventoryPanes/Button_Gear.png", "inventoryPanes/Button_GuideN.png", "inventoryPanes/Button_GuideP.png",
    "inventoryPanes/Button_Info.png", "inventoryPanes/Button_Lock.png", "inventoryPanes/Button_LockOpen.png", "inventoryPanes/Button_Pin.png",
    "inventoryPanes/Button_Settings.png", "inventoryPanes/Button_TreeCollapseAll.png", "inventoryPanes/Button_TreeCollapsed.png", "inventoryPanes/Button_TreeExpandAll.png",
    "inventoryPanes/Button_TreeExpanded.png", "inventoryPanes/Button_TreeFilter.png", "inventoryPanes/FavouriteNo.png", "inventoryPanes/FavouriteYes.png",
    "inventoryPanes/TakeSameTypeOneContainer.png", "inventoryPanes/Tickbox_Cross.png", "inventoryPanes/Tickbox_Tick.png", "inventoryPanes/TransferSameTypeMultiContainer.png",
    "inventoryPanes/TransferSameTypeOneContainer.png", "inventoryPanes/craft.png", "inventoryPanes/craftok.png", "inventoryPanes/nocraft.png",
    "speedControls/FFwd1_Off.png", "speedControls/FFwd1_On.png", "speedControls/FFwd2_Off.png", "speedControls/FFwd2_On.png",
    "speedControls/Pause_Off.png", "speedControls/Pause_On.png", "speedControls/Play_Off.png", "speedControls/Play_On.png",
    "speedControls/StepForward_Off.png", "speedControls/Wait_Off.png", "speedControls/Wait_On.png", "survival_guide_spiffo/category_cleaning.png",
    "survival_guide_spiffo/category_combat.png", "survival_guide_spiffo/category_crafting.png", "survival_guide_spiffo/category_farming.png", "survival_guide_spiffo/category_fishing.png",
    "survival_guide_spiffo/category_food_and_water.png", "survival_guide_spiffo/category_foraging_mining.png", "survival_guide_spiffo/category_interactable.png", "survival_guide_spiffo/category_movement.png",
    "survival_guide_spiffo/category_multiplayer.png", "survival_guide_spiffo/category_ranching.png", "survival_guide_spiffo/category_vehicles.png", "survival_guide_spiffo/category_weather.png",
    "survival_guide_spiffo/green_status.png", "survival_guide_spiffo/mood_dead.png", "survival_guide_spiffo/mood_fatigue.png", "survival_guide_spiffo/mood_first_aid.png",
    "survival_guide_spiffo/mood_nauseous.png", "survival_guide_spiffo/mood_sleep.png", "survival_guide_spiffo/red_status.png", "vehicles/gas_refuel.png",
    "vehicles/gas_siphon.png", "vehicles/vehicle_add_gas.png", "vehicles/vehicle_refuel_from_pump.png", "vehicles/vehicle_siphon_gas.png",
    "vehicles/vehicle_smash_window.png",
}

-- Resolving ------------------------------------------------------------------------

local cache = {}

function Icons.texture(ref)
    if type(ref) ~= "string" or ref == "" then return nil end
    local cached = cache[ref]
    if cached ~= nil then return cached or nil end

    local texture = nil
    local kind, id = string.match(ref, "^(%a+):(.+)$")
    if kind == "sym" then
        local defs = MapSymbolDefinitions and MapSymbolDefinitions.getInstance()
        local def = defs and defs:getSymbolById(id)
        if def then texture = tryGetTexture(def:getTexturePath()) end
    elseif kind == "item" then
        local item = getScriptManager():getItem(id)
        if item then
            local icon = item:getIcon()
            local icons = item:getIconsForTexture()
            if icons and not icons:isEmpty() then icon = icons:get(0) end
            if icon and icon ~= "" then texture = tryGetTexture("Item_" .. icon) end
        end
    elseif kind == "tex" then
        texture = tryGetTexture(id)
    end

    cache[ref] = texture or false
    return texture
end

function Icons.textureRef(texture)
    local name = texture and texture:getName()
    return name and ("tex:" .. name) or nil
end

-- Sources ----------------------------------------------------------------------------
--
-- Each builds a list of { ref, name } once, when its tab is first opened.

local sources = {}

local function symbolEntries()
    local list = {}
    local defs = MapSymbolDefinitions and MapSymbolDefinitions.getInstance()
    if not defs then return list end
    for i = 0, defs:getSymbolCount() - 1 do
        local def = defs:getSymbolByIndex(i)
        if def then
            table.insert(list, { ref = "sym:" .. def:getId(), name = def:getId() })
        end
    end
    return list
end

local function itemEntries()
    local list = {}
    local items = getScriptManager():getAllItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local icon = item and item:getIcon()
        if icon and icon ~= "" then
            table.insert(list, { ref = "item:" .. item:getFullName(), name = item:getDisplayName() or item:getFullName() })
        end
    end
    table.sort(list, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return list
end

local function definitionEntries(definitions, nameOf)
    local list = {}
    if not definitions then return list end
    for i = 0, definitions:size() - 1 do
        local def = definitions:get(i)
        local texture = def and def:getTexture()
        local ref = Icons.textureRef(texture)
        if ref then
            cache[ref] = texture
            table.insert(list, { ref = ref, name = nameOf(def) or ref })
        end
    end
    table.sort(list, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return list
end

local function traitEntries()
    local ok, traits = pcall(function() return CharacterTraitDefinition.getTraits() end)
    return definitionEntries(ok and traits or nil, function(def) return def:getLabel() end)
end

local function professionEntries()
    local ok, professions = pcall(function() return CharacterProfessionDefinition.getProfessions() end)
    return definitionEntries(ok and professions or nil, function(def) return def:getUIName() end)
end

local function uiEntries()
    local list = {}
    for _, path in ipairs(UI_IMAGES) do
        local name = string.match(path, "([^/]+)%.png$") or path
        table.insert(list, { ref = "tex:media/ui/" .. path, name = name .. "  (" .. path .. ")" })
    end
    return list
end

--- The tiles of one tile set that exist. Tile sets hold up to 256, eight a row.
local function tileEntries(tileset)
    local list = {}
    for n = 0, 255 do
        local name = tileset .. "_" .. n
        local texture = tryGetTexture(name)
        if texture then
            local ref = "tex:" .. name
            cache[ref] = texture
            table.insert(list, { ref = ref, name = name })
        end
    end
    return list
end

local TABS = {
    { id = "symbols", title = "IconTabSymbols", build = symbolEntries },
    { id = "items", title = "IconTabItems", build = itemEntries },
    { id = "traits", title = "IconTabTraits", build = traitEntries },
    { id = "professions", title = "IconTabProfessions", build = professionEntries },
    { id = "ui", title = "IconTabGameUI", build = uiEntries },
    { id = "tiles", title = "IconTabTiles" },
}

local function entriesOf(tab)
    if not sources[tab.id] and tab.build then
        sources[tab.id] = tab.build()
    end
    return sources[tab.id] or {}
end

-- Picker window --------------------------------------------------------------------------

local Picker = ISPanel:derive("ZomboidFixesB42_AdminHotbarIconPicker")

function Picker:new(ref, tint, onPick)
    local core = getCore()
    local width = math.min(760, core:getScreenWidth() - 40)
    local height = math.min(620, core:getScreenHeight() - 40)
    local o = ISPanel:new(core:getScreenWidth() / 2 - width / 2, core:getScreenHeight() / 2 - height / 2, width, height)
    setmetatable(o, self)
    self.__index = self
    o.selected = ref
    o.tint = tint
    o.onPick = onPick
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.92 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.moveWithMouse = true
    o.tab = TABS[1]
    o.entries = {}
    o.columns = 1
    o.hovered = nil
    return o
end

function Picker:addButton(x, y, width, title, onClick)
    local button = ISButton:new(x, y, width, BUTTON_HGT, title, self, onClick)
    button:initialise()
    button:instantiate()
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
    self:addChild(button)
    return button
end

function Picker:createChildren()
    ISPanel.createChildren(self)
    local x = UI_BORDER_SPACING + 1
    local y = UI_BORDER_SPACING * 2 + FONT_HGT_MEDIUM

    self.tabButtons = {}
    local tabWidth = math.floor((self.width - x * 2 - UI_BORDER_SPACING * (#TABS - 1)) / #TABS)
    for i, tab in ipairs(TABS) do
        local button = self:addButton(x + (i - 1) * (tabWidth + UI_BORDER_SPACING), y, tabWidth, txt(tab.title), Picker.onTab)
        button.tab = tab
        table.insert(self.tabButtons, button)
    end
    y = y + BUTTON_HGT + UI_BORDER_SPACING

    self.search = ISTextEntryBox:new("", x, y, self.width - x * 2, BUTTON_HGT)
    self.search:initialise()
    self.search:instantiate()
    self.search:setClearButton(true)
    self.search.target = self
    self.search.onTextChangeFunction = Picker.filter
    self:addChild(self.search)
    self.search:setPlaceholderText(txt("Search"))
    y = y + BUTTON_HGT + UI_BORDER_SPACING

    local bottom = BUTTON_HGT * 2 + CELL + UI_BORDER_SPACING * 4
    local gridHeight = self.height - y - bottom
    self.gridTop = y

    -- Tile sets, shown on the Tiles tab only.
    self.tilesets = ISScrollingListBox:new(x, y, 220, gridHeight)
    self.tilesets:initialise()
    self.tilesets:instantiate()
    self.tilesets.font = UIFont.Small
    self.tilesets.itemheight = BUTTON_HGT
    self.tilesets.drawBorder = true
    self.tilesets:setOnMouseDownFunction(self, Picker.onTileset)
    self:addChild(self.tilesets)
    self.tilesets:setVisible(false)

    self.grid = ISScrollingListBox:new(x, y, self.width - x * 2, gridHeight)
    self.grid:initialise()
    self.grid:instantiate()
    self.grid.font = UIFont.Small
    self.grid.itemheight = CELL
    self.grid.drawBorder = true
    self.grid.picker = self
    self.grid.doDrawItem = Picker.drawGridRow
    self.grid.onMouseDown = Picker.onGridMouseDown
    self.grid.onMouseDoubleClick = Picker.onGridDoubleClick
    self.grid.onMouseMove = Picker.onGridMouseMove
    self:addChild(self.grid)

    local by = self.height - BUTTON_HGT - UI_BORDER_SPACING
    self.previewY = by - UI_BORDER_SPACING - CELL
    local bx = x + CELL + UI_BORDER_SPACING
    self.tintButton = self:addButton(bx, self.previewY + (CELL - BUTTON_HGT) / 2, 110, txt("IconTint"), Picker.onTint)
    self:addButton(self.tintButton:getRight() + UI_BORDER_SPACING, self.tintButton:getY(), 110, txt("IconNoTint"), function(picker)
        picker.tint = nil
    end)

    local buttonWidth = 110
    local ok = self:addButton(self.width / 2 - buttonWidth * 1.5 - UI_BORDER_SPACING, by, buttonWidth, getText("UI_Ok"), Picker.onOk)
    ok:enableAcceptColor()
    self:addButton(ok:getRight() + UI_BORDER_SPACING, by, buttonWidth, txt("IconDefault"), Picker.onDefault)
    local cancel = self:addButton(ok:getRight() + buttonWidth + UI_BORDER_SPACING * 2, by, buttonWidth, getText("UI_Cancel"), Picker.close)
    cancel:enableCancelColor()

    self:showTab(self.tab)
end

function Picker:onTab(button)
    self:showTab(button.tab)
end

function Picker:showTab(tab)
    self.tab = tab
    for _, button in ipairs(self.tabButtons) do
        if button.tab == tab then
            button:enableAcceptColor()
        else
            button:setBackgroundRGBA(0, 0, 0, 1)
            button:setBorderRGBA(1, 1, 1, 0.3)
        end
    end

    local x = UI_BORDER_SPACING + 1
    if tab.id == "tiles" then
        self.tilesets:setVisible(true)
        self.grid:setX(self.tilesets:getRight() + UI_BORDER_SPACING)
        self.grid:setWidth(self.width - self.grid:getX() - x)
        if #self.tilesets.items == 0 then
            local names = getWorld():getAllTilesName()
            local sorted = {}
            for i = 0, names:size() - 1 do table.insert(sorted, names:get(i)) end
            table.sort(sorted)
            for _, name in ipairs(sorted) do self.tilesets:addItem(name, name) end
        end
        self.source = self.tileset and tileEntries(self.tileset) or {}
    else
        self.tilesets:setVisible(false)
        self.grid:setX(x)
        self.grid:setWidth(self.width - x * 2)
        self.source = entriesOf(tab)
    end
    self:filter()
end

function Picker:onTileset(name)
    self.tileset = name
    self.source = tileEntries(name)
    self:filter()
end

function Picker:filter()
    local text = string.lower(self.search:getInternalText() or "")
    local entries = {}
    for _, entry in ipairs(self.source or {}) do
        if text == "" or string.find(string.lower(entry.name), text, 1, true) then
            table.insert(entries, entry)
        end
    end
    self.entries = entries

    -- The scroll bar takes a strip on the right.
    self.columns = math.max(1, math.floor((self.grid:getWidth() - 16) / CELL))
    self.grid:clear()
    local rows = math.ceil(#entries / self.columns)
    for row = 1, rows do
        self.grid:addItem("", row)
    end
    self.grid:setYScroll(0)
end

function Picker:entryAt(x, y)
    local grid = self.grid
    local row = grid:rowAt(x, y)
    if row < 1 then return nil end
    local column = math.floor(x / CELL) + 1
    if column > self.columns then return nil end
    return self.entries[(row - 1) * self.columns + column]
end

function Picker:drawGridRow(y, item, alt)
    local picker = self.picker
    local height = self.itemheight
    local top = -self:getYScroll()
    if y + height < top or y > top + self.height then
        return y + height
    end
    local row = item.item
    for column = 1, picker.columns do
        local entry = picker.entries[(row - 1) * picker.columns + column]
        if not entry then break end
        local cx = (column - 1) * CELL
        if entry.ref == picker.selected then
            self:drawRect(cx + 1, y + 1, CELL - 2, CELL - 2, 0.45, 0.2, 0.7, 0.3)
        elseif entry == picker.hovered then
            self:drawRect(cx + 1, y + 1, CELL - 2, CELL - 2, 0.15, 1, 1, 1)
        end
        self:drawRectBorder(cx, y, CELL, CELL, 0.25, 0.5, 0.5, 0.5)
        local texture = Icons.texture(entry.ref)
        if texture then
            local tint = picker.tint or { r = 1, g = 1, b = 1 }
            self:drawTextureScaledAspect(texture, cx + 4, y + 4, CELL - 8, CELL - 8, 1, tint.r, tint.g, tint.b)
        end
    end
    return y + height
end

function Picker:onGridMouseDown(x, y)
    local picker = self.picker
    local entry = picker:entryAt(x, y)
    if entry then
        picker.selected = entry.ref
        getSoundManager():playUISound("UISelectListItem")
    end
end

function Picker:onGridDoubleClick(x, y)
    local picker = self.picker
    if picker:entryAt(x, y) then picker:onOk() end
end

function Picker:onGridMouseMove(dx, dy)
    ISScrollingListBox.onMouseMove(self, dx, dy)
    self.picker.hovered = self.picker:entryAt(self:getMouseX(), self:getMouseY())
end

function Picker:onTint()
    local tint = self.tint or { r = 1, g = 1, b = 1 }
    local colorPicker = ISColorPicker:new(getMouseX() - 100, getMouseY() - 20)
    colorPicker:initialise()
    colorPicker.pickedTarget = self
    colorPicker.resetFocusTo = self
    colorPicker:setInitialColor(ColorInfo.new(tint.r, tint.g, tint.b, 1))
    colorPicker:setPickedFunc(function(picker, color)
        picker.tint = { r = color.r, g = color.g, b = color.b }
    end)
    colorPicker:addToUIManager()
    colorPicker:bringToTop()
end

function Picker:prerender()
    ISPanel.prerender(self)
    self:drawText(txt("IconPickerTitle"), UI_BORDER_SPACING + 1, UI_BORDER_SPACING, 1, 1, 1, 1, UIFont.Medium)

    local x = UI_BORDER_SPACING + 1
    self:drawRectBorder(x, self.previewY, CELL, CELL, 0.6, 0.6, 0.6, 0.6)
    local texture = Icons.texture(self.selected)
    if texture then
        local tint = self.tint or { r = 1, g = 1, b = 1 }
        self:drawTextureScaledAspect(texture, x + 3, self.previewY + 3, CELL - 6, CELL - 6, 1, tint.r, tint.g, tint.b)
    end
    local status = self.hovered and self.hovered.name or ""
    if self.tab.id == "tiles" and not self.tileset then
        status = txt("IconPickTileset")
    end
    self:drawText(status, self.tintButton:getX(), self.previewY - FONT_HGT_SMALL - 2, 0.8, 0.8, 0.8, 1, UIFont.Small)
end

function Picker:onOk()
    self:close()
    self.onPick(self.selected, self.tint)
end

function Picker:onDefault()
    self:close()
    self.onPick(nil, nil)
end

function Picker:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

--- Open the picker. onPick(ref, tint); both nil means "use the action's default".
function Icons.openPicker(ref, tint, onPick)
    local picker = Picker:new(ref, tint, onPick)
    picker:initialise()
    picker:addToUIManager()
    picker:bringToTop()
    return picker
end
