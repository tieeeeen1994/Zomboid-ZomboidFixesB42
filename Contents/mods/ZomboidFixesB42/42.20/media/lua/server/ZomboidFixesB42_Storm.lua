--[[
    Zomboid Fixes B42.21 -- server, storm controls

    The Climate Control window's Weather tab (ISAdmPanelWeather) has Trigger Storm,
    Trigger Tropical Storm and Trigger Blizzard, with a duration slider and
    nothing else. On a client they send a ClimateManager packet (type 7), and the
    server runs ClimateManager.triggerCustomWeatherStage(stage, duration), which
    builds a weather front from a fresh AirFront: strength 0.95, warm front, and a
    wind angle that AirFront.reset() leaves at 0. WeatherPeriod.createSingleStage
    then makes three stages: START (1 hour), the storm stage, CLEARING (1 hour).

    How a storm plays out (WeatherPeriod.updateCurrentStage, ThunderStorm):
      - When a STORM or TROPICAL_STORM stage starts, it starts its thunder clouds
        once (hasStartedCloud): 1 or 2 clouds (Rand.Next(1, 3)), radius 8000 x
        strength, 60% x strength of events with lightning; the first cloud passes
        over a random online player only when the strength is above 0.7, the
        others over random spots on the map. A tropical storm makes one cloud,
        radius 15000, 80% lightning, strength 1. A blizzard makes none.
      - Each cloud crosses the whole map along the front's angle (setCenter: from
        the map's half diagonal plus 1500-7500 tiles behind its centre to as far
        ahead) during the stage, so it is over its centre about halfway through.
        Every few seconds it makes a thunder event within half its radius:
        Rand(3.5 - 3 x s, 24 - 20 x s) real seconds at 1x apart, s being the
        cloud's strength, and a share of them (the thunder ratio) are lightning
        with a flash and thunder, the rest a distant rumble. Events only exist
        on the server and reach clients as ClimateManager packets (type 2).
      - Wind speed and direction are overrides set every climate tick: during a
        storm the wind angle is 0.7 x noise x (+1 or -1 from the front's angle),
        so it only loosely follows the storm.
    So every admin storm comes from the same side (angle 0, plus or minus 10
    degrees per cloud: it always travels west to east), at the same strength, and
    whether its lightning comes anywhere near a player is left to chance. Clouds
    are not saved either: after a restart in the middle of a storm stage the rain
    goes on with no thunder at all (hasStartedCloud is saved as true).

    What this does instead, for the Storm tab (client file):
      - WeatherPeriod.startCreateModdedPeriod(warmFront, strength, angle) +
        createAndAddStage + endCreateModdedPeriod build the same three stages with
        the chosen angle, strength, front and length. endInit sends the period
        to every client (type 1); the climate values follow with the server's
        regular update (type 0, every ten game minutes).
      - Events.OnClimateTick fires right after WeatherPeriod.update, before the
        climate values are calculated and before ThunderStorm.update. In the tick
        where the storm stage starts, the clouds it just started (none has made
        an event yet) are stopped and replaced (ThunderStorm.startThunderCloud,
        8 arguments: the 7-argument one calls itself forever) with the chosen
        count, radius, strength and thunder ratio; ThunderCloud.setCenter puts
        each one on the chosen player or the admin. Blizzards get clouds only when
        a count is chosen.
      - In the same event, while the storm stage runs, the wind speed and angle
        overrides are given other targets with the interpolation the stage chose
        (so they still build up and die down with the storm). Admin values from
        the Climate tab still win over them (ClimateFloat.calculate).
        ClimateManager.getWindAngleDegrees maps the wind angle value v to
        degrees: v > 0 gives 45 + 180 v, -0.25 < v <= 0 gives 45 + 45 v,
        v <= -0.25 gives 360 - 180 (|v| - 0.25). The angle wanted is the front's
        angle, which is what the weather forecast and the radio already call the
        wind's direction during a weather period (ClimateForecaster reads
        WeatherPeriod.getWindAngleDegrees).
      - The storm's settings are kept in global mod data, so the clouds come back
        after a server restart (started for what is left of the stage).
    The storm is ours while the running period's first stage starts at the hour
    it had when it was made; once the weather is stopped or replaced, it is
    forgotten.

    Only roles with the ClimateManager capability (the Climate Control window's
    own), admins and moderators by default. Each storm is written to the admin
    log. In single player the window calls Storm.start directly (debug mode only,
    like the window itself).
--]]

if isClient() then return end

-- shared/ZomboidFixesB42_Storm.lua has loaded already (shared loads before
-- server); a require of that name could find this file instead.
ZomboidFixesB42 = ZomboidFixesB42 or {}
local Storm = ZomboidFixesB42.Storm

