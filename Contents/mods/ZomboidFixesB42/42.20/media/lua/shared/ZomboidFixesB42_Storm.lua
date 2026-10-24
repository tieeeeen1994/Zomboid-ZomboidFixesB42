--[[
    Zomboid Fixes B42.21 -- shared, storm controls

    What the Storm tab of the admin Climate Control window can ask for, and the
    limits the server holds every request to. The client builds its controls from
    these tables and the server file checks against them, so the two cannot drift
    apart. The server file explains how vanilla makes a storm and what this
    changes.

    Directions are where the storm comes from on the world map, north up (world -y,
    IsoDirections N = (0, -1)). A storm's thunder clouds cross the map along the
    weather front's angle, in degrees: ThunderStorm.ThunderCloud.setCenter moves a
    cloud from centre - d * (cos a, sin a) to centre + d * (cos a, sin a) in world
    x and y. So a storm from the west travels towards +x, angle 0, and one from the
    north towards +y, angle 90.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local Storm = {}
ZomboidFixesB42.Storm = Storm

-- Storm types: the WeatherPeriod stage each one is (STAGE_STORM,
-- STAGE_TROPICAL_STORM, STAGE_BLIZZARD), in the order the window lists them.
Storm.TYPES = {
    { id = "storm", stage = 3, textKey = "IGUI_ZomboidFixesB42_Storm_TypeStorm" },
    { id = "tropical", stage = 8, textKey = "IGUI_ZomboidFixesB42_Storm_TypeTropical" },
    { id = "blizzard", stage = 7, textKey = "IGUI_ZomboidFixesB42_Storm_TypeBlizzard" },
}

-- Where the storm comes from, and the front angle (the way it travels) for it.
Storm.DIRECTIONS = {
    { id = "random", textKey = "IGUI_ZomboidFixesB42_Storm_FromRandom" },
    { id = "N", angle = 90, textKey = "IGUI_ZomboidFixesB42_Storm_FromN" },
    { id = "NE", angle = 135, textKey = "IGUI_ZomboidFixesB42_Storm_FromNE" },
    { id = "E", angle = 180, textKey = "IGUI_ZomboidFixesB42_Storm_FromE" },
    { id = "SE", angle = 225, textKey = "IGUI_ZomboidFixesB42_Storm_FromSE" },
    { id = "S", angle = 270, textKey = "IGUI_ZomboidFixesB42_Storm_FromS" },
    { id = "SW", angle = 315, textKey = "IGUI_ZomboidFixesB42_Storm_FromSW" },
    { id = "W", angle = 0, textKey = "IGUI_ZomboidFixesB42_Storm_FromW" },
    { id = "NW", angle = 45, textKey = "IGUI_ZomboidFixesB42_Storm_FromNW" },
}

-- What the thunder clouds pass over. "player" comes with a username.
Storm.TARGETS = { randomPlayer = true, me = true, player = true, anywhere = true }

-- Limits, and the values the window starts with. Hours are the storm stage
-- alone; the game adds an hour of build-up before it and an hour of clearing
-- after it, as for vanilla's Trigger Storm.
Storm.HOURS_MIN, Storm.HOURS_MAX, Storm.HOURS_DEFAULT = 1, 240, 6
-- Front strength. Vanilla's Trigger buttons always use 0.95; weather periods
-- start only from 0.1 up (WeatherPeriod.startInit).
Storm.STRENGTH_MIN, Storm.STRENGTH_MAX, Storm.STRENGTH_DEFAULT = 0.1, 1, 0.95
-- ThunderStorm keeps three clouds at most.
Storm.CLOUDS_MIN, Storm.CLOUDS_MAX, Storm.CLOUDS_DEFAULT = 1, 3, 2
-- Cloud radius in tiles (ThunderStorm caps it at 20000). Vanilla: 8000 x
-- strength, 15000 for a tropical storm. Strikes land within half of it.
Storm.WIDTH_MIN, Storm.WIDTH_MAX, Storm.WIDTH_DEFAULT = 500, 20000, 8000
-- Percentages: how often a cloud makes an event, and how many of those are
-- lightning (flash and thunder) rather than a distant rumble.
Storm.FREQUENCY_DEFAULT = 95
Storm.LIGHTNING_DEFAULT = 60
Storm.WIND_KPH_DEFAULT = 60

function Storm.typeById(id)
    for _, def in ipairs(Storm.TYPES) do
        if def.id == id then return def end
    end
    return nil
end

function Storm.directionById(id)
    for _, def in ipairs(Storm.DIRECTIONS) do
        if def.id == id then return def end
    end
    return nil
end
