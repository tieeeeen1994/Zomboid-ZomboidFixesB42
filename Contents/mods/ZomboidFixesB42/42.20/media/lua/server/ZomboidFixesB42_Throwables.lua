--[[
    Zomboid Fixes B42.20 -- server, throwing pipe bombs, Molotovs and other throwables

    shared/ZomboidFixesB42_Throwables.lua has the vanilla throw and the flight. The
    thrower's client sends throwable { item, ox, oy, oz, dx, dy, token, bounces,
    rotation, spin } at the swing's hit point (and flies its own copy at once); this
    flies the same path in fixed steps from OnTick and ends it the way vanilla's
    IsoMolotovCocktail.Explode does on a server, with the thrown item itself:

        IsoTrap.new(thrower, weapon, cell, square):place()

    IsoTrap.place (42.21) adds the trap to the square, sends AddExplosiveTrap to
    every client (each adds its own copy, and sets off an instant one too, for the
    local zombies and the effects), and on the server sets off one with
    weapon:isInstantExplosion() (no timer, sensor or remote: explosionTimer <= 0,
    sensorRange <= 0, no remote ID, not CanBeRemote). The others stay on the floor
    as traps. Vanilla's AddExplosiveTrapPacket.processServer does the same for a
    client's throw and logs it to the "map" logger; this logs the same line.

    In multiplayer the client's weapon:Use() right after the hit point removes the
    item only from its own inventory, so this takes the item out of the server's
    copy by ID (DoRemoveItem + sendRemoveItemFromContainer, which the client, no
    longer holding it, ignores). The item must be in the sender's inventory: a
    client cannot throw what it does not carry. The origin is the client's when it
    is near the server's position of the player, so both fly the same path; the
    destination is pulled in to the weapon's MaxRange. Every client then gets
    throwableFly to show it, and throwableEnd when it lands or goes off.

    In single player the client file calls Throwables.launch directly with the
    weapon, which vanilla's own Use() then takes out of the inventory.
    Option ThrowableBallistics.
--]]

if isClient() then return end

local Throwables = ZomboidFixesB42.Throwables

-- How far the client's origin may be from the server's position of the player.
local MAX_ORIGIN_OFFSET = 3
local RATE_LIMIT = 5
-- A flight that has not ended by then ends where it is.
local MAX_FLIGHT_SECONDS = 30

local flights = {}
local clock = { carry = 0 }

local function finish(entry)
    local f = entry.flight
    local square = f.square
    local thrower = entry.player
    if thrower and isServer() and getPlayerByOnlineID(entry.onlineID) ~= thrower then thrower = nil end

    if square then
        local trap = thrower and IsoTrap.new(thrower, entry.weapon, square:getCell(), square)
            or IsoTrap.new(entry.weapon, square:getCell(), square)
        trap:place()
        if isServer() then
            local name = entry.player and entry.player:getUsername() or "?"
            writeLog("map", string.format('"%s" threw %s to %d,%d,%d', name, entry.weapon:getFullType(),
                square:getX(), square:getY(), square:getZ()))
        end
    end

    if isServer() then
        sendServerCommand(ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_THROWABLE_END, { key = entry.key })
    elseif Throwables.endVisual then
        Throwables.endVisual(entry.key)
    end
end

--- Starts a throw. `throw` holds ox, oy, oz (origin), dx, dy (destination),
-- bounces, rotation and spin, all checked; the destination floor is the origin's.
function Throwables.launch(player, weapon, throw, key)
    local params = Throwables.paramsFor(weapon)
    throw.dz = Throwables.floorOf(throw.oz)
    local flight = Throwables.newFlight(params, throw)
    if not flight then return false end

    if #flights == 0 then
        clock.last = getTimestampMs()
        clock.carry = 0
    end
    flights[#flights + 1] = {
        key = key,
        flight = flight,
        weapon = weapon,
        player = player,
        onlineID = player:getOnlineID(),
    }

    if isServer() then
        sendServerCommand(ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_THROWABLE_FLY, {
            key = key,
            type = weapon:getFullType(),
            maxDistance = params.maxDistance,
            detonateOnImpact = params.detonateOnImpact,
            fuse = params.fuse,
            ox = throw.ox, oy = throw.oy, oz = throw.oz,
            dx = throw.dx, dy = throw.dy,
            bounces = throw.bounces,
            rotation = throw.rotation,
            spin = throw.spin,
        })
    end
    return true
end

local function onTick()
    if #flights == 0 then return end
    local steps = Throwables.stepsDue(clock)
    if steps == 0 then return end

    for i = #flights, 1, -1 do
        local entry = flights[i]
        local f = entry.flight
        local fuse = f.params.fuse
        local done = false
        for _ = 1, steps do
            local status = Throwables.step(f)
            if (fuse > 0 and f.age >= fuse)
                or status == "wall" or status == "impact"
                or (status == "rest" and fuse <= 0)
                or f.age >= MAX_FLIGHT_SECONDS then
                done = true
                break
            end
        end
        if done then
            table.remove(flights, i)
            finish(entry)
        end
    end
end

-- [player online ID] = { second = whole second, count = throws in it }
local rates = {}

local function withinRate(player)
    local id = player:getOnlineID()
    local second = math.floor(getTimestampMs() / 1000)
    local rate = rates[id]
    if not rate or rate.second ~= second then
        rate = { second = second, count = 0 }
        rates[id] = rate
    end
    rate.count = rate.count + 1
    return rate.count <= RATE_LIMIT
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function onThrow(player, args)
    if not Throwables.isEnabled() or not player or player:isDead() or not withinRate(player) then return end

    local id = tonumber(args.item)
    local token = tonumber(args.token)
    local dx, dy = tonumber(args.dx), tonumber(args.dy)
    if not id or not token or not dx or not dy then return end

    local weapon = player:getInventory():getItemWithIDRecursiv(id)
    if not weapon or not Throwables.isHandled(weapon) then return end

    local sx, sy, sz = Throwables.originFor(player)
    local ox, oy, oz = tonumber(args.ox), tonumber(args.oy), tonumber(args.oz)
    if not ox or not oy or not oz
        or math.abs(ox - sx) > MAX_ORIGIN_OFFSET or math.abs(oy - sy) > MAX_ORIGIN_OFFSET
        or math.abs(oz - sz) > 1 then
        ox, oy, oz = sx, sy, sz
    end

    local throw = {
        ox = ox, oy = oy, oz = oz,
        dx = dx, dy = dy,
        bounces = clamp(math.floor(tonumber(args.bounces) or 1), 1, Throwables.MAX_BOUNCES),
        rotation = (tonumber(args.rotation) or 0) % 360,
        spin = clamp(tonumber(args.spin) or Throwables.SPIN_MIN, Throwables.SPIN_MIN, Throwables.SPIN_MAX),
    }

    local container = weapon:getContainer()
    if container then
        container:DoRemoveItem(weapon)
        sendRemoveItemFromContainer(container, weapon)
    end
    Throwables.launch(player, weapon, throw, string.format("%d:%d", player:getOnlineID(), token))
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_THROW then return end
    onThrow(player, type(args) == "table" and args or {})
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(onTick)
