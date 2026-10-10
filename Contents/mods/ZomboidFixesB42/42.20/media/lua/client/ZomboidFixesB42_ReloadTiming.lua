--[[
    Zomboid Fixes B42.20 -- client, filling or emptying a magazine clicks once every loop

    Filling a loose magazine (shared/TimedActions/ISLoadBulletsInMagazine.lua, 42.21)
    loops the InsertBullets animation node, whose time is tied to the action's
    UpdateLoadBulletsTime (m_TrackTimeToVariable): updateLoadingTime advances it every
    update and wraps it at 1.0, clearing loadedThisLoop. Its events do not come once per
    loop: logged on a server (2026-10-11), InsertBulletSound and InsertBullet both arrive
    every frame, whatever the time in the loop. Vanilla keeps each to one per loop with
    loadedThisLoop, which InsertBullet sets and InsertBulletSound only reads, so when
    InsertBullet is handed out first in the first frame of a loop, that whole loop is
    silent (three loops out of eight in the log) while the round still goes in.
    Emptying one (ISUnloadBulletsFromMagazine: RemoveBullets node, RemoveBullet /
    RemoveBulletSound, unloadedThisLoop) is built the same way.

    So the click gets its own once-per-loop mark: the first click event after the loop
    wraps plays it, whatever came before it in that frame. Vanilla's skip when there is
    nothing left to do is kept (loading finished; an empty magazine when unloading).
    Vanilla's handler for that event only plays the click, so it is not called for it.
    Only for the local player's own action (isLocal: a client, or single player).

    The server half (server/ZomboidFixesB42_ReloadTiming.lua) moves one round per loop
    instead of two, so every round gets a click.
--]]

require "TimedActions/ISLoadBulletsInMagazine"
require "TimedActions/ISUnloadBulletsFromMagazine"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ReloadAnimTiming == true
end

--- Gives `class`'s `soundEvent` its own once-per-loop mark; `isDone(self)` = nothing left to click for.
local function clickOncePerLoop(class, soundEvent, isDone)
    local previousUpdateLoadingTime = class.updateLoadingTime
    class.updateLoadingTime = function(self)
        local before = self.updateLoadBulletsTime
        previousUpdateLoadingTime(self)
        local after = self.updateLoadBulletsTime
        if before and after and after < before then
            self.zfixClickedThisLoop = nil
        end
    end

    local previousAnimEvent = class.animEvent
    class.animEvent = function(self, event, parameter)
        if event == soundEvent and isEnabled() and self:isLocal() then
            if not self.zfixClickedThisLoop and not isDone(self) then
                self.zfixClickedThisLoop = true
                self.character:playSound(parameter)
            end
            return
        end
        return previousAnimEvent(self, event, parameter)
    end
end

clickOncePerLoop(ISLoadBulletsInMagazine, "InsertBulletSound", function(self)
    return self:isLoadFinished()
end)

clickOncePerLoop(ISUnloadBulletsFromMagazine, "RemoveBulletSound", function(self)
    return self.magazine:getCurrentAmmoCount() <= 0
end)
