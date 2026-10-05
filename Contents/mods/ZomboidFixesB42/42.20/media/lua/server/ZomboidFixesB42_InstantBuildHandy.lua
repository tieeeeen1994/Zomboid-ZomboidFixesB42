--[[
    Zomboid Fixes B42.20 -- server, instant building with the Handy trait

    In multiplayer a build is a Java BuildAction timed by the server
    (zombie/core/BuildAction.getDuration, 42.21):

        maxTime = 200 - Woodwork * 5     (150 for graves)
        if isTimedActionInstant() then maxTime = 1 end
        if hasTrait(HANDY) then maxTime = maxTime - 50 end
        return maxTime * 20

    so the Timed Action Instant cheat plus Handy gives -980 ms. Action.setTimeData
    treats a negative duration as "looped" and sets the end to
    AnimEventEmulator.getDurationMax(), 30 minutes later; the client's ISBuildAction
    gets the same negative duration (getActionDuration is never > 0), waits with
    setWaitForFinished and an empty bar, and the build lands half an hour later
    unless the player walks away (forum 100841). Single player is fine: there the
    action's maxTime of -49 counts as finished at once (BaseAction.isFinished).

    No Lua runs between the duration and the server's answer, but the server builds
    the building object from the client's arguments first: BuildActionPacket.parse
    calls <Type>.new, and every building object's new calls ISBuildingObject.init.
    So while init runs on the server, Handy is taken off every online player who has
    instant timed actions, and the next OnTick puts it back. The trait map has no
    side effects (CharacterTraits.set only flips a flag), and in GameServer's main
    loop packets are handled first, then IngameState.update (OnTick), then
    NetworkPlayerManager's trait sync (PlayerXp), so no client ever sees the trait
    missing. Players without the cheat are never touched, and for players with it
    every duration is 1 anyway.
    The one gap: a held player who disconnects before that OnTick is saved without
    Handy (a disconnect is handled in the same packet loop).
--]]

if isClient() then return end

require "BuildingObjects/ISBuildingObject"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.InstantBuildHandy ~= false
end

-- Players whose Handy trait is held until the next OnTick.
local held = {}

local function holdHandy()
    local players = getOnlinePlayers()
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player:isTimedActionInstant() and player:hasTrait(CharacterTrait.HANDY) then
            player:getCharacterTraits():remove(CharacterTrait.HANDY)
            table.insert(held, player)
        end
    end
end

local function restoreHandy()
    if #held == 0 then return end
    for _, player in ipairs(held) do
        player:getCharacterTraits():add(CharacterTrait.HANDY)
    end
    held = {}
end

local vanillaInit = ISBuildingObject.init

function ISBuildingObject:init()
    -- Single player needs nothing (see above).
    if isServer() and isEnabled() then
        holdHandy()
    end
    return vanillaInit(self)
end

Events.OnTick.Add(restoreHandy)
