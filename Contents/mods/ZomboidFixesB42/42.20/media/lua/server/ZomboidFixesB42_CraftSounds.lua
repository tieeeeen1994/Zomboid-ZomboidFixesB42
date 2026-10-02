--[[
    Zomboid Fixes B42.20 -- server, other players hear crafting and cooking

    In multiplayer nobody hears what another player crafts or cooks: stirring a
    bowl, slicing, kneading, sawing, adding an ingredient to a stew. Those sounds
    are played by the actions' Lua on the crafter's own game:

      * ISHandcraftAction (every craftRecipe, shared/Entity/TimedActions) plays its
        timedAction script's `sound` with self.character:playSound(name) in
        start() (soundTime action_start), or in animEvent() on "StartActionAnim"
        (animation_start) / "PlayActionSound" (animation_event), stops it in
        stop() / perform() / stopSound(), and plays `completionSound` in perform().
      * ISAddItemInRecipe (evolved recipes: soups, stews, salads, drinks) plays the
        recipe's AddIngredientSound (or AddItemInRecipe, AddWet/DryItemInBeverage)
        with getEmitter():playSoundImpl(name, nil) in start() and stops it in
        stop() / perform().

    IsoGameCharacter.playSound -> CharacterSoundEmitter.playSound and playSoundImpl
    only play on the local FMOD emitter; nothing is sent. Sounds that do reach other
    players are either anim XML "PlaySound" events (IsoGameCharacter
    OnAnimEvent_PlaySound, run by every client animating that character) or a
    PlaySoundPacket. A client's PlaySoundPacket is relayed by the server to the
    other connections near the character (zombie/network/packets/sound/
    PlaySoundPacket.processServer, 70 tiles or the sound's clip distance), but Lua
    cannot send one: the only global, sendPlaySound(sound, loop, object), returns
    unless GameServer.server and sends to every client near the object, the crafter
    included, who already plays it (the actions above run on the crafter's client,
    start/perform/stop are never called on the server), and its packet carries no
    handle, so nobody could stop a looping craft sound when the action is cancelled.

    The animation is not the problem: BaseAction.setActionAnim enters
    PlayerActionsState on a client, which captures the action's anim variables
    (PerformingAction, ...) and hand models in its state params, and the remote side
    builds a BaseAction from them (PlayerActionsState.setParams), so others see the
    stirring. Adding an ingredient has no animation at all, in single player too.

    So the crafter's client reports each sound it starts or stops
    (client/ZomboidFixesB42_CraftSounds.lua) and this file passes it on to the
    players near the crafter, whose clients play it on the crafter's character. Only
    sounds some timedAction script or evolved recipe names are passed on, at most
    RATE_LIMIT a second per player, and nothing that starts a sound is passed on for
    an invisible player (CharacterSoundEmitter.playSound already plays nothing for
    one).
--]]

if not isServer() then return end

local MODULE = ZomboidFixesB42.MODULE

-- How far from the crafter, in tiles, other players get the sound. FMOD fades it
-- out well before that.
local RADIUS = 40
-- Messages a player may send a second; a craft sends two or three per action, more
-- for animation_event sounds, which restart on every event.
local RATE_LIMIT = 12

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.CraftSoundsMP ~= false
end

-- Every sound a craft or ingredient action can play, built once on first use
-- (scripts are loaded by then and do not change while a server runs).
local allowed = nil

local function allowedSounds()
    if allowed then return allowed end
    allowed = { AddItemInRecipe = true, AddWetItemInBeverage = true, AddDryItemInBeverage = true }
    local scripts = getScriptManager():getAllTimedActionScripts()
    for i = 0, scripts:size() - 1 do
        local script = scripts:get(i)
        if script:getSound() then allowed[script:getSound()] = true end
        if script:getCompletionSound() then allowed[script:getCompletionSound()] = true end
    end
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
    args from the crafter's client:
      op  "p" play `s` as the craft sound (stopping the one before), or
          "s" stop the craft sound, then play `d` once if given
      s   sound name (op "p")
      d   completion sound (op "s", optional)
      k   the client's session number, n its message number; receivers drop a
          message older than the last they saw (client commands are not ordered)
--]]
local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= ZomboidFixesB42.CMD_CRAFT_SOUND then return end
    if not isEnabled() or not player or type(args) ~= "table" then return end
    if not isCount(args.k) or not isCount(args.n) then return end
    if not withinRate(player:getOnlineID()) then return end

    local out = { id = player:getOnlineID(), k = args.k, n = args.n }
    local silent = player:isInvisible() or player:isDead()
    if args.op == "p" then
        if silent or not isAllowedSound(args.s) then return end
        out.op = "p"
        out.s = args.s
    elseif args.op == "s" then
        out.op = "s"
        if args.d ~= nil and not silent and isAllowedSound(args.d) then
            out.d = args.d
        end
    else
        return
    end
    relay(player, out)
end

Events.OnClientCommand.Add(onClientCommand)
