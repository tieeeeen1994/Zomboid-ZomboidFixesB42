--[[
    Zomboid Fixes B42.20 -- client, filling a magazine clicks once for every loop

    Filling a loose magazine (shared/TimedActions/ISLoadBulletsInMagazine.lua, 42.21)
    loops the InsertBullets animation node, whose time is tied to the action's
    UpdateLoadBulletsTime (m_TrackTimeToVariable): updateLoadingTime advances it every
    update and wraps it at 1.0, clearing loadedThisLoop. Its events do not come once per
    loop: logged on a server (2026-10-11), InsertBulletSound and InsertBullet both arrive
    every frame, whatever the time in the loop. Vanilla keeps each to one per loop with
    loadedThisLoop, which InsertBullet sets and InsertBulletSound only reads, so when
    InsertBullet is handed out first in the first frame of a loop, that whole loop is
    silent (three loops out of eight in the log) while the round still goes in.

    So the click gets its own once-per-loop mark: the first InsertBulletSound after the
    loop wraps plays it, whatever came before it in that frame. The skip when loading
    is finished is kept. Vanilla's handler for that event only plays the click, so it is
    not called for it. Only for the local player's own action (isLocal: a client, or
    single player).

    The server half (server/ZomboidFixesB42_ReloadTiming.lua) puts one round in per
    loop instead of two, so every round gets a click.
--]]

require "TimedActions/ISLoadBulletsInMagazine"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ReloadAnimTiming == true
end

local previousUpdateLoadingTime = ISLoadBulletsInMagazine.updateLoadingTime

function ISLoadBulletsInMagazine:updateLoadingTime()
    local before = self.updateLoadBulletsTime
    previousUpdateLoadingTime(self)
    local after = self.updateLoadBulletsTime
    if before and after and after < before then
        self.zfixClickedThisLoop = nil
    end
end

local previousAnimEvent = ISLoadBulletsInMagazine.animEvent

function ISLoadBulletsInMagazine:animEvent(event, parameter)
    if event == "InsertBulletSound" and isEnabled() and self:isLocal() then
        if not self.zfixClickedThisLoop and not self:isLoadFinished() then
            self.zfixClickedThisLoop = true
            self.character:playSound(parameter)
        end
        return
    end
    return previousAnimEvent(self, event, parameter)
end
