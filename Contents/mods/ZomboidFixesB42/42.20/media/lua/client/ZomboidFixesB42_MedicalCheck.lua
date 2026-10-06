--[[
    Zomboid Fixes B42.20 -- client, a second medical check resets the patient's stats

    A health window on another player (ISMedicalCheckAction:perform, and this mod's
    admin Health button in ZomboidFixesB42_HealthCheck.lua) calls
    doctor:startReceivingBodyDamageUpdates(patient). In Java (IsoPlayer ~6665) that
    resets the client's copy of the patient's body (resetBodyDamageRemote) and sends
    BodyDamageUpdatePacket START_UPDATING; the window closing sends STOP_UPDATING.
    On the server (zombie.network.BodyDamageSync.startSendingUpdates) a start makes
    an Updater that streams the patient's body to the doctor every 0.5 s as the
    difference from bdSent, its record of what was sent:

        updaterx.bdSent = new BodyDamage(player);

    bdSent's parent character is the patient. The BodyDamage constructor calls
    RestoreToFullHealth before it sets parentChar, so the first start is harmless.
    But a start for a doctor and patient that already have an Updater does this:

        updater.bdSent.RestoreToFullHealth();

    and RestoreToFullHealth, with parentChar set now, runs this.stats.resetStats()
    on the patient's real Stats (bdSent shares them through the parent), plus
    parentChar.setCorpseSicknessRate(0). Every CharacterStat goes back to its
    default on the server: hunger, thirst, fatigue, endurance, pain, panic, stress,
    boredom, unhappiness, sickness, food sickness, drunkenness and the rest. The
    stat sync reaches the patient within a second, so their negative moodles
    vanish. That happens whenever a second start is sent while the first window's
    is still running: a second Medical Check while the window is still open
    (perform reuses the window and starts again without a stop), or the Health
    button pressed again. Anyone can do it to anyone who accepts a medical check.

    Nothing on the server can be changed from Lua, so the client never sends a
    second start while one is running: startReceivingBodyDamageUpdates and
    stopReceivingBodyDamageUpdates are wrapped on IsoPlayer's class metatable, which
    catches every caller (vanilla, this mod, other mods). A start for a patient whose
    updates are already coming is dropped, together with its resetBodyDamageRemote
    (the server only sends what changed, so wiping the client's copy without the
    server's reset would leave the window showing full health). The window's own
    stop and start (walking out of reach and back) still go through: the stop
    clears the patient, and the next start is a first start again.

    Reliability 2 (RELIABLE, not ordered) means a stop and the next start can still
    swap on the way and reset the stats once; they are as far apart as the doctor's
    walk out of reach and back, so that is left alone.
--]]

if not isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MedicalCheckNoReset == true
end

-- [patient online ID] = the patient object, while the server is sending that
-- patient's body to us. Kept as the object so a player who left and came back
-- (a new IsoPlayer, maybe with the same online ID) starts afresh.
local receiving = {}

--- The conditions under which Java really sends the packet (IsoPlayer ~6665).
local function sends(doctor, patient)
    return isClient() and patient ~= nil and patient ~= doctor
        and doctor:isLocalPlayer() and not patient:isLocalPlayer()
end

local classTable = __classmetatables and IsoPlayer and __classmetatables[IsoPlayer.class]
local index = classTable and classTable.__index
local vanillaStart = index and index.startReceivingBodyDamageUpdates
local vanillaStop = index and index.stopReceivingBodyDamageUpdates

if not vanillaStart or not vanillaStop then
    print("[ZomboidFixesB42] MedicalCheck: IsoPlayer's class metatable is not reachable, fix not applied")
    return
end

index.startReceivingBodyDamageUpdates = function(doctor, patient, ...)
    if isEnabled() and sends(doctor, patient) then
        local id = patient:getOnlineID()
        if receiving[id] == patient then return end
        receiving[id] = patient
    end
    return vanillaStart(doctor, patient, ...)
end

index.stopReceivingBodyDamageUpdates = function(doctor, patient, ...)
    if patient ~= nil then
        receiving[patient:getOnlineID()] = nil
    end
    return vanillaStop(doctor, patient, ...)
end
