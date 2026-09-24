--[[
    Zomboid Fixes B42.20 -- shared, body stats editor

    The debug menu's General Debuggers > Body panel (ISStatsAndBody) lets you drag
    every stat of your character -- hunger, unhappiness, calories, weight and so on.
    Multiplayer has a capability made for exactly this, CanModifyBodyStats, which
    admins and moderators hold, but its only use is that panel, and the panel only
    opens with the -debug launch flag. Even then it half works on a server:

      - The server owns every stat. NetworkPlayerManager sends each player their
        stats, nutrition, smoking timer and main body fields every second, and a
        client never simulates its own body at all (BodyDamage.Update returns
        straight away on a client). Anything set only on the client is put back
        within a second.
      - The panel only tells the server about the 24 CharacterStats
        (sendPlayerStat) and nutrition (sendPlayerNutrition). The eaten food timer,
        smoking timer, cold, overall health, the Fitness level and the tick boxes
        never leave the client.
      - It only ever edits getPlayer(). Another player's stats never reach an
        admin's client at all -- the client even resets remote players' bodies to
        full health every update -- so the Check Stats window cannot show them either.

    So the editor asks the server for the values and asks the server to change
    them. This file holds what both sides need: the list of fields, in the debug
    panel's order and with its ranges, and how to read and change each one on the
    authoritative copy of a player. The server uses it for multiplayer, and the
    client uses it directly in single player, where there is no server.

    Several stats are driven by something else every tick, so setting the stat
    alone would not stick. Those are changed at the source instead:

      - Fitness is recomputed from the Fitness skill level every tick
        (IsoGameCharacter.updateFitness), so the level is set, the same way the
        debug panel does it, and vanilla's LevelPerk handling then swaps the
        Unfit / Out of Shape / Fit / Athletic traits.
      - Wetness is pulled 90% of the way back to the average of the body parts'
        wetness every tick (BodyDamage.UpdateWetness), so the body parts are wet too.
      - Zombie infection is recomputed from the time since infection for an infected
        character, so the infection time is moved to match.

    Pain is recomputed from the body parts' pain every tick, and morale only moves
    while stressed; the debug panel says so, and so does this one.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local BodyStats = {}
ZomboidFixesB42.BodyStats = BodyStats

-- syncPlayerStats masks. Every stat: SyncPlayerStatsPacket only walks bits up to
-- the number of stats, so setting the rest is harmless. -1 sends the nutrition.
local ALL_STATS = 0x7FFFFFFF
local NUTRITION = -1

BodyStats.SYNC_STATS = "stats"
BodyStats.SYNC_NUTRITION = "nutrition"

-- Below this, Nutrition.setWeight clamps to 35 and damages the character, every
-- time it is called.
local MIN_WEIGHT = 35

local function stats(player)
    return player:getStats()
end

local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

--- The Fitness skill level for a Fitness stat value, as the debug panel works it out.
local function fitnessLevel(value)
    return clamp(math.floor((value + 1) * 5 + 0.5), 0, 10)
end

local function setFitness(player, value)
    local level = fitnessLevel(value)
    if player:getPerkLevel(Perks.Fitness) ~= level then
        -- setPerkLevelDebug and setXPToLevel rather than XP.AddXP, which does
        -- nothing while the character is asleep or, for Fitness, overweight or
        -- underweight.
        player:setPerkLevelDebug(Perks.Fitness, level)
        player:getXp():setXPToLevel(Perks.Fitness, level)
        -- What vanilla does for any change of level: XpUpdate.levelPerk swaps the
        -- Fitness traits to match it.
        triggerEvent("LevelPerk", player, Perks.Fitness, level, false)
    end
    stats(player):set(CharacterStat.FITNESS, level / 5 - 1)
end

local function setWetness(player, value)
    local parts = player:getBodyDamage():getBodyParts()
    for i = 0, parts:size() - 1 do
        parts:get(i):setWetness(value)
    end
    stats(player):set(CharacterStat.WETNESS, value)
end

local function setZombieInfection(player, value)
    local body = player:getBodyDamage()
    local duration = body:getInfectionMortalityDuration()
    -- BodyDamage.Update sets the stat to (hours survived - infection time) /
    -- mortality duration. The infection time cannot go below 0: GameTime.checkHours
    -- treats a negative time as "infected just now".
    if body:isInfected() and duration > 0 then
        local hours = player:getHoursSurvived()
        body:setInfectionTime(math.max(0, hours - (value / 100) * duration))
    end
    stats(player):set(CharacterStat.ZOMBIE_INFECTION, value)
end

local function setOverallHealth(player, value)
    -- The overall health is worked out from the body parts, so the parts are
    -- healed or hurt, as the debug panel does it.
    local body = player:getBodyDamage()
    local current = body:getOverallBodyHealth()
    if value < current then
        body:ReduceGeneralHealth(current - value)
    elseif value > current then
        body:AddGeneralHealth(value - current)
    end
    body:calculateOverallHealth()
end

local function setInfected(player, value)
    local body = player:getBodyDamage()
    if value then
        body:setInfected(true)
        return
    end
    -- Taking the tick away cures the infection, the same way a full heal does.
    -- Clearing only the flag would not last: BodyDamage.Update sets it again from
    -- any infected body part on the next tick.
    local parts = body:getBodyParts()
    for i = 0, parts:size() - 1 do
        parts:get(i):SetInfected(false)
    end
    body:setInfected(false)
    body:setInfectionTime(-1)
    body:setInfectionMortalityDuration(-1)
    stats(player):reset(CharacterStat.ZOMBIE_INFECTION)
end

local function setFakeInfected(player, value)
    local body = player:getBodyDamage()
    body:setIsFakeInfected(value)
    if not value then
        -- setIsFakeInfected only clears the first body part.
        local parts = body:getBodyParts()
        for i = 0, parts:size() - 1 do
            parts:get(i):SetFakeInfected(false)
        end
    end
end

local fields = nil

local function statField(key, statName, title, step)
    local stat = CharacterStat[statName]
    return {
        key = key,
        title = title,
        min = stat:getMinimumValue(),
        max = stat:getMaximumValue(),
        step = step or 0.01,
        sync = BodyStats.SYNC_STATS,
        get = function(player) return stats(player):get(stat) end,
        set = function(player, value) stats(player):set(stat, value) end,
    }
end

local function numberField(key, title, min, max, step, get, set, sync)
    return { key = key, title = title, min = min, max = max, step = step, get = get, set = set, sync = sync }
end

local function boolField(key, title, get, set, command, capability)
    return { key = key, title = title, bool = true, get = get, set = set, command = command, capability = capability }
end

local function build()
    local list = {}
    local function add(field) table.insert(list, field) end
    local function body(player) return player:getBodyDamage() end
    local function nutrition(player) return player:getNutrition() end

    -- The debug panel's rows, in its order and with its ranges and steps.
    add(statField("Hunger", "HUNGER", "IGUI_StatsAndBody_Hunger"))
    add(numberField("HealthFromFoodTimer", "IGUI_StatsAndBody_HealthFromFoodTimer", 0, 10000, 1,
        function(p) return body(p):getHealthFromFoodTimer() end,
        function(p, v) body(p):setHealthFromFoodTimer(v) end))
    add(statField("Thirst", "THIRST", "IGUI_StatsAndBody_Thirst"))
    add(statField("Fatigue", "FATIGUE", "IGUI_StatsAndBody_Fatigue"))
    add(statField("Endurance", "ENDURANCE", "IGUI_StatsAndBody_Endurance"))

    -- One Fitness level is 0.2 of the stat, so the slider moves a level at a time.
    local fitness = statField("Fitness", "FITNESS", "IGUI_StatsAndBody_Fitness", 0.2)
    fitness.set = setFitness
    add(fitness)

    add(statField("Intoxication", "INTOXICATION", "IGUI_StatsAndBody_Intoxication", 1))
    add(statField("Anger", "ANGER", "IGUI_StatsAndBody_Anger"))
    add(statField("Pain", "PAIN", "IGUI_StatsAndBody_Pain", 1))
    add(statField("Panic", "PANIC", "IGUI_StatsAndBody_Panic", 1))
    add(statField("Morale", "MORALE", "IGUI_StatsAndBody_Morale"))
    add(statField("Stress", "STRESS", "IGUI_StatsAndBody_Stress"))
    add(statField("NicotineWithdrawal", "NICOTINE_WITHDRAWAL", "IGUI_StatsAndBody_NicotineWithdrawal"))
    add(numberField("TimeSinceLastSmoke", "IGUI_StatsAndBody_TimeSinceLastSmoke", 0, 10, 0.01,
        function(p) return p:getTimeSinceLastSmoke() end,
        function(p, v) p:setTimeSinceLastSmoke(v) end))
    add(statField("Boredom", "BOREDOM", "IGUI_StatsAndBody_Boredom", 1))
    add(statField("Idleness", "IDLENESS", "IGUI_StatsAndBody_Idleness", 0.001))
    add(statField("Unhappiness", "UNHAPPINESS", "IGUI_StatsAndBody_Unhappiness", 1))
    add(statField("Sanity", "SANITY", "IGUI_StatsAndBody_Sanity"))
    add(statField("Discomfort", "DISCOMFORT", "IGUI_StatsAndBody_Discomfort", 1))

    local wetness = statField("Wetness", "WETNESS", "IGUI_StatsAndBody_Wetness", 1)
    wetness.set = setWetness
    add(wetness)

    add(statField("Temperature", "TEMPERATURE", "IGUI_StatsAndBody_Temperature", 0.1))
    add(numberField("ColdDamageStage", "IGUI_StatsAndBody_ColdDamageStage", 0, 1, 0.01,
        function(p) return body(p):getColdDamageStage() end,
        function(p, v) body(p):setColdDamageStage(v) end))
    add(numberField("OverallBodyHealth", "IGUI_StatsAndBody_OverallBodyHealth", 0, 100, 1,
        function(p) return body(p):getOverallBodyHealth() end,
        setOverallHealth))
    add(numberField("ColdStrength", "IGUI_StatsAndBody_ColdStrength", 0, 100, 1,
        function(p) return body(p):getColdStrength() end,
        function(p, v)
            body(p):setHasACold(v > 0)
            body(p):setColdStrength(v)
        end))
    add(statField("Sickness", "SICKNESS", "IGUI_StatsAndBody_Sickness"))

    local infection = statField("ZombieInfection", "ZOMBIE_INFECTION", "IGUI_StatsAndBody_ZombieInfection", 1)
    infection.set = setZombieInfection
    add(infection)

    add(statField("ZombieFever", "ZOMBIE_FEVER", "IGUI_StatsAndBody_ZombieFever", 1))
    add(statField("FoodSickness", "FOOD_SICKNESS", "IGUI_StatsAndBody_FoodSickness", 1))
    add(numberField("Carbohydrates", "Fluid_Prop_Carbohydrates", -500, 1000, 1,
        function(p) return nutrition(p):getCarbohydrates() end,
        function(p, v) nutrition(p):setCarbohydrates(v) end, BodyStats.SYNC_NUTRITION))
    add(numberField("Lipids", "Fluid_Prop_Lipids", -500, 1000, 1,
        function(p) return nutrition(p):getLipids() end,
        function(p, v) nutrition(p):setLipids(v) end, BodyStats.SYNC_NUTRITION))
    add(numberField("Proteins", "Fluid_Prop_Proteins", -500, 1000, 1,
        function(p) return nutrition(p):getProteins() end,
        function(p, v) nutrition(p):setProteins(v) end, BodyStats.SYNC_NUTRITION))
    add(numberField("Calories", "IGUI_StatsAndBody_Calories", -2200, 3700, 1,
        function(p) return nutrition(p):getCalories() end,
        function(p, v) nutrition(p):setCalories(v) end, BodyStats.SYNC_NUTRITION))
    add(numberField("Weight", "IGUI_StatsAndBody_Weight", MIN_WEIGHT, 130, 1,
        function(p) return nutrition(p):getWeight() end,
        function(p, v)
            nutrition(p):setWeight(v)
            -- Vanilla only re-checks the weight traits every 2000 nutrition
            -- updates; this makes Overweight, Obese and the rest follow at once.
            nutrition(p):applyTraitFromWeight()
        end, BodyStats.SYNC_NUTRITION))
    add(statField("Poison", "POISON", "IGUI_StatsAndBody_Poison", 1))

    add(boolField("IsInfected", "IGUI_StatsAndBody_IsInfected",
        function(p) return body(p):isInfected() end, setInfected))
    add(boolField("IsFakeInfected", "IGUI_StatsAndBody_IsFakeInfected",
        function(p) return body(p):isIsFakeInfected() end, setFakeInfected))
    add(boolField("IsOnFire", "IGUI_StatsAndBody_IsOnFire",
        function(p) return body(p):isIsOnFire() end,
        function(p, v) body(p):setIsOnFire(v) end))
    -- God mode and invisibility go out to every client in ExtraInfoPacket, which
    -- only the server's own commands can send for another player, so in
    -- multiplayer these two use those commands. Ghost mode is not listed: in this
    -- build IsoPlayer.setGhostMode just calls setInvisible.
    add(boolField("GodMod", "IGUI_StatsAndBody_GodMod",
        function(p) return p:isGodMod() end,
        function(p, v) p:setGodMod(v) end,
        "/godmodplayer", "ToggleGodModEveryone"))
    add(boolField("Invisible", "IGUI_StatsAndBody_Invisible",
        function(p) return p:isInvisible() end,
        function(p, v) p:setInvisible(v) end,
        "/invisibleplayer", "ToggleInvisibleEveryone"))

    return list
end

--- Every editable field, in display order.
function BodyStats.getFields()
    if not fields then
        fields = build()
        BodyStats.byKey = {}
        for _, field in ipairs(fields) do
            BodyStats.byKey[field.key] = field
        end
    end
    return fields
end

function BodyStats.getField(key)
    BodyStats.getFields()
    return type(key) == "string" and BodyStats.byKey[key] or nil
end

--- Whether an admin may edit this player's body. Mirrors ISPlayerStatsUI:canModifyThis:
-- nobody edits a player whose role ranks above their own.
function BodyStats.canEdit(admin, target)
    if not admin or not target then return false end
    if not isClient() and not isServer() then return true end
    local adminRole = admin:getRole()
    local targetRole = target:getRole()
    if not adminRole or not adminRole:hasCapability(Capability.CanModifyBodyStats) then return false end
    if targetRole and targetRole:getPosition() > adminRole:getPosition() then return false end
    return true
end

--- Every field's current value, as a table keyed by field key.
function BodyStats.read(player)
    local values = {}
    for _, field in ipairs(BodyStats.getFields()) do
        local ok, value = pcall(field.get, player)
        if ok and value ~= nil then
            if field.bool then
                values[field.key] = value == true
            else
                values[field.key] = tonumber(value)
            end
        end
    end
    return values
end

--- Change one field on the authoritative copy of a player. The value is checked
-- and clamped here, because on a server it comes from a client.
-- Returns the field when it was changed, or nil.
function BodyStats.apply(player, key, value)
    local field = BodyStats.getField(key)
    if not field or not player then return nil end

    if field.bool then
        if type(value) ~= "boolean" then return nil end
    else
        value = tonumber(value)
        -- value ~= value is NaN.
        if not value or value ~= value then return nil end
        value = clamp(value, field.min, field.max)
    end

    field.set(player, value)
    return field
end

--- Send what apply changed to the player it belongs to straight away, instead of
-- waiting up to a second for the regular sync. Does nothing outside a server.
-- Everything else a field can change (the body, the smoking timer, the Fitness
-- level and traits) reaches the player on the regular sync: every half second for
-- body part health, every second for the rest.
function BodyStats.sync(player, changed)
    if not isServer() or not player:isExistInTheWorld() then return end
    if changed[BodyStats.SYNC_STATS] then
        syncPlayerStats(player, ALL_STATS)
    end
    if changed[BodyStats.SYNC_NUTRITION] then
        syncPlayerStats(player, NUTRITION)
    end
end
