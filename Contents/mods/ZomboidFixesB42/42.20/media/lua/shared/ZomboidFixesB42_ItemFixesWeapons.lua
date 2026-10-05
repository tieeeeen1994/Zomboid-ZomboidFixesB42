--[[
    Zomboid Fixes B42.20 -- shared, weapon data fixes

    Plain mistakes in items/weapon.txt, items/weaponpart.txt and fixing.txt (42.21),
    behind the ItemDataFixes sandbox option, or RecipeFixes for those that change
    a recipe or a repair; the name each fix is registered under shows in the log.
    The machinery is in ZomboidFixesB42_ScriptFixes.lua.

    SawnOffDoubleBarrelRepair: fixing.txt has a repair for every gun, and the pump
    shotgun and its sawn-off version repair each other ("Fix Shotgun" / "Fix
    ShotgunSawnoff"), but "Fix DoubleBarrelShotgun" only requires and uses
    Base.DoubleBarrelShotgun, so the sawn-off double barrel can never be repaired.
    The fix adds the sawn-off to that repair, both as an item it repairs and as a
    part (Aiming 2, like the others).

    SawnOffShotgunSounds: the sawn-off pump shotgun has only InsertAmmoSound, no
    insert start/stop and no eject sounds, although SawnOffJS2000ShotgunInsertAmmoStart
    / Stop and EjectAmmoStart / Stop exist (there is no sawn-off EjectAmmo, so the
    full shotgun's is used). The sounds are read from the script each time.
    Its missing `AimingMod` / `IsAimedHandWeapon` are left alone: in 42.21
    HandWeapon.getAimingMod() always returns 1.0 and the only reader of
    isAimedHandWeapon (IsoPlayer.IsUsingAimHandWeapon) is never called.

    ShotgunScopeMount: the pump shotgun and the sawn-off both have
    `ModelWeaponPart = x2Scope x2Scope scope scope` and their models have the scope
    attachment points, but x2Scope's MountOn lists neither, so the scope cannot be
    put on them. (The JS-3T also names recoil pad and choke tube models, but its
    model has no recoilpad / choketube attachment points, so a mounted part would be
    drawn at the gun's origin; left alone.) A weapon part copies MountOn when it is
    created, so scopes already loaded follow the change once they are next loaded.

    KatanaSharpening: 12 of the 14 long blades have `base:sharpenable`; the katana
    and the broken katana do not, although they have Sharpness and dull like the
    rest, so they can never be sharpened (InventoryItem.isSharpenable and the three
    SharpenBlade recipes' tags[base:sharpenable] input).
--]]

require "ZomboidFixesB42_ScriptFixes"

local ScriptFixes = ZomboidFixesB42.ScriptFixes

local SAWN_OFF_DB = "Base.DoubleBarrelShotgunSawnoff"
local repairState = {}

ScriptFixes.register("RecipeFixes", "SawnOffDoubleBarrelRepair",
    function()
        local fixing = ScriptFixes.getFixing("Fix DoubleBarrelShotgun")
        if not fixing or not ScriptFixes.getItem(SAWN_OFF_DB) then return end
        local required = fixing:getRequiredItem()
        if not required:contains(SAWN_OFF_DB) then
            required:add(SAWN_OFF_DB)
            repairState.required = true
        end
        local fixer = ScriptFixes.newFixer(SAWN_OFF_DB .. "; Aiming=2")
        fixing:getFixers():add(fixer)
        repairState.fixer = fixer
    end,
    function()
        local fixing = ScriptFixes.getFixing("Fix DoubleBarrelShotgun")
        if not fixing then return end
        if repairState.required then fixing:getRequiredItem():remove(SAWN_OFF_DB) end
        if repairState.fixer then fixing:getFixers():remove(repairState.fixer) end
        repairState = {}
    end)

ScriptFixes.register("ItemDataFixes", "SawnOffShotgunSounds",
    function()
        ScriptFixes.setParams({ ["Base.ShotgunSawnoff"] = {
            InsertAmmoStartSound = "SawnOffJS2000ShotgunInsertAmmoStart",
            InsertAmmoStopSound = "SawnOffJS2000ShotgunInsertAmmoStop",
            EjectAmmoStartSound = "SawnOffJS2000ShotgunEjectAmmoStart",
            EjectAmmoSound = "JS2000ShotgunEjectAmmo",
            EjectAmmoStopSound = "SawnOffJS2000ShotgunEjectAmmoStop",
        } })
    end,
    function()
        ScriptFixes.setParams({ ["Base.ShotgunSawnoff"] = {
            InsertAmmoStartSound = "",
            InsertAmmoStopSound = "",
            EjectAmmoStartSound = "",
            EjectAmmoSound = "",
            EjectAmmoStopSound = "",
        } })
    end)

local X2_SCOPE_MOUNT_ON = "Base.HuntingRifle;Base.VarmintRifle;Base.AssaultRifle;Base.AssaultRifle2;"
    .. "Base.JS14_Rifle;Base.Revolver_Long;Base.TrapperCarbine;Base.MSR7T_Rifle"

ScriptFixes.register("ItemDataFixes", "ShotgunScopeMount",
    function()
        ScriptFixes.setParams({ ["Base.x2Scope"] = {
            MountOn = X2_SCOPE_MOUNT_ON .. ";Base.Shotgun;Base.ShotgunSawnoff",
        } })
    end,
    function()
        ScriptFixes.setParams({ ["Base.x2Scope"] = { MountOn = X2_SCOPE_MOUNT_ON } })
    end)

local KATANAS = { "Base.Katana", "Base.Katana_Broken" }

ScriptFixes.register("RecipeFixes", "KatanaSharpening",
    function()
        for _, fullType in ipairs(KATANAS) do
            ScriptFixes.addTag(fullType, "base:sharpenable")
        end
    end,
    function()
        for _, fullType in ipairs(KATANAS) do
            ScriptFixes.removeTag(fullType, "base:sharpenable")
        end
    end)