local MOD_DATA_KEY = "ZomboidFixesB42_Storm"

-- ClimateManager float ids (ISAdmPanelClimate.lua has the full list).
local FLOAT_WIND_INTENSITY = 6
local FLOAT_WIND_ANGLE_INTENSITY = 7

-- WeatherPeriod stage ids.
local STAGE_START = 0
local STAGE_CLEARING = 4
local STAGE_BLIZZARD = 7
local STAGE_TROPICAL_STORM = 8

-- The storm this file made, as saved in global mod data, or nil.
local storm = nil
-- The world hour the storm stage started at, once its clouds have been started
-- in this session.
local cloudsStartedFor = nil

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.StormControls == true
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

--- A number from a client argument, clamped, or nil when it is not one.
local function numberArg(value, low, high)
    value = tonumber(value)
    if value == nil or value ~= value then return nil end
    return clamp(value, low, high)
end

local function remember(record)
    storm = record
    cloudsStartedFor = nil
    ModData.getOrCreate(MOD_DATA_KEY).storm = record
end

local function forget()
    if storm == nil then return end
    remember(nil)
end

--- The world hour the period's first stage started at, or nil.
local function firstStageStart(period)
    local stages = period:getWeatherStages()
    if stages:size() == 0 then return nil end
    return stages:get(0):getStageStart()
end

--- The wind angle value for which ClimateManager.getWindAngleDegrees() gives
-- these degrees. Values between -0.25 and 0 only reach 33.75 to 45 degrees (and
-- -0.25 itself is 360), so 0 to 33.75 snaps to the nearer end.
local function windAngleValueFor(degrees)
    degrees = degrees % 360
    if degrees > 45 and degrees <= 225 then return (degrees - 45) / 180 end
    if degrees > 225 then return -(0.25 + (360 - degrees) / 180) end
    if degrees > 33.75 then return (degrees - 45) / 45 end
    if degrees < 16.875 then return -0.25 end
    return -0.2499
end

-- Players ------------------------------------------------------------------------

local function eachPlayer(fn)
    if isServer() then
        local players = getOnlinePlayers()
        for i = 0, players:size() - 1 do
            fn(players:get(i))
        end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            if player then fn(player) end
        end
    end
end

local function findPlayer(username)
    local found = nil
    eachPlayer(function(player)
        if not found and player:getUsername() == username and player:getCurrentSquare() then
            found = player
        end
    end)
    return found
end

