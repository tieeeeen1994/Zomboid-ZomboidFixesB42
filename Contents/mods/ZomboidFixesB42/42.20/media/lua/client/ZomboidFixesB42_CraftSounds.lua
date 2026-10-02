--[[
    Zomboid Fixes B42.20 -- client, other players hear crafting and cooking

    Craft and ingredient sounds are played by the actions' Lua on the crafter's
    game only (see server/ZomboidFixesB42_CraftSounds.lua for the Java behind it),
    so in multiplayer nobody else hears someone stir, slice, knead or add an
    ingredient to a pot. This file has both halves of the relay:

      * Sending: ISHandcraftAction and ISAddItemInRecipe are wrapped so that each
        time vanilla starts its sound (self.sound becomes a playing handle), the
        sound's name goes to the server, and when vanilla stops it (stop, perform),
        a stop goes too, with the completion sound perform() plays, if any.
        CharacterSoundEmitter.playSound returns 0 for an invisible character, so
        nothing is sent for one; the server checks invisibility again for
        ISAddItemInRecipe, whose playSoundImpl does not.
      * Receiving: the server passes the message on to players near the crafter,
        and their client plays the sound on the crafter's character
        (IsoPlayer:playSound -> its CharacterSoundEmitter, which follows the
        character and plays nothing for an invisible one) and keeps the handle to
        stop it later.

    Client commands travel unordered (RakNet RELIABLE), so every message carries
    this game's session number and a message number; a receiver drops one older
    than the last it saw from that player. A sound is also stopped when its player
    leaves, dies or respawns, when the player was seen in an action
    (IsPerformingAnAction, which the remote copy gets from the
    NetworkPlayerVariables isPerformingAction flag and PlayerActionsState) and no
    longer is, and after MAX_SOUND_MS at the latest, so a lost stop cannot leave a
    loop playing. Adding an ingredient has no animation, so that sound only stops
    on its message, on its own or at the cap.
--]]

if not isClient() then return end

require "Entity/TimedActions/ISHandcraftAction"
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

local function isLocalCrafter(character)
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

--- Sends the action's sound if vanilla started a new one since `before`.
local function sendIfStarted(action, before, sound)
    if not isEnabled() or not isLocalCrafter(action.character) then return end
    if isHandle(action.sound) and action.sound ~= before and sound then
        action.zfixCraftSound = true
        send(action.character, { op = "p", s = sound })
    end
end

--- Sends a stop for the action's sound (if one was sent), and the completion sound.
local function sendStop(action, completion)
    if not isLocalCrafter(action.character) then return end
    if not action.zfixCraftSound and not (completion and isEnabled()) then return end
    action.zfixCraftSound = nil
    send(action.character, { op = "s", d = isEnabled() and completion or nil })
end

local function scriptSound(action)
    return action.actionScript and action.actionScript:getSound() or nil
end

local vanillaHandcraftStart = ISHandcraftAction.start

function ISHandcraftAction:start()
    local before = self.sound
    local result = vanillaHandcraftStart(self)
    sendIfStarted(self, before, scriptSound(self))
    return result
end

local vanillaHandcraftAnimEvent = ISHandcraftAction.animEvent

function ISHandcraftAction:animEvent(event, parameter)
    local before = self.sound
    local result = vanillaHandcraftAnimEvent(self, event, parameter)
    sendIfStarted(self, before, scriptSound(self))
    return result
end

local vanillaHandcraftStop = ISHandcraftAction.stop

function ISHandcraftAction:stop()
    sendStop(self, nil)
    return vanillaHandcraftStop(self)
end

local vanillaHandcraftPerform = ISHandcraftAction.perform

function ISHandcraftAction:perform()
    local completion = self.actionScript and self.actionScript:getCompletionSound() or nil
    if completion and self.character and self.character:isInvisible() then completion = nil end
    sendStop(self, completion)
    return vanillaHandcraftPerform(self)
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

local vanillaIngredientStart = ISAddItemInRecipe.start

function ISAddItemInRecipe:start()
    local before = self.sound
    local result = vanillaIngredientStart(self)
    if self.character and not self.character:isInvisible() then
        sendIfStarted(self, before, ingredientSound(self))
    end
    return result
end

local vanillaIngredientStop = ISAddItemInRecipe.stop

function ISAddItemInRecipe:stop()
    sendStop(self, nil)
    return vanillaIngredientStop(self)
end

local vanillaIngredientPerform = ISAddItemInRecipe.perform

function ISAddItemInRecipe:perform()
    sendStop(self, nil)
    return vanillaIngredientPerform(self)
end

-- Receiving -----------------------------------------------------------------------

-- [onlineID] = { character, handle, started, seenInAction }
local playing = {}
-- [onlineID] = { k = session, n = message number } of the newest message seen
local newest = {}

local function stopSound(id)
    local entry = playing[id]
    playing[id] = nil
    if entry then
        entry.character:getEmitter():stopOrTriggerSound(entry.handle)
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
        local handle = character:playSound(args.s)
        if isHandle(handle) then
            playing[args.id] = { character = character, handle = handle, started = getTimestampMs(), seenInAction = false }
        end
    elseif args.op == "s" and type(args.d) == "string" then
        character:playSound(args.d)
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
        local done = false
        if character ~= entry.character or character:isDead() then
            done = true
        elseif not entry.character:getEmitter():isPlaying(entry.handle) then
            done = true
        elseif character:isPerformingAnAction() then
            entry.seenInAction = true
        elseif entry.seenInAction then
            done = true
        end
        if done or now - entry.started > MAX_SOUND_MS then
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
