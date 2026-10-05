--[[
    Zomboid Fixes B42.20 -- client, Full Bright admin power

    Vanilla's Always Day admin power only lights the outdoors: ClimateManager
    getDayLightStrength / getAmbient / getNightStrength return day values while the
    local player has isAlwaysDayCheat, and RenderSettings feeds that ambient to the
    native lighting (LightingJNI.stateEndFrame). Indoors the native lighting only
    lights a square from windows, room lights (IsoRoomLight: the room's switch on and
    power) and light sources, so rooms stay dark day and night.

    What does not work from Lua: FBORenderChunk.NoLighting and ForceSkyLightLevel are
    debug-only options (BooleanDebugOption.getValue returns the default without
    -debug); IsoRoomLight is not exposed and follows the room's switch and power;
    per-square lighting (square:setVertLight / getLightInfo) is overwritten by the
    native update and the chunk renders are cached (FBORenderLevels).

    What does: IsoLightSource (exposed) added with getCell():addLamppost(light).
    LightingJNI.checkLights sends each one to the native lighting (addLight: radius
    capped at 20, colour r * 2 clamped to 1, falloff (1 - d / radius)^2, blocked by
    walls) and drops it from the cell's list once it is outside every player's loaded
    area (isInBounds); removeLamppost(light) sets its life to 0 and it is dropped on
    the next update. Lights live on this client only, nothing is sent.

    So Full Bright turns Always Day on for the outdoors and puts a white light every
    few tiles (sandbox AdminFullBrightSpacing) through each rectangle of every room
    (RoomDef rects, from IsoMetaGrid.getRoomsIntersecting) within RANGE tiles of the
    player, on squares that are loaded, each reaching AdminFullBrightRadius tiles. The
    native lighting lights each square on its own, so a short reach shows as steps
    between neighbouring squares (one half of a two-tile table darker than the other);
    a longer reach or closer lights even it out. The set is rebuilt when the player has
    moved MOVE_TILES or changed floor, and every REFRESH_MS, which also puts back
    lights the engine dropped and follows a change of either option.
    Always Day keeps its own tick: while Full Bright is on, the Always Day option
    reads and saves the admin's own choice, and that choice is put back when Full
    Bright goes off. In multiplayer Full Bright is off after a restart; in single
    player vanilla saves every Admin Powers option to CheatPanel.ini and sets it again
    at game start, this one included.

    Side effects, as with Always Day: the lit squares count as lit for this client's
    zombies looking at this admin (IsoZombie.updateVisionRadius) and for reading.

    Gate: the Admin Powers rule (single player: -debug; multiplayer: an admin power
    role with Capability.ClimateManager, Always Day's capability), checked every tick.
    With the sandbox option off, the option is left out of the Admin Powers window
    (ISAdminPowerUI adds every OptionList entry the role allows, so its addOption* are
    wrapped) and the hotbar greys its toggle out (option.zfixEnabled).
    Loads before ZomboidFixesB42_AdminHotbarActions.lua, which makes a hotbar toggle
    of every Admin Powers option it finds.
--]]

require "ISUI/AdminPanel/ISAdminPowerUI"

local OPTION_ID = "ZomboidFixesB42_FullBright"
-- How far from the player, in tiles, rooms are lit.
local RANGE = 45
-- Tiles between two lights in a room, and each light's radius in tiles (the engine
-- caps it at 20), when the sandbox options are missing. Walls stop each light at its
-- room, so the cost is mostly the number of lights: 8 gives most house rooms one, and
-- the full radius keeps that one light's far corners lit.
local DEFAULT_SPACING = 8
local DEFAULT_RADIUS = 20
local MAX_RADIUS = 20
-- The lights are rebuilt after this many tiles of movement...
local MOVE_TILES = 4
-- ...or this often.
local REFRESH_MS = 3000

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.AdminFullBright == true
end

local function intOption(name, default, min, max)
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    local value = vars and tonumber(vars[name])
    if not value then return default end
    return math.max(min, math.min(max, math.floor(value)))
end

local function spacing()
    return intOption("AdminFullBrightSpacing", DEFAULT_SPACING, 1, 20)
end

local function radius()
    return intOption("AdminFullBrightRadius", DEFAULT_RADIUS, 1, MAX_RADIUS)
end

local function isAllowed(player)
    if not player or player:isDead() then return false end
    if isDebugEnabled() then return true end
    if not isClient() then return false end
    local role = player:getRole()
    return role ~= nil and role:hasAdminPower() and role:hasCapability(Capability.ClimateManager)
end

local active = false
-- The admin's own Always Day setting while Full Bright holds it on.
local ownAlwaysDay = false
-- ["x,y,z"] = IsoLightSource
local lights = {}
-- The cell the lights were added to, and their radius.
local lightsCell = nil
local lightsRadius = nil
local lastX, lastY, lastZ, lastRefresh = nil, nil, nil, 0

