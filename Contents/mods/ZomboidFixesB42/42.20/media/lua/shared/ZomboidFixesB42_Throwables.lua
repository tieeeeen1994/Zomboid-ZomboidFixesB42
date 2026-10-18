--[[
    Zomboid Fixes B42.20 -- shared, throwing pipe bombs, Molotovs and other throwables

    Vanilla throw (42.21). CombatManager.attackCollisionCheck fires
    OnWeaponSwingHitPoint(owner, weapon) and then, when the weapon has a
    PhysicsObject, IsoGameCharacter.Throw(weapon) (~7932), followed by weapon:Use().
    Throw aims at attackTargetSquare, which IsoLivingCharacter picked when the swing
    began from UIManager.getPicked(): the square of the tile under the mouse, or of
    the character under it, so a wall or a tall object can stand in for the floor
    behind it (a joypad throws MaxRange straight ahead). It then takes the distance
    to that square's corner, clamps x and y each to MaxRange (a square, not a
    circle: diagonals reach 1.4 times further) and spawns an IsoMolotovCocktail at
    height 0.6 with velocity distance x 0.4 per axis. The Molotov's constructor
    adds a random -0.2..0.2 to each axis, half the whole velocity on a one-tile
    throw. IsoPhysicsObject.update has no upward speed (velZ starts at 0: the item
    drops from hand height), keeps 90% of its speed per frame, and scales every step
    by 30 / PerformanceSettings.getLockFPS(), the frame rate cap from the options,
    not the real frame time, so the same throw lands elsewhere on a game that runs
    below its cap, and a server steps at a fixed 10. Where the throw ends is
    computed on the thrower's client (IsoMolotovCocktail.Explode on a client sends
    AddExplosiveTrapPacket with the item for a local player only).

    Explosion timing: HandWeapon.triggerExplosionTimer (script triggerExplosionTimer,
    in 30 fps ticks: 50 for the aerosol bomb, noise maker and smoke bomb) counts
    from the throw and explodes wherever the item is; 0 explodes at the first wall,
    floor or character it touches (pipe bomb, Molotov, firecracker, and every
    remote, sensor and timer variant, which IsoTrap then leaves on the floor to wait).

    This replaces it with the ballistic throw of Gunworks gang framework's
    ExplosivesSystems (Workshop 3722064198, mod id SWMG: Physics.lua, used by Guns
    of Marz's grenades), adapted: the item flies in an arc to the point under the
    mouse (screenToIsoX/Y at the player's floor, as ISPlace3DItemCursor places 3D
    items; Gunworks adds a fixed 1.5 tiles to both, which is not needed), at most
    the weapon's MaxRange away in any direction, bounces off closed doors, windows
    and walls (low walls only below 0.25 height) and ceilings, drops to the floor
    below when thrown off a ledge, and comes to rest after a few bounces. Changes
    from Gunworks: fixed 60 Hz steps on every side (Gunworks scales one step by the
    frame time, so a server at 10 updates a second moved up to 1.2 tiles a step and
    went through walls, and its path differed from the clients'), real time instead
    of game time (fast forward does not speed the throw up), and the explosion is
    vanilla's: the thrown item itself becomes an IsoTrap (IsoTrap:place, see the
    server file), so remote, sensor and timer bombs keep their remote ID and lie
    down to wait as before.

    The vanilla throw is turned off for one frame: OnWeaponSwingHitPoint clears the
    weapon's physics object (HandWeapon.setPhysicsObject; the field is not saved
    with the item) so Throw spawns nothing, and the next tick puts it back. This runs
    for every character on every side. Items Gunworks already throws (its
    OrdnanceFactory registry) are left to it. Option ThrowableBallistics.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local Throwables = {}
ZomboidFixesB42.Throwables = Throwables

function Throwables.isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ThrowableBallistics == true
end

-- Gunworks' numbers. A step is 1/60 s; positions move by velocity x XY_STEP and
-- height by velocity x Z_STEP per step.
local GRAVITY = 0.020
local XY_STEP = 0.10
local Z_STEP = 0.05
local DRAG_XY = 0.995
local DRAG_Z = 0.998
local BOUNCE_WALL = 0.50
local BOUNCE_CEILING = 0.30
local BOUNCE_POSITION_CORRECT = 0.12
local BOUNCE_MIN_VELOCITY = 0.004
local EDGE_TOL = 0.15
local LOW_WALL_HEIGHT = 0.25
local GRAVITY_WORLD = GRAVITY * Z_STEP * 3600
local XY_CONV = XY_STEP * 60
local Z_CONV = Z_STEP * 60

