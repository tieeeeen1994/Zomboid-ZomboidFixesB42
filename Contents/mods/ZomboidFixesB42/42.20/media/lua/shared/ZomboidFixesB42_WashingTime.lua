--[[
    Zomboid Fixes B42.20 -- shared, washing time

    ISBaseTimedAction:adjustMaxTime (42.21 ~99) makes an action longer for an
    unhappy or drunk character (x 1 + level / 4 each), for pain in the hands and
    forearms (x 1 + pain / 300) and by body temperature
    (getTimedActionTimeModifier). Every action gets it once: ISBaseTimedAction:create
    adjusts maxTime on the client (and in single player), and on a server
    NetTimedAction adjusts getDuration() when the action starts.

    ISWashClothing is the only vanilla action whose getDuration already returns
    self:adjustMaxTime(maxTime) (~215), and its new sets maxTime = getDuration(),
    so washing is adjusted twice everywhere: create adjusts it again on the client
    and in single player, NetTimedAction again on a server (the two agree, so the
    bar is not out of step, only far too long). The slowdowns are squared: a very
    unhappy and very drunk character (x 2 each, x 4 together) washes 16 times
    slower instead of 4.

    So getDuration returns the base time here, and the one adjustment every other
    action gets is the only one. During vanilla's getDuration the instance gets
    an adjustMaxTime that returns the time unchanged, removed right after, so
    anything else that wraps ISBaseTimedAction.adjustMaxTime (fast forward on a
    server) still runs for the real adjustment. Option WashingTimeFix.
--]]

require "TimedActions/ISWashClothing"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.WashingTimeFix == true
end

local function unadjusted(_, maxTime)
    return maxTime
end

local vanillaGetDuration = ISWashClothing.getDuration

function ISWashClothing:getDuration(...)
    if not isEnabled() then
        return vanillaGetDuration(self, ...)
    end
    self.adjustMaxTime = unadjusted
    local ok, result = pcall(vanillaGetDuration, self, ...)
    self.adjustMaxTime = nil
    if not ok then error(result) end
    return result
end