local function clearLights()
    local cell = getCell()
    if cell and cell == lightsCell then
        for _, light in pairs(lights) do
            cell:removeLamppost(light)
        end
    end
    lights = {}
    lastX = nil
end

local function refresh(player)
    local cell = getCell()
    if not cell then return end
    -- Leaving a game and starting another keeps this file's state, not the old cell.
    if cell ~= lightsCell then
        lights = {}
        lightsCell = cell
    end
    -- A light's radius is fixed once added, so a new radius means new lights.
    local r = radius()
    if r ~= lightsRadius then
        for _, light in pairs(lights) do
            cell:removeLamppost(light)
        end
        lights = {}
        lightsRadius = r
    end
    local step = spacing()
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    lastX, lastY, lastZ, lastRefresh = px, py, pz, getTimestampMs()

    local rooms = ArrayList.new()
    getWorld():getMetaGrid():getRoomsIntersecting(px - RANGE, py - RANGE, RANGE * 2, RANGE * 2, rooms)
    local wanted = {}
    for i = 0, rooms:size() - 1 do
        local room = rooms:get(i)
        local z = room:getZ()
        local rects = room:getRects()
        for j = 0, rects:size() - 1 do
            local rect = rects:get(j)
            local rx, ry, w, h = rect:getX(), rect:getY(), rect:getW(), rect:getH()
            local nx = math.max(1, math.ceil(w / step))
            local ny = math.max(1, math.ceil(h / step))
            for ix = 0, nx - 1 do
                local x = rx + math.floor((ix + 0.5) * w / nx)
                for iy = 0, ny - 1 do
                    local y = ry + math.floor((iy + 0.5) * h / ny)
                    -- An unloaded square's light would be dropped at once and added again.
                    if cell:getGridSquare(x, y, z) then
                        wanted[x .. "," .. y .. "," .. z] = { x, y, z }
                    end
                end
            end
        end
    end

    local gone = {}
    for key, light in pairs(lights) do
        if not wanted[key] then gone[#gone + 1] = key end
    end
    for _, key in ipairs(gone) do
        cell:removeLamppost(lights[key])
        lights[key] = nil
    end

    local list = cell:getLamppostPositions()
    for key, pos in pairs(wanted) do
        local light = lights[key]
        if not light or not list:contains(light) then
            light = IsoLightSource.new(pos[1], pos[2], pos[3], 1, 1, 1, r)
            cell:addLamppost(light)
            lights[key] = light
        end
    end
end

local function setActive(player, on)
    if on == active then return end
    active = on
    if on then
        ownAlwaysDay = player:isAlwaysDayCheat()
        player:setAlwaysDayCheat(true)
        lastX = nil
    else
        clearLights()
        if player then
            player:setAlwaysDayCheat(ownAlwaysDay)
            if isClient() then sendPlayerExtraInfo(player) end
        end
    end
end

local option = ISAdminPowerUI.AddOption(OPTION_ID, "right", Capability.ClimateManager,
    function(self)
        return active
    end,
    function(self, selected)
        local player = self.player or getPlayer()
        if selected and not (isEnabled() and isAllowed(player)) then return end
        setActive(player, selected == true)
    end
)

if option then
    option.zfixEnabled = isEnabled

    -- The window is built from OptionList whenever it opens; the sandbox option is
    -- only known in game, so it is left out there rather than never registered.
    for _, name in ipairs({ "addOptionLeft", "addOptionRight" }) do
        local vanilla = ISAdminPowerUI[name]
        ISAdminPowerUI[name] = function(self, opt, ...)
            if opt == option and not isEnabled() then return end
            return vanilla(self, opt, ...)
        end
    end
end

-- While Full Bright holds Always Day on, the Always Day option shows and keeps the
-- admin's own setting.
local alwaysDay = ISAdminPowerUI.OptionById and ISAdminPowerUI.OptionById.AlwaysDay
if alwaysDay and option then
    local vanillaGet, vanillaSet = alwaysDay.getValue, alwaysDay.setValue
    alwaysDay.getValue = function(self)
        if active then return ownAlwaysDay end
        return vanillaGet(self)
    end
    alwaysDay.setValue = function(self, selected)
        if active then
            ownAlwaysDay = selected == true
            return vanillaSet(self, true)
        end
        return vanillaSet(self, selected)
    end
end

local function onTick()
    if not active then return end
    local player = getPlayer()
    if not isEnabled() or not isAllowed(player) then
        setActive(player, false)
        return
    end
    -- A respawn, or the server's copy of the flags, can turn it off underneath.
    if not player:isAlwaysDayCheat() then player:setAlwaysDayCheat(true) end
    local x, y, z = player:getX(), player:getY(), math.floor(player:getZ())
    if lastX == nil or z ~= lastZ or math.abs(x - lastX) >= MOVE_TILES or math.abs(y - lastY) >= MOVE_TILES
            or getTimestampMs() - lastRefresh >= REFRESH_MS then
        refresh(player)
    end
end

Events.OnTick.Add(onTick)
