--[[
    Zomboid Fixes B42.20 -- client, other players hear ingredients being added

    Adding an ingredient to a soup, stew, salad or drink (ISAddItemInRecipe) plays
    its sound on the cook's game only (see server/ZomboidFixesB42_CraftSounds.lua
    for the Java behind it), so in multiplayer nobody else hears it. Crafting
    sounds (ISHandcraftAction) need nothing: vanilla already shares them. This
    file has both halves of the relay:

      * Sending: ISAddItemInRecipe is wrapped so that when vanilla starts its sound
        (self.sound becomes a playing handle), the sound's name goes to the server,
        and when vanilla stops it (stop, perform), a stop goes too. Nothing is sent
        for an invisible cook; the server checks invisibility again.
      * Receiving: the server passes the message on to players near the cook, and
        their client plays the sound on the cook's character and keeps the handle
        to stop it later. Only the emitter's local calls are used here
        (playSoundImpl, stopOrTriggerSoundLocal): character:playSound and
        stopOrTriggerSound send a PlaySound / StopSound packet of their own, which
        the server forwards to everyone else near the cook, the cook included, so
        every receiver would echo the sound back to the cook (heard twice there)
        and to the other receivers, and could cut the cook's own sound short.

    Client commands travel unordered (RakNet RELIABLE), so every message carries
    this game's session number and a message number; a receiver drops one older
    than the last it saw from that player. A sound is also stopped when its player
    leaves, dies or respawns, and after MAX_SOUND_MS at the latest, so a lost stop
    cannot leave a loop playing. Vanilla's own stop (stopOrTriggerSound on the
    cook's game) also sends a StopSound by name, which stops the relayed copy too.
--]]

if not isClient() then return end

require "TimedActions/ISAddItemInRecipe"

local MODULE = ZomboidFixesB42.MODULE

-- Longest a relayed sound may play without a stop.
local MAX_SOUND_MS = 5 * 60 * 1000
-- How often the playing sounds are checked.
local WATCH_MS = 250

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.CraftSoundsMP ~= false
end

-- Sending -------------------------------------------------------------------------

local session = ZombRand(1, 1000000000)
local sequence = 0

local function isLocalCook(character)
    return character and instanceof(character, "IsoPlayer") and character:isLocalPlayer()
end

local function send(character, args)
    sequence = sequence + 1
    args.k = session
    args.n = sequence
    sendClientCommand(character, MODULE, ZomboidFixesB42.CMD_CRAFT_SOUND, args)
end

local function isHandle(sound)
    return sound ~= nil and sound ~= 0
end

--- ISAddItemInRecipe:start's choice of sound, which it keeps in a local.
local function ingredientSound(action)
    local sound = action.recipe and action.recipe:getAddIngredientSound() or "AddItemInRecipe"
    if sound == "AddItemInBeverage" then
        if action.usedItem and action.usedItem:hasTag(ItemTag.WET_BEVERAGE_INGREDIENT) then
            sound = "AddWetItemInBeverage"
        else
            sound = "AddDryItemInBeverage"
        end
    end
    return sound
end

--- Sends a stop for the action's sound, if one was sent.
local function sendStop(action)
    if not action.zfixCraftSound or not isLocalCook(action.character) then return end
    action.zfixCraftSound = nil
    send(action.character, { op = "s" })
end

local vanillaIngredientStart = ISAddItemInRecipe.start

function ISAddItemInRecipe:start()
    local before = self.sound
    local result = vanillaIngredientStart(self)
    if isEnabled() and isLocalCook(self.character) and not self.character:isInvisible()
            and isHandle(self.sound) and self.sound ~= before then
        self.zfixCraftSound = true
        send(self.character, { op = "p", s = ingredientSound(self) })
    end
    return result
end

local vanillaIngredientStop = ISAddItemInRecipe.stop

function ISAddItemInRecipe:stop()
    sendStop(self)
    return vanillaIngredientStop(self)
end

local vanillaIngredientPerform = ISAddItemInRecipe.perform

function ISAddItemInRecipe:perform()
    sendStop(self)
    return vanillaIngredientPerform(self)
end

-- Receiving -----------------------------------------------------------------------

-- [onlineID] = { character, handle, started }
local playing = {}
-- [onlineID] = { k = session, n = message number } of the newest message seen
local newest = {}

local function stopSound(id)
    local entry = playing[id]
    playing[id] = nil
    if entry then
        entry.character:getEmitter():stopOrTriggerSoundLocal(entry.handle)
    end
end

local function isNewest(args)
    local last = newest[args.id]
    if last and last.k == args.k and args.n <= last.n then return false end
    newest[args.id] = { k = args.k, n = args.n }
    return true
end

local function onServerCommand(module, command, args)
    if module ~= MODULE or command ~= ZomboidFixesB42.CMD_CRAFT_SOUND_RELAY then return end
    if type(args) ~= "table" or type(args.id) ~= "number" then return end
    if type(args.k) ~= "number" or type(args.n) ~= "number" then return end
    if not isNewest(args) then return end

    stopSound(args.id)
    local character = getPlayerByOnlineID(args.id)
    if not character or character:isLocalPlayer() or character:isDead() then return end

    if args.op == "p" and type(args.s) == "string" then
        local handle = character:getEmitter():playSoundImpl(args.s, nil)
        if isHandle(handle) then
            playing[args.id] = { character = character, handle = handle, started = getTimestampMs() }
        end
    end
end

local lastWatch = 0

local function watchSounds()
    local now = getTimestampMs()
    if now - lastWatch < WATCH_MS then return end
    lastWatch = now
    local finished = nil
    for id, entry in pairs(playing) do
        local character = getPlayerByOnlineID(id)
        if character ~= entry.character or character:isDead()
                or not entry.character:getEmitter():isPlaying(entry.handle)
                or now - entry.started > MAX_SOUND_MS then
            finished = finished or {}
            finished[#finished + 1] = id
        end
    end
    if finished then
        for _, id in ipairs(finished) do stopSound(id) end
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(watchSounds)
