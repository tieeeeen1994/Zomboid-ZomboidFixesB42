--[[
    Zomboid Fixes B42.20 -- server, reloads keep pace with the reload animation

    In single player a reload is driven by its animation: each loop of the shell
    loading clip fires "loadFinished", which puts one round in, and a magazine swap
    or rack ends on the clip's last frame. In multiplayer the server has no
    animation, so each action's serverStart (shared/TimedActions, 42.21) fakes the
    events on a timer instead:

        emulateAnimEvent(self.netAction, ISReloadWeaponAction.getReloadTime(self.character, BASE_MS), "loadFinished", nil)

    getReloadTime is BASE_MS / ReloadSpeed, the same ReloadSpeed the client's
    animation node plays at (m_SpeedScale ReloadSpeed in every Load*/Rack*/Unload*
    node; the server works it out with the same setReloadSpeed in initVars). But the
    BASE_MS values are hand-written and do not match the clips the client plays
    (lengths from media/anims_X/Bob/*.X, event times from AnimSets/player/actions):

        action               vanilla timer   clip the client plays
        load a shell         833             Bob_Reload_Shotgun_Load      700
        load a revolver      950             Bob_Reload_Revolver_Load     767
        load a lever action  1000 (default)  Bob_Reload_Lever_Load        700
        load bolt, no mag    590             Bob_Reload_Shotgun_Load      700
        load double barrel   2500            Bob_Reload_DBShotgun_Load   2133
        load sawn-off dbl    1000 (default)  Bob_Reload_DBShotgun_Load   2133
        insert handgun mag   1500            Bob_Reload_Handgun_Load     1500
        insert rifle mag     1500            Bob_Reload_Rifle_Load       1733
        eject handgun mag    1200            Bob_Reload_Handgun_Load     1500 (reversed)
        eject rifle mag      1200            Bob_Reload_Rifle_Load       1733 (reversed)
        rack shotgun         600             Bob_Reload_Shotgun_Rack     1400, aiming 767
        rack handgun         1200            Bob_Reload_Handgun_Rack     1333
        rack bolt action     1200            Bob_Reload_Bolt_Rack        1767, aiming 1667
        rack lever action    1200            Bob_Reload_Lever_Rack       1133, aiming 1200
        rack revolver, dbl   1200            1200 (matches)

    The client's action only ends when the server's Done arrives, so a slower timer
    lets the looping animation run ahead of the round count (six shells take about
    seven loading motions), a faster one puts rounds in before the hand gets there,
    and a short rack or magazine timer cuts the animation off half way (the shotgun
    pump). Loading rounds into a magazine (500 ms, Bob_IdleLoadMagazine 500) already
    matches.

    This file replaces only those base times: while one of the four actions'
    serverStart runs, ISReloadWeaponAction.getReloadTime answers with the clip
    length for the gun's reload type when it is asked for the vanilla base time of
    that action and type (the 100 ms rackBullet of a rack, for one, is left alone).
    The rack picks the aimed clip from the server's isAiming(), which the aim state's
    synced parameters set (PlayerAimState.processOnEnter / processOnExit). The
    division by ReloadSpeed stays as it is. A constant lag of about one round trip
    remains (the server starts its timer when the request arrives, and the new count
    needs another trip back), as does the blend into the first loop.

    Guns that Gunworks (mod id SWMG) has a reload animation profile for are left
    alone: Gunworks times those itself (WeaponSystems/Hooks/ReloadAnimHooks.lua,
    ReloadAnim.getActionDurationMs, which never calls getReloadTime) and may play its
    own clips; when it falls through to vanilla for one, vanilla's timing is kept.
    The fast forward event code (*_FastForwardAnimEvents.lua) wraps emulateAnimEvent
    and so works from the corrected periods.
--]]

if not isServer() then return end

require "TimedActions/ISReloadWeaponAction"
require "TimedActions/ISInsertMagazine"
require "TimedActions/ISEjectMagazine"
require "TimedActions/ISRackFirearm"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.ReloadAnimTiming ~= false
end

--[[
    Per action, keyed by tostring(gun:getWeaponReloadType()) (the anim nodes'
    WeaponReloadType values): from = the vanilla base time it asks for, to = the
    clip length, aimed = the clip length while aiming (racks with an aimed node).
--]]
local TIMES = {
    reload = {
        shotgun = { from = 833, to = 700 },
        revolver = { from = 950, to = 767 },
        leveraction = { from = 1000, to = 700 },
        boltactionnomag = { from = 590, to = 700 },
        doublebarrelshotgun = { from = 2500, to = 2133 },
        doublebarrelshotgunsawn = { from = 1000, to = 2133 },
    },
    insert = {
        boltaction = { from = 1500, to = 1733 },
    },
    eject = {
        handgun = { from = 1200, to = 1500 },
        boltaction = { from = 1200, to = 1733 },
    },
    rack = {
        shotgun = { from = 600, to = 1400, aimed = 767 },
        handgun = { from = 1200, to = 1333 },
        boltaction = { from = 1200, to = 1767, aimed = 1667 },
        boltactionnomag = { from = 1200, to = 1767, aimed = 1667 },
        leveraction = { from = 1200, to = 1133, aimed = 1200 },
    },
}

-- Gunworks' ReloadAnim module, looked up on first use: nil = not yet, false = absent.
local gunworks = nil

local function gunworksTimes(gun)
    if gunworks == nil then
        gunworks = false
        if getActivatedMods():contains("SWMG") then
            local ok, module = pcall(require, "WeaponSystems/Utils/ReloadAnim")
            if ok and type(module) == "table" and module.GetHandlerForGun then
                gunworks = module
            end
        end
    end
    return gunworks and gunworks.GetHandlerForGun(gun) ~= nil
end

-- The action whose serverStart is running: { times = entry, aiming = bool }, or nil.
local current = nil

local vanillaGetReloadTime = ISReloadWeaponAction.getReloadTime

function ISReloadWeaponAction.getReloadTime(character, baseTime)
    local entry = current
    if entry and baseTime == entry.times.from then
        if entry.aiming and entry.times.aimed then
            baseTime = entry.times.aimed
        else
            baseTime = entry.times.to
        end
    end
    return vanillaGetReloadTime(character, baseTime)
end

--- What `kind` of this action's gun should be timed with, or nil to keep vanilla.
local function timesFor(action, kind)
    local gun = action.gun
    if not gun or not instanceof(gun, "HandWeapon") then return nil end
    local times = TIMES[kind][tostring(gun:getWeaponReloadType())]
    if not times or gunworksTimes(gun) then return nil end
    return times
end

local function wrapServerStart(class, kind)
    local previous = class.serverStart
    class.serverStart = function(self)
        local times = isEnabled() and timesFor(self, kind) or nil
        if not times then return previous(self) end
        current = {
            times = times,
            aiming = kind == "rack" and self.character ~= nil and self.character:isAiming(),
        }
        local ok, err = pcall(previous, self)
        current = nil
        if not ok then error(err) end
    end
end

wrapServerStart(ISReloadWeaponAction, "reload")
wrapServerStart(ISInsertMagazine, "insert")
wrapServerStart(ISEjectMagazine, "eject")
wrapServerStart(ISRackFirearm, "rack")
