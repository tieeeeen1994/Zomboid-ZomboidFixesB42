--[[
    Zomboid Fixes B42.20 -- shared, body stats editor

    The debug menu's General Debuggers > Body panel (ISStatsAndBody) lets you drag
    every stat of your character -- hunger, unhappiness, calories, weight and so on.
    Multiplayer has a capability made for exactly this, CanModifyBodyStats, which
    admins and moderators hold (its tooltip says "Use the Body section of General
    Debuggers in the Debug Menu panel"), but its only use is that panel, and the
    panel only opens with the -debug launch flag. Even then it half works on a
    server:

      - The server owns every stat. For every online player NetworkPlayerManager
        sends the owning client, and only that client:

          every 0.5 s  PlayerHealth    each body part's health
          every 1 s    PlayerStats     every CharacterStat (Stats.save), the
                                       nutrition, the smoking timer and
                                       BodyDamage.saveMainFields: cold, food
                                       healing timer, pain and cold reduction,
                                       infection time and mortality, cold
                                       damage stage
                       PlayerEffects   sleeping pill, beta blocker,
                                       antidepressant and painkiller effects
                       PlayerXp        traits, XP and perk levels
          every 2 s    PlayerDamage    max weight, corpse sickness rate and the
                                       whole BodyDamage, every body part with its
                                       infection flags, wetness and health
                       PlayerInjuries  wounds

        A client never simulates its own body (BodyDamage.Update returns straight
        away on a client for its own living player). So anything set only on the
        client is put back within a second, and anything the server sets --
        including traits and skill levels -- reaches the player within a second by
        itself. BodyDamage.isInfected, isIsFakeInfected and isIsOnFire are in no
        packet at all; they only exist on the server.
      - The panel only tells the server about the 24 CharacterStats
        (sendPlayerStat) and nutrition (sendPlayerNutrition). Both are client
        only and do nothing unless the local role has CanModifyBodyStats. They send
        a SyncPlayerStatsPacket, which the server loads into the player it names --
        not necessarily the sender -- without answering or passing it on. The
        eaten food timer, smoking timer, cold, overall health, the Fitness level and
        the tick boxes never leave the client.
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
    while stressed; the debug panel says so, and so does this one. Pain is set to
    the body parts' pain minus the painkiller reduction whenever it is above that,
    and only creeps up slowly when below (BodyDamage.Update).

    Others stick, some only for a while:

      - Sickness: nothing writes it any more; it is only read by the
        thermoregulator and the moodles.
      - Temperature: the thermoregulator lerps the core temperature halfway to the
        stat every update and writes the stat back
        (Thermoregulator.updateHeatDeltas), so it gets there and then drifts
        naturally.
      - Discomfort is lerped slowly towards a target from clothing, bed and
        moodles, so it drifts back.
      - Fatigue is reset on the server when sleep is not allowed or not needed
        (IsoGameCharacter.calculateStats).
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local BodyStats = {}
ZomboidFixesB42.BodyStats = BodyStats

-- syncPlayerStats masks. syncPlayerStats(player, mask) is server only and sends a
-- SyncPlayerStatsPacket to that player, once they exist in the world. Each bit is
-- a stat, in CharacterStat.ORDERED_STATS order: Anger 0, Boredom, Discomfort,
-- Endurance, Fatigue, Fitness, FoodSickness, Hunger, Idleness, Intoxication,
-- Morale 10, NicotineWithdrawal, Pain, Panic, Poison, Sanity, Sickness, Stress,
-- Temperature, Thirst, Unhappiness 20, Wetness, ZombieFever, ZombieInfection 23.
-- Every stat: the packet only walks bits up to the number of stats, so setting the
-- rest is harmless. -1 sends the whole nutrition instead.
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
    -- BodyPart.setWetness clamps to 0..100, the same range as the stat.
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
    -- healed or hurt, as the debug panel does it. AddGeneralHealth spreads the
    -- amount over the damaged parts only, ReduceGeneralHealth over all of them.
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
    -- setTimeSinceLastSmoke clamps to 0..10 itself.
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
    -- Nutrition's setters clamp to these same ranges.
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
    -- Only the flag the game checks to decide "burnt to death", as in the debug
    -- panel. Really setting someone alight is IsoGameCharacter.SetOnFire(), and
    -- StopBurning() puts them out.
    add(boolField("IsOnFire", "IGUI_StatsAndBody_IsOnFire",
        function(p) return body(p):isIsOnFire() end,
        function(p, v) body(p):setIsOnFire(v) end))
    -- God mode and invisibility go out to every client in ExtraInfoPacket, which
    -- only the server's own commands can send for another player
    -- (GameServer.sendPlayerExtraInfo is not reachable from Lua, and the Lua
    -- global sendPlayerExtraInfo is client only), so in multiplayer these two use
    -- /godmodplayer and /invisibleplayer. Ghost mode is not listed: in this build
    -- IsoPlayer.setGhostMode just calls setInvisible.
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

-- Body part conditions ------------------------------------------------------------
--[[
    One condition on one body part (a bite on the left hand, a fracture of the right
    shin...), for the admin hotbar's per-part toggle. Vanilla's health panel has the
    same toggles in its Cheat menu, but in multiplayer it sends them as
    player.onHealthCheatCurrentPlayer (server/ClientCommands.lua), which checks
    nothing: any client can hurt any player by online ID. These go through the body
    stats set command instead, with its capability and rank checks and the admin log,
    and each is set and cleared exactly the way that vanilla handler does it.

    A condition is a field like the editor's, keyed "Part:<BodyPartType>:<condition>",
    but not in getFields(), so the editor window does not grow a row per part. Its
    value is true or false, or FLIP to turn it over from whatever the server has:
    another player's body on an admin's client is reset to full health every update
    (BodyDamage.Update), so the hotbar cannot read it and asks the server to flip it.
    After a change the part is sent to its owner at once with syncBodyPart, as vanilla
    does. Nothing is changed while the BodyStatsEditor sandbox option is off.
--]]

BodyStats.FLIP = "flip"

-- Every syncBodyPart flag, the mask vanilla's cheat handler sends.
local PART_SYNC_ALL = 0xFFFFFFFFFFF

-- The BodyPartType constants, head to feet.
BodyStats.PART_TYPES = {
    "Head", "Neck", "Torso_Upper", "Torso_Lower", "Groin",
    "UpperArm_L", "UpperArm_R", "ForeArm_L", "ForeArm_R", "Hand_L", "Hand_R",
    "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R", "Foot_L", "Foot_R",
}

local function removeStiffness(player, part)
    part:setStiffness(0)
    player:getFitness():removeStiffnessValue(BodyPartType.ToString(part:getType()))
end

--- No injury left on the part and its health full.
local function isHealed(part)
    return part:getHealth() >= 100
        and part:getBleedingTime() <= 0 and part:getScratchTime() <= 0
        and not part:isCut() and part:getCutTime() <= 0 and part:getDeepWoundTime() <= 0
        and not part:bitten() and not part:IsInfected() and not part:haveGlass() and not part:haveBullet()
        and part:getBurnTime() <= 0 and part:getFractureTime() <= 0
        and not part:isInfectedWound() and part:getStiffness() <= 0
end

--- Vanilla's Full Health (BodyPart.RestoreToFullHealth) also takes off the bandage,
-- the poultices (plantain, comfrey, garlic), the splint and the stitches. This
-- clears every injury the same way and leaves the treatment on. Stitches never come
-- out by themselves (stitchTime only grows to 50), and pulling them out before 40
-- reopens the wound (BodyPart.setStitched(false)), so they are left fully healed.
-- An alcohol-soaked bandage stays one: nothing here touches the bandage.
local function healKeepingTreatment(part, player)
    -- The bullet first: taking it out makes a deep wound, cleared below.
    if part:haveBullet() then part:setHaveBullet(false, 0) end
    part:setHaveGlass(false)
    part:setBleedingTime(0)
    part:setBleeding(false)
    part:setScratched(false, true)
    part:setScratchTime(0)
    part:setCut(false)
    part:setCutTime(0)
    part:setDeepWoundTime(0)
    part:setDeepWounded(false)
    part:SetBitten(false)
    part:setBiteTime(0)
    part:SetInfected(false)
    part:SetFakeInfected(false)
    part:setBurnTime(0)
    part:setNeedBurnWash(false)
    part:setLastTimeBurnWash(0)
    part:setFractureTime(0)
    part:setInfectedWound(false)
    part:setWoundInfectionLevel(0)
    part:setAdditionalPain(0)
    if part:getStiffness() > 0 then removeStiffness(player, part) end
    if part:stitched() then part:setStitchTime(50) end
    part:SetHealth(100)
end

-- get(part) and set(part, on, player), after server/ClientCommands.lua
-- Commands.player.onHealthCheatCurrentPlayer.
BodyStats.PART_CONDITIONS = {
    { key = "Bleeding", title = "IGUI_ZomboidFixesB42_BodyPart_Bleeding",
        get = function(part) return part:getBleedingTime() > 0 end,
        set = function(part, on) part:setBleedingTime(on and 10 or 0) end },
    { key = "Scratched", title = "IGUI_ZomboidFixesB42_BodyPart_Scratched",
        get = function(part) return part:getScratchTime() > 0 end,
        set = function(part, on)
            if on then
                part:setScratched(true, false)
            else
                part:setScratched(false, true)
                part:setScratchTime(0)
            end
        end },
    { key = "Laceration", title = "IGUI_ZomboidFixesB42_BodyPart_Laceration",
        get = function(part) return part:isCut() end,
        set = function(part, on)
            part:setCut(on)
            if not on then part:setCutTime(0) end
        end },
    { key = "DeepWound", title = "IGUI_ZomboidFixesB42_BodyPart_DeepWound",
        get = function(part) return part:getDeepWoundTime() > 0 end,
        set = function(part, on)
            if on then
                part:generateDeepWound()
            else
                part:setDeepWoundTime(0)
                part:setDeepWounded(false)
                part:setBleedingTime(0)
            end
        end },
    -- A bite also gives the zombie infection, as a real one does (by the sandbox's
    -- infection settings); taking it away cures that part.
    { key = "Bite", title = "IGUI_ZomboidFixesB42_BodyPart_Bite",
        get = function(part) return part:bitten() end,
        set = function(part, on)
            if on then
                part:SetBitten(true)
            else
                part:SetBitten(false)
                part:SetInfected(false)
                part:SetFakeInfected(false)
            end
        end },
    -- Vanilla can only add glass (with its deep wound); removing it is what
    -- ISRemoveGlass does.
    { key = "Glass", title = "IGUI_ZomboidFixesB42_BodyPart_Glass",
        get = function(part) return part:haveGlass() end,
        set = function(part, on)
            if on then part:generateDeepShardWound() else part:setHaveGlass(false) end
        end },
    -- Taking the bullet out leaves the wound it made, as vanilla does.
    { key = "Bullet", title = "IGUI_ZomboidFixesB42_BodyPart_Bullet",
        get = function(part) return part:haveBullet() end,
        set = function(part, on)
            if on then
                part:setHaveBullet(true, 0)
                return
            end
            local deepWound = part:isDeepWounded()
            local deepWoundTime = part:getDeepWoundTime()
            local bleedTime = part:getBleedingTime()
            part:setHaveBullet(false, 0)
            part:setDeepWoundTime(deepWoundTime)
            part:setDeepWounded(deepWound)
            part:setBleedingTime(bleedTime)
        end },
    { key = "Burned", title = "IGUI_ZomboidFixesB42_BodyPart_Burned",
        get = function(part) return part:getBurnTime() > 0 end,
        set = function(part, on) part:setBurnTime(on and 50 or 0) end },
    { key = "Fracture", title = "IGUI_ZomboidFixesB42_BodyPart_Fracture",
        get = function(part) return part:getFractureTime() > 0 end,
        set = function(part, on) part:setFractureTime(on and 21 or 0) end },
    { key = "WoundInfection", title = "IGUI_ZomboidFixesB42_BodyPart_WoundInfection",
        get = function(part) return part:isInfectedWound() end,
        set = function(part, on) part:setWoundInfectionLevel(on and 10 or -1) end },
    { key = "MuscleStrain", title = "IGUI_ZomboidFixesB42_BodyPart_MuscleStrain",
        get = function(part) return part:getStiffness() > 0 end,
        set = function(part, on, player)
            if on then part:setStiffness(100) else removeStiffness(player, part) end
        end },
    -- On = healed. Turning it off does nothing: there is no injury to give back.
    { key = "Healed", title = "IGUI_ZomboidFixesB42_BodyPart_Healed",
        get = function(part) return isHealed(part) end,
        set = function(part, on, player)
            if on then healKeepingTreatment(part, player) end
        end },
}

BodyStats.HEALED = "Healed"

local partTypeSet = {}
for _, name in ipairs(BodyStats.PART_TYPES) do partTypeSet[name] = true end
local conditionByKey = {}
for _, condition in ipairs(BodyStats.PART_CONDITIONS) do conditionByKey[condition.key] = condition end
local partFields = {}

function BodyStats.partsEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.BodyStatsEditor == true
end

function BodyStats.partKey(partType, conditionKey)
    return "Part:" .. tostring(partType) .. ":" .. tostring(conditionKey)
end

--- The field for a "Part:<type>:<condition>" key, or nil.
local function partField(key)
    if partFields[key] then return partFields[key] end
    local typeName, conditionKey = string.match(key, "^Part:([%w_]+):(%w+)$")
    local condition = conditionKey and conditionByKey[conditionKey]
    if not typeName or not partTypeSet[typeName] or not condition then return nil end
    local function bodyPart(player)
        return player:getBodyDamage():getBodyPart(BodyPartType[typeName])
    end
    local field = {
        key = key,
        title = condition.title,
        bool = true,
        part = true,
        get = function(player) return condition.get(bodyPart(player)) == true end,
        set = function(player, on)
            local part = bodyPart(player)
            condition.set(part, on, player)
            if isServer() then syncBodyPart(part, PART_SYNC_ALL) end
        end,
    }
    partFields[key] = field
    return field
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
    if type(key) ~= "string" then return nil end
    return BodyStats.byKey[key] or partField(key)
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

    if field.part then
        if not BodyStats.partsEnabled() then return nil end
        if value == BodyStats.FLIP then value = not field.get(player) end
    end

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
-- body part health, every second for the rest. A single body part can also be
-- sent at once with syncBodyPart(part, mask), server only.
function BodyStats.sync(player, changed)
    if not isServer() or not player:isExistInTheWorld() then return end
    if changed[BodyStats.SYNC_STATS] then
        syncPlayerStats(player, ALL_STATS)
    end
    if changed[BodyStats.SYNC_NUTRITION] then
        syncPlayerStats(player, NUTRITION)
    end
end
