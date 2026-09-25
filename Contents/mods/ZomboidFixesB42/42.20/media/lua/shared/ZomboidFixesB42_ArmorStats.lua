--[[
    Zomboid Fixes B42.20 -- shared, blacksmithing armor stats

    Vanilla has the run speed of the metal shin armor and the articulated metal
    shin armor the wrong way round. Articulated armor is the Blacksmith 8 upgrade
    and is jointed so it moves better, yet it was the slower of the two:

                                   vanilla   fixed
      Metal Shin Armor              0.90     0.85
      Articulated Metal Shin Armor  0.85     0.90

    Only the two values are exchanged; nothing else is changed. Only the item
    scripts are edited, so both sides must run this. Items that already exist in
    a save may keep the value they were created with.

    The sandbox options are not loaded yet when this file runs. SandboxOptions.load
    comes before GlobalModData.init in IsoWorld.init (a client has them from the
    server before that), so the scripts are first edited from OnInitGlobalModData.
    There is no event for the options changing mid-game, so the setting is checked
    again every ten game minutes and the scripts are put back to vanilla if it has
    been switched off.
--]]

local FIXED = {
    ["Base.Greave_Left"] = 0.85,
    ["Base.Greave_Right"] = 0.85,
    ["Base.ShinKneeGuard_L_Metal"] = 0.9,
    ["Base.ShinKneeGuard_R_Metal"] = 0.9,
}

local VANILLA = {
    ["Base.Greave_Left"] = 0.9,
    ["Base.Greave_Right"] = 0.9,
    ["Base.ShinKneeGuard_L_Metal"] = 0.85,
    ["Base.ShinKneeGuard_R_Metal"] = 0.85,
}

-- Whether the scripts currently hold the fixed values.
local applied = false

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.FixShinArmorRunSpeed == true
end

local function write(values)
    local scripts = ScriptManager.instance
    for fullType, value in pairs(values) do
        local item = scripts:getItem(fullType)
        if item then
            item:DoParam("RunSpeedModifier = " .. tostring(value))
        else
            print("ZomboidFixesB42: armor stats, item not found: " .. fullType)
        end
    end
end

local function update()
    local enabled = isEnabled()
    if enabled == applied then return end
    write(enabled and FIXED or VANILLA)
    applied = enabled
end

Events.OnInitGlobalModData.Add(update)
Events.EveryTenMinutes.Add(update)
