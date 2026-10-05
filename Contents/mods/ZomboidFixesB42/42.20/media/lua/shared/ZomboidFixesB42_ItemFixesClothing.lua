--[[
    Zomboid Fixes B42.20 -- shared, clothing and armor data fixes

    Plain mistakes in items/clothing.txt (42.21), behind the ItemDataFixes sandbox
    option, or RecipeFixes for those that change what a recipe takes; the name each
    fix is registered under shows in the log. The machinery is in
    ZomboidFixesB42_ScriptFixes.lua. Items that are
    already loaded keep a copied value (combat speed, condition chance) until they
    are next loaded; see that file.

    ShinArmorSpeed: the metal leg armor run speeds follow one pattern on the thigh
    (metal and scrap 0.9, spiked -0.05, articulated +0.05: 0.9 / 0.85 / 0.95), and
    the shoulders likewise make articulated the faster piece, but the shin pieces
    break it: spiked metal and spiked scrap shin armor cost nothing (0.9), the
    articulated shin armor is slower than the plain one (0.85) and its spiked
    version 0.8. The shin pieces that break the pattern get the thigh's values:

                                          vanilla   fixed
      Metal / Scrap Metal Shin Armor        0.90    0.90 (unchanged)
      Spiked (Scrap) Metal Shin Armor       0.90    0.85
      Articulated Metal Shin Armor          0.85    0.95
      Spiked Articulated Metal Shin Armor   0.80    0.90

    SpikedThighArmorSide: the right spiked metal and spiked scrap metal thigh
    armor have `ClothingItemExtra = Base.ThighMetalSpike_R` / `ThighScrapMetalSpike_R`,
    i.e. themselves, so their "Left Thigh" option (ClothingItemExtraOption) puts the
    same right-thigh piece back on. The left pieces point at the right ones as they
    should. Every other thigh armor pair points at the other side.

    SpikedShoulderPadSmelting: the spiked articulated metal shoulder pads lost the
    `base:smeltablesteelmedium` tag the plain articulated ones have, so they cannot
    be smelted (ExtractSteelFromMediumItem takes tags[base:smeltablesteelmedium]).

    KneepadGaiterPairs: every knee pad pair spawns together through SpawnWith
    (ItemPickerJava spawns the SpawnWith item next to a picked one), except the
    plain Kneepad_Left, which has none, and Gaiter_Right likewise, so those two
    turn up alone.

    BowTieWeight: Tie_BowTieFull has no Weight line, so it weighs the default 1.0;
    the worn bow tie weighs 0.1.

    ChainmailSleeveSpeed: every left/right armor pair slows the right (weapon) arm
    more (shoulder pads 0.95 / 0.92, chainmail gloves 0.99 / 0.98), but the full
    chainmail sleeves have the right at 0.97 and the left at 0.95.

    TireShoulderPads: the left tire shoulder pad has ConditionLowerChanceOneIn 5,
    the right one and every other tire armor piece 2; and both cover UpperBody
    (the torso) instead of their own upper arm like every other single shoulder pad
    (bone, wood, metal, articulated). BloodLocation is what decides the body parts a
    piece protects, gets bloody and gets holes on.
--]]

require "ZomboidFixesB42_ScriptFixes"

local ScriptFixes = ZomboidFixesB42.ScriptFixes

local SHIN_SPEEDS = {
    -- full type = { fixed, vanilla }
    ["Base.GreaveSpike_Left"] = { "0.85", "0.9" },
    ["Base.GreaveSpike_Right"] = { "0.85", "0.9" },
    ["Base.GreaveSpikeScrap_Left"] = { "0.85", "0.9" },
    ["Base.GreaveSpikeScrap_Right"] = { "0.85", "0.9" },
    ["Base.ShinKneeGuard_L_Metal"] = { "0.95", "0.85" },
    ["Base.ShinKneeGuard_R_Metal"] = { "0.95", "0.85" },
    ["Base.ShinKneeGuardSpike_L_Metal"] = { "0.9", "0.8" },
    ["Base.ShinKneeGuardSpike_R_Metal"] = { "0.9", "0.8" },
}