Throwables.STEP_SECONDS = 1 / 60
-- Steps run at most per update; a longer stall is dropped.
Throwables.MAX_STEPS = 15

-- The throw, as Guns of Marz throws its grenades.
Throwables.ARC_FACTOR = 0.12 -- arc height = distance x this
Throwables.MAX_ARC = 1.5 -- tiles
Throwables.MAX_SPEED = 12 -- tiles a second across the ground
Throwables.FORWARD_OFFSET = 0.5 -- the item leaves the hand this far ahead
Throwables.HEIGHT_OFFSET = 0.55 -- and this high
Throwables.MAX_BOUNCES = 5 -- the floor bounces it takes are 1..this, picked per throw
Throwables.BOUNCE_ENERGY = 0.2
Throwables.SPIN_MIN = 10 -- degrees a step while in the air
Throwables.SPIN_MAX = 30

local gunworksRegistry = nil
local gunworksChecked = false

--- Gunworks' OrdnanceFactory, when that mod is on.
local function getGunworksRegistry()
    if not gunworksChecked then
        gunworksChecked = true
        if getActivatedMods():contains("SWMG") then
            gunworksRegistry = require "ExplosivesSystems/OrdnanceFactory"
        end
    end
    return gunworksRegistry
end

--- Whether this throwable flies the ballistic way: a weapon whose item script has
-- a PhysicsObject (IsoMolotovCocktail; vanilla's other kind, "Ball", is left
-- alone) that Gunworks does not throw itself.
function Throwables.isHandled(weapon)
    if not weapon or not instanceof(weapon, "HandWeapon") then return false end
    local script = weapon:getScriptItem()
    local physics = script and script:getPhysicsObject()
    if not physics or physics == "" or string.lower(physics) == "ball" then return false end
    local registry = getGunworksRegistry()
    if registry and registry.IsRegistered and registry.IsRegistered(weapon:getFullType()) then return false end
    return true
end

--- What a throw of this weapon does: how far it goes, and whether it explodes on
-- the first thing it touches or after a fuse (seconds).
function Throwables.paramsFor(weapon)
    local timer = weapon:getTriggerExplosionTimer() or 0
    return {
        maxDistance = math.max(1, weapon:getMaxRange()),
        detonateOnImpact = timer <= 0,
        fuse = timer > 0 and timer / 30 or 0,
    }
end

--- Where the item leaves the hand.
function Throwables.originFor(player)
    local forward = player:getForwardDirection()
    return player:getX() + forward:getX() * Throwables.FORWARD_OFFSET,
        player:getY() + forward:getY() * Throwables.FORWARD_OFFSET,
        player:getZ() + Throwables.HEIGHT_OFFSET
end

