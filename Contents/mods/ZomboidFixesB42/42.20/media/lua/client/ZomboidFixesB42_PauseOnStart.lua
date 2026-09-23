--[[
    Zomboid Fixes B42.20 -- client, pause on start

    Loading into a save drops the player straight into a running world. This pauses
    it before anything moves, the same as pressing the pause button.

    OnGameStart is fired from IngameState.enter(), before the state's first update,
    so a speed of 0 set here is in place before any zombie, timer or clock advances.
    The Survival Guide already does exactly this when it opens on start.

    The guide is also the one thing that undoes it: SurvivalGuide:setVisible sets the
    speed to 0 when shown and to 1 when hidden, so closing the guide that opened with
    the game would unpause it. That first close is caught and the pause kept, unless
    the player had already unpaused behind the guide. Every later open and close of
    the guide behaves as vanilla.

    Single player only. A multiplayer world runs on the server, and one client has
    no business stopping it for everyone.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.PauseOnStart == true
end

-- True while the guide that opened with the game has not yet been closed.
local holdThroughGuide = false

local function wrapSurvivalGuide()
    if SurvivalGuide == nil or SurvivalGuide.setVisible == nil then return end
    local setVisible = SurvivalGuide.setVisible
    SurvivalGuide.setVisible = function(self, visible, ...)
        if visible or not holdThroughGuide then
            return setVisible(self, visible, ...)
        end
        holdThroughGuide = false
        local stillPaused = getGameSpeed() == 0
        local r = setVisible(self, visible, ...)
        if stillPaused then setGameSpeed(0) end
        return r
    end
end

local function onGameStart()
    if isClient() or not isEnabled() then return end
    if getCore():getGameMode() == "Tutorial" then return end

    holdThroughGuide = SurvivalGuide ~= nil and SurvivalGuide.instance ~= nil
        and SurvivalGuide.instance:isVisible()
    wrapSurvivalGuide()
    setGameSpeed(0)
end

Events.OnGameStart.Add(onGameStart)
