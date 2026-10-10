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
    pump).

    Filling a loose magazine (ISLoadBulletsInMagazine) is twice as fast as its animation.
    Its client clip (InsertBullets, Bob_IdleLoadMagazine) does not play at its own length:
    m_TrackTimeToVariable ties it to UpdateLoadBulletsTime, which the action's
    updateLoadingTime advances by getAnimationTimeDelta() (seconds) x ReloadSpeed and wraps
    at 1.0, so one loop takes 1000 / ReloadSpeed ms, and single player puts one round in
    per loop (InsertBullet, once per loop by loadedThisLoop). The server fires InsertBullet
    every getReloadTime(500) ms with no such guard, so in multiplayer two rounds go in per
    loop while the client's click (InsertBulletSound, also once per loop) sounds for at
    most one of them. Logged on a server 2026-10-11 at ReloadSpeed 1.8: loops every ~555
    ms, a round every ~300 ms. So that base time becomes 1000 too (the 500 ms
    updateLoadingTime event, which the server's copy uses for nothing, with it); the
    550 ms loadFinished that ends a full magazine is left alone. Emptying a magazine
    (ISUnloadBulletsFromMagazine: RemoveBullets node, the same clip and variable,
    RemoveBullet every 500, unloadFinished every 550) is built the same way and gets
    the same change.

    Right lengths are not enough for the events that repeat once per round (shells'
    loadFinished, a magazine's InsertBullet and RemoveBullet). AnimEventEmulator.update
    runs once per server update (~100 ms) and restarts an event's timer when it fires,
    so every period is rounded up to the next update: 555 ms becomes about 600, and the
    rounds fall further behind the animation with every one. And its first firing
    comes one whole period after the start, while a magazine's client loop clicks and
    (in single player) moves its first round at the start of the first loop. So those
    events are not given to the emulator: while serverStart runs, emulateAnimEvent is
    swapped for one that keeps them, and an OnTick here owes the action
    elapsed ms x game speed / period of them, paying what is owed every tick (a
    magazine starts owing one). The average rate is then the animation's, whatever the
    update rate, and the fast forward speed (ZomboidFixesB42.fastForwardSpeed) is
    followed from the next tick, mid-action included; ZomboidFixesB42_FastForward-
    AnimEvents.lua never sees these events, so it adds no extras for them. Paying stops
    once the action completes, is stopped, or is about to complete (getProgress >= 1).

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
require "TimedActions/ISLoadBulletsInMagazine"
require "TimedActions/ISUnloadBulletsFromMagazine"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ReloadAnimTiming == true
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
    -- Every magazine, whatever the gun (the actions have no gun to key by).
    magazine = { from = 500, to = 1000 },
    unload = { from = 500, to = 1000 },
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

-- Events paced here instead of by the emulator: the per-round event of each kind, and
-- whether one is owed at once (a magazine's loop moves a round at its start, a shell
-- loop at its end).
local PACED = {
    reload = { event = "loadFinished", owedAtStart = 0 },
    magazine = { event = "InsertBullet", owedAtStart = 1 },
    unload = { event = "RemoveBullet", owedAtStart = 1 },
}

-- Most rounds paid to one action in one tick, and how long one is paced at most
-- (AnimEventEmulator.getDurationMax, 30 minutes).
local MAX_PER_TICK = 60
local MAX_AGE_MS = 1800000

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
    if kind == "magazine" or kind == "unload" then return TIMES[kind] end
    local gun = action.gun
    if not gun or not instanceof(gun, "HandWeapon") then return nil end
    local times = TIMES[kind][tostring(gun:getWeaponReloadType())]
    if not times or gunworksTimes(gun) then return nil end
    return times
end

-- Actions whose per-round event is paced here: { action, net, event, parameter, period, owed, startMs, lastMs }.
local pacers = {}

--- Mark the action ended when the server completes or stops it.
local function hookEnd(action)
    if action.zfixPaceHooked then return end
    action.zfixPaceHooked = true
    local complete = action.complete
    local serverStop = action.serverStop
    action.complete = function(self, ...)
        self.zfixPaceEnded = true
        if complete then return complete(self, ...) end
        return true
    end
    action.serverStop = function(self, ...)
        self.zfixPaceEnded = true
        if serverStop then return serverStop(self, ...) end
    end
end

local function pace(action, period, event, parameter, owedAtStart)
    hookEnd(action)
    local now = getTimestampMs()
    table.insert(pacers, {
        action = action, net = action.netAction, event = event, parameter = parameter,
        period = period, owed = owedAtStart, startMs = now, lastMs = now,
    })
end

local function isOver(p, now)
    return p.action.zfixPaceEnded or now - p.startMs > MAX_AGE_MS or p.net:getProgress() >= 1
end

local function onTick()
    if #pacers == 0 then return end
    local now = getTimestampMs()
    local speed = math.max(ZomboidFixesB42 and ZomboidFixesB42.fastForwardSpeed or 1, 1)
    -- A copy, since paying runs the action's Lua.
    local list = {}
    for i, p in ipairs(pacers) do list[i] = p end
    for _, p in ipairs(list) do
        if isOver(p, now) then
            p.over = true
        else
            p.owed = p.owed + (now - p.lastMs) * speed / p.period
            p.lastMs = now
            local paid = 0
            while p.owed >= 1 and paid < MAX_PER_TICK and not isOver(p, now) do
                p.owed = p.owed - 1
                paid = paid + 1
                p.net:animEvent(p.event, p.parameter)
            end
        end
    end
    for i = #pacers, 1, -1 do
        if pacers[i].over then table.remove(pacers, i) end
    end
end

Events.OnTick.Add(onTick)

local function wrapServerStart(class, kind)
    local previous = class.serverStart
    class.serverStart = function(self)
        local times = isEnabled() and timesFor(self, kind) or nil
        if not times then return previous(self) end
        current = {
            times = times,
            aiming = kind == "rack" and self.character ~= nil and self.character:isAiming(),
        }
        local paced = PACED[kind]
        local outerEmulate = emulateAnimEvent
        if paced and self.netAction then
            emulateAnimEvent = function(netAction, duration, event, parameter)
                local period = tonumber(duration)
                if event == paced.event and netAction == self.netAction and period and period > 0 then
                    pace(self, period, event, parameter, paced.owedAtStart)
                    return
                end
                return outerEmulate(netAction, duration, event, parameter)
            end
        end
        local ok, err = pcall(previous, self)
        emulateAnimEvent = outerEmulate
        current = nil
        if not ok then error(err) end
    end
end

wrapServerStart(ISReloadWeaponAction, "reload")
wrapServerStart(ISInsertMagazine, "insert")
wrapServerStart(ISEjectMagazine, "eject")
wrapServerStart(ISRackFirearm, "rack")
wrapServerStart(ISLoadBulletsInMagazine, "magazine")
wrapServerStart(ISUnloadBulletsFromMagazine, "unload")
