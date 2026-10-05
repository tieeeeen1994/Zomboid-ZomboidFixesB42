--[[
    Zomboid Fixes B42.20 -- server, other players hear ingredients being added

    In multiplayer nobody hears another player add an ingredient to a soup, stew,
    salad or drink. ISAddItemInRecipe (evolved recipes) plays the recipe's
    AddIngredientSound (or AddItemInRecipe, AddWet/DryItemInBeverage) with
    getEmitter():playSoundImpl(name, nil) in start() and stops it with
    getEmitter():stopOrTriggerSound in stop() / perform(), on the cook's client only
    (start/perform/stop never run on the server).

    How a character's sound reaches other players (42.21, fmod/fmod/FMODSoundEmitter,
    the same in PZ_Optimization's copy of that class): CharacterSoundEmitter.playSound
    -> FMODSoundEmitter.playSound(String) on a client sends a PlaySoundPacket for the
    character (not for an invisible player), and stopSound / stopOrTriggerSound send a
    StopSoundPacket by sound name. The server relays both to the other connections
    near the character (PlaySoundPacket.processServer: 70 tiles or the sound's clip
    distance; never back to the sender), whose clients play it with playSoundImpl and
    stop it with stopOrTriggerSoundByName. playSoundImpl, stopSoundLocal and
    stopOrTriggerSoundLocal send nothing. So crafting (ISHandcraftAction, which uses
    character:playSound for its sound and completion sound) is already heard by
    everyone; the ingredient sound, played with playSoundImpl, is not. Lua cannot
    send a PlaySoundPacket for another character's sound without playing it locally:
    the only global, sendPlaySound(sound, loop, object), returns unless
    GameServer.server and goes to every client near the object, the cook included,
    who already plays it.

    So the cook's client reports each ingredient sound it starts or stops
    (client/ZomboidFixesB42_CraftSounds.lua) and this file passes it on to the
    players near the cook, whose clients play it on the cook's character. Only
    ingredient sounds of the game's evolved recipes are passed on, at most
    RATE_LIMIT a second per player, and none for an invisible player.
--]]

if not isServer() then return end

local MODULE = ZomboidFixesB42.MODULE

-- How far from the cook, in tiles, other players get the sound. FMOD fades it out
-- well before that.
local RADIUS = 40
-- Messages a player may send a second; adding an ingredient sends two.
local RATE_LIMIT = 12

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.CraftSoundsMP == true
end

-- Every sound adding an ingredient can play, built once on first use (scripts are
-- loaded by then and do not change while a server runs).
local allowed = nil

local function allowedSounds()
    if allowed then return allowed end
    allowed = { AddItemInRecipe = true, AddWetItemInBeverage = true, AddDryItemInBeverage = true }
    local recipes = getScriptManager():getAllEvolvedRecipesList()
    for i = 0, recipes:size() - 1 do
        local sound = recipes:get(i):getAddIngredientSound()
        if sound then allowed[sound] = true end
    end
    return allowed
end

local function isAllowedSound(sound)
    return type(sound) == "string" and allowedSounds()[sound] == true
end

local function isCount(n)
    return type(n) == "number" and n == n and n >= 0 and n < 2 ^ 52
end

-- [onlineID] = { second = whole second, count = messages in it }
local rates = {}

local function withinRate(id)
    local second = math.floor(getTimestampMs() / 1000)
    local rate = rates[id]
    if not rate or rate.second ~= second then
        rates[id] = { second = second, count = 1 }
        return true
    end
    rate.count = rate.count + 1
    return rate.count <= RATE_LIMIT
end

local function relay(player, args)
    local players = getOnlinePlayers()
    if not players then return end
    local x, y = player:getX(), player:getY()
    for i = 0, players:size() - 1 do
        local other = players:get(i)
        if other ~= player and math.abs(other:getX() - x) <= RADIUS and math.abs(other:getY() - y) <= RADIUS then
            sendServerCommand(other, MODULE, ZomboidFixesB42.CMD_CRAFT_SOUND_RELAY, args)
        end
    end
end

--[[
    args from the cook's client:
      op  "p" play `s` (stopping the one before), or "s" stop it
      s   sound name (op "p")
      k   the client's session number, n its message number; receivers drop a
          message older than the last they saw (client commands are not ordered)
--]]
local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= ZomboidFixesB42.CMD_CRAFT_SOUND then return end
    if not isEnabled() or not player or type(args) ~= "table" then return end
    if not isCount(args.k) or not isCount(args.n) then return end
    if not withinRate(player:getOnlineID()) then return end

    local out = { id = player:getOnlineID(), k = args.k, n = args.n }
    if args.op == "p" then
        if player:isInvisible() or player:isDead() or not isAllowedSound(args.s) then return end
        out.op = "p"
        out.s = args.s
    elseif args.op == "s" then
        out.op = "s"
    else
        return
    end
    relay(player, out)
end

Events.OnClientCommand.Add(onClientCommand)
