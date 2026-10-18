--[[
    Zomboid Fixes B42.20 -- client, throwing pipe bombs, Molotovs and other throwables

    shared/ZomboidFixesB42_Throwables.lua has the vanilla throw and the flight, the
    server file what ends it. At the swing's hit point (OnWeaponSwingHitPoint, the
    moment vanilla would call Throw) a local player's throw aims at the point under
    the mouse on the player's floor, or MaxRange straight ahead on a joypad and for
    split-screen players 2-4 (vanilla's own rule: only player 1 has the mouse,
    ISPlace3DItemCursor). This client picks the bounces, starting rotation and spin
    and flies its own copy at once, so the throw shows without waiting for the
    server; the server flies the same path from the same numbers and ends it.

    Drawing: Render3DItem(item, square, x, y, z, rotation) from
    RenderOpaqueObjectsInWorld, as ISPlace3DItemCursor draws the item being placed
    (world coordinates). FBORenderCell.renderOpaqueObjectsEvent (42.21) fires it
    once a frame per player, but only while UIManager.getPickedTile() is set on a
    mouse player, so a flying item is not drawn for the moments the mouse is over a
    window. Every client draws every throw it is sent (throwableFly), and drops it
    on throwableEnd, or itself at the first wall or floor for items that go off on
    impact. Option ThrowableBallistics.
--]]

local Throwables = ZomboidFixesB42.Throwables

-- A shown flight nobody ended is dropped this long after its fuse.
local VISUAL_GRACE_SECONDS = 10

-- [key] = { flight, item }
local visuals = {}
local count = 0
-- [key] = time it was shown, so a throwableFly arriving after this client's own
-- copy already landed does not show it again.
local shown = {}
local lastPurge = 0
local clock = { carry = 0 }
-- Random start, so keys from before a reconnect are not reused.
local nextToken = ZombRand(1000000)

local function addVisual(key, itemType, params, throw)
    if shown[key] then return end
    local now = getTimestampMs()
    shown[key] = now
    if now - lastPurge > 60000 then
        lastPurge = now
        local old = {}
        for k, t in pairs(shown) do
            if now - t > 60000 then old[#old + 1] = k end
        end
        for _, k in ipairs(old) do shown[k] = nil end
    end
    local item = instanceItem(itemType)
    local flight = item and Throwables.newFlight(params, throw)
    if not flight then return end
    if count == 0 then
        clock.last = now
        clock.carry = 0
    end
    visuals[key] = { flight = flight, item = item }
    count = count + 1
end

function Throwables.endVisual(key)
    if not visuals[key] then return end
    visuals[key] = nil
    count = count - 1
end

local function aimPoint(player, weapon, z)
    local playerNum = player:getPlayerNum()
    if playerNum == 0 and (player:getJoypadBind() == -1 or wasMouseActiveMoreRecentlyThanJoypad()) then
        local mx, my = getMouseX(), getMouseY()
        return screenToIsoX(playerNum, mx, my, z), screenToIsoY(playerNum, mx, my, z)
    end
    local forward = player:getForwardDirection()
    local range = weapon:getMaxRange()
    return player:getX() + forward:getX() * range, player:getY() + forward:getY() * range
end

function Throwables.onThrow(character, weapon)
    if not instanceof(character, "IsoPlayer") or not character:isLocalPlayer() then return end

    local ox, oy, oz = Throwables.originFor(character)
    local dz = Throwables.floorOf(oz)
    local dx, dy = aimPoint(character, weapon, dz)
    local throw = {
        ox = ox, oy = oy, oz = oz,
        dx = dx, dy = dy, dz = dz,
        bounces = ZombRand(1, Throwables.MAX_BOUNCES + 1),
        rotation = ZombRand(360),
        spin = ZombRand(Throwables.SPIN_MIN, Throwables.SPIN_MAX + 1),
    }
    nextToken = nextToken + 1
    local key = string.format("%d:%d", character:getOnlineID(), nextToken)
    addVisual(key, weapon:getFullType(), Throwables.paramsFor(weapon), throw)

    if isClient() then
        sendClientCommand(character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_THROW, {
            item = weapon:getID(),
            token = nextToken,
            ox = ox, oy = oy, oz = oz,
            dx = dx, dy = dy,
            bounces = throw.bounces,
            rotation = throw.rotation,
            spin = throw.spin,
        })
    elseif Throwables.launch then
        Throwables.launch(character, weapon, throw, key)
    end
end

local function onTick()
    if count == 0 then return end
    local steps = Throwables.stepsDue(clock)
    if steps == 0 then return end
    local ended = {}
    for key, visual in pairs(visuals) do
        local f = visual.flight
        for _ = 1, steps do
            local status = Throwables.step(f)
            if status == "wall" or status == "impact"
                or f.age >= f.params.fuse + VISUAL_GRACE_SECONDS then
                ended[#ended + 1] = key
                break
            end
        end
    end
    for _, key in ipairs(ended) do Throwables.endVisual(key) end
end

local function onRender()
    if count == 0 then return end
    for _, visual in pairs(visuals) do
        local f = visual.flight
        local square = f.square
        Render3DItem(visual.item, square, square:getX() + f.x, square:getY() + f.y, square:getZ() + f.z, f.rotation)
    end
end

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or type(args) ~= "table" or type(args.key) ~= "string" then return end
    if command == ZomboidFixesB42.CMD_THROWABLE_FLY then
        local params = {
            maxDistance = tonumber(args.maxDistance) or 10,
            detonateOnImpact = args.detonateOnImpact == true,
            fuse = tonumber(args.fuse) or 0,
        }
        local throw = {
            ox = tonumber(args.ox), oy = tonumber(args.oy), oz = tonumber(args.oz),
            dx = tonumber(args.dx), dy = tonumber(args.dy),
            bounces = tonumber(args.bounces) or 1,
            rotation = tonumber(args.rotation) or 0,
            spin = tonumber(args.spin) or 0,
        }
        if not throw.ox or not throw.oy or not throw.oz or not throw.dx or not throw.dy
            or type(args.type) ~= "string" then return end
        throw.dz = Throwables.floorOf(throw.oz)
        addVisual(args.key, args.type, params, throw)
    elseif command == ZomboidFixesB42.CMD_THROWABLE_END then
        Throwables.endVisual(args.key)
    end
end

Events.OnTick.Add(onTick)
Events.RenderOpaqueObjectsInWorld.Add(onRender)
Events.OnServerCommand.Add(onServerCommand)