local function setShinSpeeds(index)
    local params = {}
    for fullType, values in pairs(SHIN_SPEEDS) do
        params[fullType] = { RunSpeedModifier = values[index] }
    end
    ScriptFixes.setParams(params)
end

ScriptFixes.register("ItemDataFixes", "ShinArmorSpeed",
    function() setShinSpeeds(1) end,
    function() setShinSpeeds(2) end)

ScriptFixes.register("ItemDataFixes", "SpikedThighArmorSide",
    function()
        ScriptFixes.setParams({
            ["Base.ThighMetalSpike_R"] = { ClothingItemExtra = "Base.ThighMetalSpike_L" },
            ["Base.ThighScrapMetalSpike_R"] = { ClothingItemExtra = "Base.ThighScrapMetalSpike_L" },
        })
    end,
    function()
        ScriptFixes.setParams({
            ["Base.ThighMetalSpike_R"] = { ClothingItemExtra = "Base.ThighMetalSpike_R" },
            ["Base.ThighScrapMetalSpike_R"] = { ClothingItemExtra = "Base.ThighScrapMetalSpike_R" },
        })
    end)

local SPIKED_PADS = { "Base.Shoulderpad_ArticulatedSpike_L", "Base.Shoulderpad_ArticulatedSpike_R" }

ScriptFixes.register("RecipeFixes", "SpikedShoulderPadSmelting",
    function()
        for _, fullType in ipairs(SPIKED_PADS) do
            ScriptFixes.addTag(fullType, "base:smeltablesteelmedium")
        end
    end,
    function()
        for _, fullType in ipairs(SPIKED_PADS) do
            ScriptFixes.removeTag(fullType, "base:smeltablesteelmedium")
        end
    end)

ScriptFixes.register("ItemDataFixes", "KneepadGaiterPairs",
    function()
        ScriptFixes.setParams({
            ["Base.Kneepad_Left"] = { SpawnWith = "Base.Kneepad_Right" },
            ["Base.Gaiter_Right"] = { SpawnWith = "Base.Gaiter_Left" },
        })
    end,
    function()
        ScriptFixes.setParams({
            ["Base.Kneepad_Left"] = { SpawnWith = "" },
            ["Base.Gaiter_Right"] = { SpawnWith = "" },
        })
    end)

ScriptFixes.register("ItemDataFixes", "BowTieWeight",
    function()
        ScriptFixes.setParams({ ["Base.Tie_BowTieFull"] = { Weight = "0.1" } })
    end,
    function()
        ScriptFixes.setParams({ ["Base.Tie_BowTieFull"] = { Weight = "1.0" } })
    end)

ScriptFixes.register("ItemDataFixes", "ChainmailSleeveSpeed",
    function()
        ScriptFixes.setParams({
            ["Base.Chainmail_SleeveFull_R"] = { CombatSpeedModifier = "0.95" },
            ["Base.Chainmail_SleeveFull_L"] = { CombatSpeedModifier = "0.97" },
        })
    end,
    function()
        ScriptFixes.setParams({
            ["Base.Chainmail_SleeveFull_R"] = { CombatSpeedModifier = "0.97" },
            ["Base.Chainmail_SleeveFull_L"] = { CombatSpeedModifier = "0.95" },
        })
    end)

ScriptFixes.register("ItemDataFixes", "TireShoulderPads",
    function()
        ScriptFixes.setParams({
            ["Base.Shoulderpad_Tire_L"] = { ConditionLowerChanceOneIn = "2", BloodLocation = "UpperArm_L" },
            ["Base.Shoulderpad_Tire_R"] = { BloodLocation = "UpperArm_R" },
        })
    end,
    function()
        ScriptFixes.setParams({
            ["Base.Shoulderpad_Tire_L"] = { ConditionLowerChanceOneIn = "5", BloodLocation = "UpperBody" },
            ["Base.Shoulderpad_Tire_R"] = { BloodLocation = "UpperBody" },
        })
    end)
