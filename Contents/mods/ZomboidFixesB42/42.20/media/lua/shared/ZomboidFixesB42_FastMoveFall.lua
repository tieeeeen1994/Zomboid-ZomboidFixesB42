--[[
    Zomboid Fixes B42.20 -- shared, no fall damage while Fast Move is on

    Fast Move carries a player across stairs faster than the game snaps them to
    the steps, so they can end up above the floor, hang there, and then drop. The
    drop goes through IsoGameCharacter.updateFalling(), which has no cheat check:

        fallSpeed = lastFallSpeed + 5.0010414 * dt      -- builds up every frame
        on reaching the floor: DoLand(impactSpeed)       -- impact from lastFallSpeed

    and DoLand() -> handleLandingImpact() turns an impact of about 5.9 or more
    (a drop of 3.5 levels) into 1000 damage, unless an 80-in-100 roll saves them. Only God Mode avoids it, and turning God
    Mode on also heals every wound and clears every moodle.

    lastFallSpeed has a public setter, so this holds it under a cap while a player
    has Fast Move on. They still come down to the floor, at a steady glide, but
    the landing stays below isFallingThreshold (about 1.87): no landing animation,
    no knees, no damage. Normal falls are untouched.

    In multiplayer the client measures the landing and sends it to the server in
    PlayerFallingState's landing_impact parameter, and the server applies the
    damage from that. The server also runs updateFalling() for remote players, so
    the cap is applied on both sides: on the client from OnPlayerUpdate, which
    runs just before updateFalling() each frame, and on the server every tick.
--]]

-- Well under isFallingThreshold (1.87), leaving room for one frame of
-- acceleration (5 * dt) on top even at a low frame rate.
local MAX_FALL_SPEED = 1.0

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.NoFastMoveFallDamage == true
end

local function capFall(player)
    if player and player:isFastMoveCheat() and player:getLastFallSpeed() > MAX_FALL_SPEED then
        player:setLastFallSpeed(MAX_FALL_SPEED)
    end
end

local function onPlayerUpdate(player)
    if not isEnabled() then return end
    if player and player:isLocalPlayer() then
        capFall(player)
    end
end

local function onServerTick()
    if not isEnabled() then return end
    local online = getOnlinePlayers()
    if not online then return end
    for i = 0, online:size() - 1 do
        capFall(online:get(i))
    end
end

if isServer() then
    Events.OnTick.Add(onServerTick)
else
    Events.OnPlayerUpdate.Add(onPlayerUpdate)
end