local function randomPlayer()
    local players = {}
    eachPlayer(function(player)
        if player:getCurrentSquare() and not player:isDead() then
            table.insert(players, player)
        end
    end)
    if #players == 0 then return nil end
    return players[ZombRand(#players) + 1]
end

--- Where a cloud should pass over, or nil for a random spot on the map.
local function cloudCentre(record)
    if record.over == "anywhere" then return nil end

    local player = nil
    if record.username then player = findPlayer(record.username) end
    -- Someone who went offline: a random player instead, as vanilla does.
    if not player then player = randomPlayer() end
    if not player then return nil end
    return math.floor(player:getX()), math.floor(player:getY())
end

-- Clouds and wind ----------------------------------------------------------------

local function startClouds(climate, record, stage)
    local hours = stage:getStageEnd() - getGameTime():getWorldAgeHours()
    if hours <= 0 then return end

    local tropical = record.stage == STAGE_TROPICAL_STORM
    local count = record.clouds
    if not count then
        if record.stage == STAGE_BLIZZARD then
            count = 0
        elseif tropical then
            count = 1
        else
            count = ZombRand(2) + 1
        end
    end
    local radius = record.width or (tropical and 15000 or 8000 * record.strength)
    local strength = record.frequency and record.frequency / 100 or (tropical and 1 or record.strength)
    local ratio = record.lightning and record.lightning / 100 or (tropical and 0.8 or 0.6 * record.strength)

    local thunder = climate:getThunderStorm()
    thunder:stopAllClouds()
    for _ = 1, count do
        local cloud = thunder:startThunderCloud(strength, record.angle, radius, strength, ratio, hours, false, 0)
        if cloud then
            local x, y = cloudCentre(record)
            if x then cloud:setCenter(x, y, record.angle) end
        end
    end
end

--- Gives the stage's wind overrides other targets, keeping how far the stage
-- has blended them in.
local function holdWind(climate, record)
    if record.windFromStorm then
        local angle = climate:getClimateFloat(FLOAT_WIND_ANGLE_INTENSITY)
        if angle:isEnableOverride() then
            angle:setOverride(windAngleValueFor(record.angle), angle:getOverrideInterpolate())
        end
    end
    if record.windKph then
        local wind = climate:getClimateFloat(FLOAT_WIND_INTENSITY)
        if wind:isEnableOverride() then
            wind:setOverride(record.windKph / climate:getMaxWindspeedKph(), wind:getOverrideInterpolate())
        end
    end
end

local function onClimateTick(climate)
    if storm == nil then return end

    local period = climate:getWeatherPeriod()
    if not isEnabled() or not period or not period:isRunning() or firstStageStart(period) ~= storm.startHour then
        return forget()
    end

    local stage = period:getCurrentStage()
    if not stage or stage:getStageID() ~= storm.stage then return end

    local stageStart = stage:getStageStart()
    if cloudsStartedFor ~= stageStart then
        cloudsStartedFor = stageStart
        startClouds(climate, storm, stage)
    end
    holdWind(climate, storm)
end

local function onInitGlobalModData()
    storm = ModData.getOrCreate(MOD_DATA_KEY).storm
    cloudsStartedFor = nil
end

-- Starting a storm ----------------------------------------------------------------

--- Starts a storm for this player, with the Storm tab's settings. Returns
-- "started", "failed" (the game would not start a weather period) or "bad".
function Storm.start(player, args)
    if type(args) ~= "table" then return "bad" end
    local def = Storm.typeById(args.type)
    if not def then return "bad" end

    local climate = getClimateManager()
    local direction = Storm.directionById(args.from) or Storm.directionById("random")
    local angle = direction.angle or ZombRand(360)
    local hours = math.floor(numberArg(args.hours, Storm.HOURS_MIN, Storm.HOURS_MAX) or Storm.HOURS_DEFAULT)
    local strength = numberArg(args.strength, Storm.STRENGTH_MIN, Storm.STRENGTH_MAX) or Storm.STRENGTH_DEFAULT

    local over = Storm.TARGETS[args.over] and args.over or "randomPlayer"
    local username = nil
    if over == "me" then
        username = player:getUsername()
    elseif over == "player" then
        username = type(args.username) == "string" and args.username or nil
        if not username then over = "randomPlayer" end
    end

    local clouds = numberArg(args.clouds, Storm.CLOUDS_MIN, Storm.CLOUDS_MAX)
    local record = {
        stage = def.stage,
        angle = angle,
        strength = strength,
        over = over,
        username = username,
        clouds = clouds and math.floor(clouds),
        width = numberArg(args.width, Storm.WIDTH_MIN, Storm.WIDTH_MAX),
        frequency = numberArg(args.frequency, 0, 100),
        lightning = numberArg(args.lightning, 0, 100),
        windKph = numberArg(args.windKph, 0, climate:getMaxWindspeedKph()),
        windFromStorm = args.windFromStorm == true,
    }

    if isServer() then
        climate:transmitServerStopWeather()
    else
        climate:stopWeatherAndThunder()
    end
    forget()

    local period = climate:getWeatherPeriod()
    if not period:startCreateModdedPeriod(args.coldFront ~= true, strength, angle) then return "failed" end
    period:createAndAddStage(STAGE_START, 1)
    period:createAndAddStage(def.stage, hours)
    period:createAndAddStage(STAGE_CLEARING, 1)
    -- createSingleStage does the same for these two; a storm keeps the last colour.
    if def.stage == STAGE_TROPICAL_STORM then
        period:setCloudColor(period:getCloudColorTropical())
    elseif def.stage == STAGE_BLIZZARD then
        period:setCloudColor(period:getCloudColorBlizzard())
    end
    if not period:endCreateModdedPeriod() then return "failed" end

    record.startHour = firstStageStart(period)
    remember(record)

    local text = string.format("%s started a %s from %s (%d degrees) for %d hours, strength %.2f, over %s",
        tostring(player:getUsername()), def.id, direction.id, angle, hours, strength, username or over)
    print("[ZomboidFixesB42] " .. text)
    if isServer() then writeLog("admin", text) end
    return "started"
end

-- Commands -------------------------------------------------------------------------

local function reply(player, result)
    sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_STORM_RESULT, { result = result })
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_STORM then return end
    if not player or not isServer() then return end

    if not isEnabled() then
        return reply(player, "disabled")
    end

    local role = player:getRole()
    if not role or not role:hasCapability(Capability.ClimateManager) then
        print("[ZomboidFixesB42] " .. tostring(player:getUsername()) .. " may not start storms (no ClimateManager capability)")
        return reply(player, "denied")
    end

    reply(player, Storm.start(player, args))
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnClimateTick.Add(onClimateTick)
Events.OnInitGlobalModData.Add(onInitGlobalModData)
