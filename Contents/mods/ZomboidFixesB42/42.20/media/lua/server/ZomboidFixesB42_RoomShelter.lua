--[[
    Zomboid Fixes B42.20 -- server, a room you built yourself shelters you from corpse smell

    The Bad Smell moodle (MoodleType.NOXIOUS_SMELL) follows the corpse sickness rate,
    and the shelter check in the game is the building you stand in:

      - Moodle.java: the smell level is set from IsoGameCharacter.getCorpseSicknessRate(),
        except that a toxic map building forces the top level.
      - BodyDamage.UpdateIllness adds that rate to FOOD_SICKNESS every update, unless the
        decaying corpse health impact sandbox option is off.
      - BodyDamage.getSicknessFromCorpsesRate reads CorpseCount.getCorpseCount(player),
        which passes chr.getBuilding() (room.building, so null outside any map building).
        With a building it counts that building's corpses; with none it counts every
        corpse in the 3x3 chunk area, as if the player were in the street.

    So a home you built yourself (walls and a roof, no map building behind them) gets the
    full outdoor count, while a map house gets its own. The game lets you plumb a sink
    only where the square is in a room (ISWorldObjectContextMenuLogic, the canBeWaterPiped
    check: square:isInARoom()), so a home where sinks can be plumbed is a room, and this
    file treats such a room like a building: a player on a room square with no map
    building takes no corpse sickness, and the moodle stays off. Map buildings keep the
    game's own count.

    The fix runs every tick after the game's update: it takes back the FOOD_SICKNESS the
    update just added (the rate times the game time multiplier, as UpdateIllness adds it)
    and zeroes the rate, so the moodle shows nothing. Zombie counts are not touched.

    Option RoomShelterFromCorpses (beta: not yet played in game).
--]]

if isClient() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.RoomShelterFromCorpses == true
end

-- Calls fn for every player on this server, or the local players in single player.
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

local function inRoomWithoutBuilding(player)
    if player:isDead() then return false end
    local square = player:getCurrentSquare()
    return square ~= nil and square:isInARoom() and player:getBuilding() == nil
end

Events.OnTick.Add(function()
    if not isEnabled() then return end
    eachPlayer(function(player)
        if not inRoomWithoutBuilding(player) then return end
        local rate = player:getCorpseSicknessRate()
        if rate > 0 then
            local stats = player:getStats()
            local added = rate * getGameTime():getMultiplier()
            stats:set(CharacterStat.FOOD_SICKNESS, stats:get(CharacterStat.FOOD_SICKNESS) - added)
        end
        player:setCorpseSicknessRate(0)
    end)
end)
