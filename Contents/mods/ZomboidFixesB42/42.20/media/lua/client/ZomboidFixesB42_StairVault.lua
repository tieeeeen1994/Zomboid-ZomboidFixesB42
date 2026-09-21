--[[
    Zomboid Fixes B42.20 -- client, no auto vault over stair railings

    Running or sprinting into a low fence vaults it without a key press. That
    happens in IsoMovingObject.checkVaultOver(), called from checkHitWall() while
    the player is being moved:

        if in ClimbOverFenceState or player.isIgnoreAutoVault(): no
        if not IsRunning() and not isSprinting(): no
        pick the Hoppable edge the player collided with, facing roughly towards it
        if isPlayerAbleToHopWallTo(dir) and isSafeToClimbOver(dir):
            ClimbOverFenceState.setParams(player, dir); reportEvent("EventClimbFence")

    Nothing there asks what is behind the fence, and isSafeToClimbOver() even
    counts a square with no floor as safe when it has stairs below it. So the
    railings on a staircase, and the ones round the stairwell on the floor above,
    are vaulted whenever a jogging player brushes them, dropping them off the side
    of the stairs or down the stairwell.

    The check is Java and never goes through Lua -- the ContextualActionHandlers
    ClimbOverFence handler is only for the interact key -- so the one thing Lua can
    change is the ignoreAutoVault flag it tests first. This sets that flag while a
    running player is facing a railing on or beside stairs, and clears it again
    otherwise, so ordinary fences on flat ground still auto vault as before.

    ignoreAutoVault also stops the interact key from hopping fences, which is why
    it is only ever set while the player is running: stop, press the key, and the
    railing can still be climbed on purpose.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.NoStairAutoVault == true
end

-- Players whose flag this file set, keyed by player index, so it only ever clears its
-- own and leaves the flag alone for anything else that uses it (the tutorial).
local ignoring = {}

--- Whether a fence between these two squares is a railing on or beside stairs,
-- rather than a fence between two floors at the same level.
local function isStairFence(from, to)
    if not to then return false end
    if from:HasStairs() or to:HasStairs() then return true end
    -- A floorless square past a railing is a stairwell: vanilla counts it as
    -- safe when there are stairs below, and the vault drops the player a floor.
    return not to:TreatAsSolidFloor()
end

--- The same four edges checkVaultOver() looks at, limited to the ones the player
-- is facing within 45 degrees, since those are the only ones it will vault.
local function facingStairFence(player, square)
    local dir = player:getDir()

    if dir == IsoDirections.N or dir == IsoDirections.NW or dir == IsoDirections.NE then
        if square:has(IsoFlagType.HoppableN)
            and isStairFence(square, square:getAdjacentSquare(IsoDirections.N)) then
            return true
        end
    end

    if dir == IsoDirections.S or dir == IsoDirections.SW or dir == IsoDirections.SE then
        local south = square:getAdjacentSquare(IsoDirections.S)
        if south and south:has(IsoFlagType.HoppableN) and isStairFence(square, south) then
            return true
        end
    end

    if dir == IsoDirections.W or dir == IsoDirections.NW or dir == IsoDirections.SW then
        if square:has(IsoFlagType.HoppableW)
            and isStairFence(square, square:getAdjacentSquare(IsoDirections.W)) then
            return true
        end
    end

    if dir == IsoDirections.E or dir == IsoDirections.NE or dir == IsoDirections.SE then
        local east = square:getAdjacentSquare(IsoDirections.E)
        if east and east:has(IsoFlagType.HoppableW) and isStairFence(square, east) then
            return true
        end
    end

    return false
end

local function shouldIgnore(player)
    if not isEnabled() then return false end
    if not player:IsRunning() and not player:isSprinting() then return false end
    local square = player:getCurrentSquare()
    return square ~= nil and facingStairFence(player, square)
end

local function onPlayerUpdate(player)
    if not player or not player:isLocalPlayer() then return end

    -- Stored as the player object rather than true, so a character who died and
    -- respawned under the same index is not mistaken for the one we flagged.
    local index = player:getPlayerNum()
    local ours = ignoring[index] == player

    if shouldIgnore(player) then
        -- Something else already set it; leave it to them.
        if not ours and not player:isIgnoreAutoVault() then
            player:setIgnoreAutoVault(true)
            ignoring[index] = player
        end
    elseif ours then
        player:setIgnoreAutoVault(false)
        ignoring[index] = nil
    end
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)
