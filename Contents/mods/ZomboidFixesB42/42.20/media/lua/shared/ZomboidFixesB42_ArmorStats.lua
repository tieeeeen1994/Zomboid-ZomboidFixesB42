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
--]]

local RUN_SPEED = {
    ["Base.Greave_Left"] = 0.85,
    ["Base.Greave_Right"] = 0.85,
    ["Base.ShinKneeGuard_L_Metal"] = 0.9,
    ["Base.ShinKneeGuard_R_Metal"] = 0.9,
}

local function apply()
    local scripts = ScriptManager.instance
    for fullType, value in pairs(RUN_SPEED) do
        local item = scripts:getItem(fullType)
        if item then
            item:DoParam("RunSpeedModifier = " .. tostring(value))
        else
            print("ZomboidFixesB42: armor stats, item not found: " .. fullType)
        end
    end
end

apply()