--- The floor a throw from this origin aims at (the thrower's).
function Throwables.floorOf(originZ)
    return math.floor(originZ - Throwables.HEIGHT_OFFSET)
end

local function predictUnitRange(vz, startZ)
    local vx, x, z = 1.0, 0, startZ
    for _ = 1, 1200 do
        vz = vz - GRAVITY
        x = x + vx * XY_STEP
        z = z + vz * Z_STEP
        vx = vx * DRAG_XY
        vz = vz * DRAG_Z
        if z <= 0 then return x end
    end
    return x
end

--- Launch velocity (internal units) that lands at the destination, which is first
-- pulled in to maxDistance.
local function launchVelocity(params, ox, oy, oz, dx, dy, dz)
    local ddx, ddy = dx - ox, dy - oy
    local distance = math.sqrt(ddx * ddx + ddy * ddy)
    if distance > params.maxDistance then
        local ratio = params.maxDistance / distance
        ddx, ddy, distance = ddx * ratio, ddy * ratio, params.maxDistance
    end
    local dirX = distance > 0.01 and ddx / distance or 0
    local dirY = distance > 0.01 and ddy / distance or 0

    local arc = math.min(Throwables.MAX_ARC, distance * Throwables.ARC_FACTOR)
    local vzWorld = math.sqrt(math.max(0, 2 * GRAVITY_WORLD * arc))
    local vz = vzWorld / Z_CONV
    local unitRange = predictUnitRange(vz, math.max(0, oz - dz))
    local speed
    if unitRange > 0.001 then
        speed = distance / unitRange * XY_CONV
    else
        speed = distance / 0.02
    end
    speed = math.min(speed, Throwables.MAX_SPEED)
    return dirX * speed / XY_CONV, dirY * speed / XY_CONV, vz
end

local function floorBelow(x, y, z)
    local minZ = getMinimumWorldLevel and getMinimumWorldLevel() or -32
    local maxZ = getMaximumWorldLevel and getMaximumWorldLevel() or 8
    local cell = getCell()
    local checkZ = math.min(z, maxZ)
    while checkZ >= minZ do
        local square = cell:getGridSquare(x, y, checkZ)
        if not square then return nil end
        if square:getFloor() then return square end
        checkZ = checkZ - 1
    end
    return nil
end

local function isLowWall(wall)
    local props = wall and wall:getProperties()
    if not props then return false end
    return props:has(IsoFlagType.transparentW) or props:has(IsoFlagType.transparentN)
        or props:has(IsoFlagType.HoppableW) or props:has(IsoFlagType.HoppableN)
end

local function isBlocked(fromSq, toSq, dir, height)
    local barrier = fromSq:getDoorOrWindowOrWindowFrame(dir, true)
        or toSq:getDoorOrWindowOrWindowFrame(dir:Rot180(), true)
    if barrier and (instanceof(barrier, "IsoDoor") or instanceof(barrier, "IsoWindow")) then
        return not barrier:IsOpen() and not (barrier.isDestroyed and barrier:isDestroyed())
    end
    if fromSq:isWallTo(toSq) then
        if isLowWall(fromSq:getWall()) or isLowWall(toSq:getWall()) then
            return height < LOW_WALL_HEIGHT
        end
        return true
    end
    return false
end

--- A thrown item's flight state: square, position in it, velocity, bounces left.
-- Everything a client needs to fly the same path is in `throw` (origin,
-- destination, bounces), so every side builds it with this.
function Throwables.newFlight(params, throw)
    local square = getCell():getGridSquare(math.floor(throw.ox), math.floor(throw.oy), math.floor(throw.oz))
    if not square then return nil end
    local vx, vy, vz = launchVelocity(params, throw.ox, throw.oy, throw.oz, throw.dx, throw.dy, throw.dz)
    return {
        params = params,
        square = square,
        x = throw.ox - square:getX(),
        y = throw.oy - square:getY(),
        z = throw.oz - square:getZ(),
        vx = vx,
        vy = vy,
        vz = vz,
        prevWorldZ = throw.oz,
        bouncesLeft = throw.bounces,
        hasHitFloor = false,
        atRest = false,
        rotation = throw.rotation,
        spin = throw.spin,
        age = 0,
    }
end

--- One 1/60 s step. Returns "flying", "wall" (hit a wall, door or window),
-- "impact" (first floor contact), "bounce" or "rest".
function Throwables.step(f)
    f.age = f.age + Throwables.STEP_SECONDS
    if f.atRest then return "rest" end
    f.rotation = (f.rotation + f.spin) % 360

    f.vz = f.vz - GRAVITY
    local oldX, oldY = f.x, f.y
    f.x = f.x + f.vx * XY_STEP
    f.y = f.y + f.vy * XY_STEP
    f.z = f.z + f.vz * Z_STEP
    f.vx = f.vx * DRAG_XY
    f.vy = f.vy * DRAG_XY
    f.vz = f.vz * DRAG_Z

    local cell = getCell()
    local sx, sy, sz = f.square:getX(), f.square:getY(), f.square:getZ()
    local blockX, blockY = false, false
    if f.vx > 0 and oldX < 1 - EDGE_TOL and f.x >= 1 - EDGE_TOL then
        local side = cell:getGridSquare(sx + 1, sy, sz)
        blockX = side ~= nil and isBlocked(f.square, side, IsoDirections.E, f.z)
    elseif f.vx < 0 and oldX > EDGE_TOL and f.x <= EDGE_TOL then
        local side = cell:getGridSquare(sx - 1, sy, sz)
        blockX = side ~= nil and isBlocked(f.square, side, IsoDirections.W, f.z)
    end
    if f.vy > 0 and oldY < 1 - EDGE_TOL and f.y >= 1 - EDGE_TOL then
        local side = cell:getGridSquare(sx, sy + 1, sz)
        blockY = side ~= nil and isBlocked(f.square, side, IsoDirections.S, f.z)
    elseif f.vy < 0 and oldY > EDGE_TOL and f.y <= EDGE_TOL then
        local side = cell:getGridSquare(sx, sy - 1, sz)
        blockY = side ~= nil and isBlocked(f.square, side, IsoDirections.N, f.z)
    end
    if blockX then
        f.vx = -f.vx * BOUNCE_WALL
        f.x = f.x + f.vx * BOUNCE_POSITION_CORRECT
        if math.abs(f.vx) < BOUNCE_MIN_VELOCITY then f.vx = 0 end
    end
    if blockY then
        f.vy = -f.vy * BOUNCE_WALL
        f.y = f.y + f.vy * BOUNCE_POSITION_CORRECT
        if math.abs(f.vy) < BOUNCE_MIN_VELOCITY then f.vy = 0 end
    end
    if (blockX or blockY) and f.params.detonateOnImpact then return "wall" end

    local worldX, worldY = sx + f.x, sy + f.y
    local tileX, tileY = math.floor(worldX), math.floor(worldY)
    local worldZ = sz + f.z
    if worldZ > f.prevWorldZ and f.z >= 1.0 then
        local above = cell:getGridSquare(tileX, tileY, sz + 1)
        if above and above:TreatAsSolidFloor() then
            f.vz = -math.abs(f.vz) * BOUNCE_CEILING
            f.z = 0.95
            worldZ = sz + f.z
        end
    end

    local square = floorBelow(tileX, tileY, sz)
    if square then
        f.square = square
        f.z = worldZ - square:getZ()
    end
    f.x = worldX - f.square:getX()
    f.y = worldY - f.square:getY()
    f.prevWorldZ = f.square:getZ() + f.z

    if f.z <= 0 then
        f.z = 0
        local first = not f.hasHitFloor
        f.hasHitFloor = true
        if first and f.params.detonateOnImpact then return "impact" end
        if f.bouncesLeft > 0 then
            f.bouncesLeft = f.bouncesLeft - 1
            f.z = 0.01
            f.vz = math.abs(f.vz) * Throwables.BOUNCE_ENERGY
            f.vx = f.vx * 0.6
            f.vy = f.vy * 0.6
            return "bounce"
        end
        f.vx, f.vy, f.vz = 0, 0, 0
        f.atRest = true
        return "rest"
    end

    f.x = math.max(0, math.min(1, f.x))
    f.y = math.max(0, math.min(1, f.y))
    return "flying"
end

--- Steps owed for the real time since the last call, kept in `clock`
-- ({ last = ms, carry = steps }). None while single player is paused.
function Throwables.stepsDue(clock)
    local now = getTimestampMs()
    local last = clock.last
    clock.last = now
    if not last or (not isClient() and not isServer() and isGamePaused()) then return 0 end
    local steps = clock.carry + (now - last) / 1000 / Throwables.STEP_SECONDS
    local whole = math.floor(steps)
    clock.carry = steps - whole
    return math.min(whole, Throwables.MAX_STEPS)
end

-- Turning the vanilla throw off for one frame ---------------------------------

local restore = {}

local function onWeaponSwingHitPoint(character, weapon)
    if not Throwables.isEnabled() or not Throwables.isHandled(weapon) then return end
    local physics = weapon:getPhysicsObject()
    if not physics then return end
    restore[#restore + 1] = { weapon = weapon, physics = physics }
    weapon:setPhysicsObject(nil)
    -- The last thing Throw does.
    if instanceof(character, "IsoPlayer") then character:setAttackAnimThrowTimer(0) end
    if Throwables.onThrow then Throwables.onThrow(character, weapon) end
end

local function onTick()
    if #restore == 0 then return end
    for i = 1, #restore do
        local entry = restore[i]
        entry.weapon:setPhysicsObject(entry.physics)
    end
    restore = {}
end

Events.OnWeaponSwingHitPoint.Add(onWeaponSwingHitPoint)
Events.OnTick.Add(onTick)
