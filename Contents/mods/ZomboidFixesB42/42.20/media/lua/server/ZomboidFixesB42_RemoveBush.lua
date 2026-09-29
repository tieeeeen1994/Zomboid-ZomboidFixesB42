--[[
    Zomboid Fixes B42.20 -- server and single player, removing a bush wears the tool

    Removing a bush or wall vines with a knife, machete, axe or other cutting tool
    (ISRemoveBush, shared/TimedActions/ISRemoveBush.lua in 42.21) is meant to strain
    the arms, cost endurance and now and then wear the tool, swapping a broken one
    for the best weapon left in the inventory. All of that is in animEvent, under
    isServer(), on the "Chop" event:

        if self.weapon then  addCombatMuscleStrain(self.weapon, ...)  end
        self:useEndurance()                         -- nothing without self.weapon
        if self.weapon and self.weapon:damageCheck(0, 4, false) then
            ItemUtils.checkWeapon(self.character)   -- 42.20: the client-only
        end                                         -- ISWorldObjectContextMenu one

    None of it ever happens:

      * On a server the action is a new table: NetTimedAction.parse calls
        ISRemoveBush.new with the values of new's own parameters (character,
        square, wallVine) read from the client's action, and then only
        serverStart, animEvent and complete. self.weapon is set in start(), which
        runs on the client only, so the server's copy never has a tool. That also
        sends complete() down its bare-handed branch, so every bush gave back
        muscle strain as if pulled out by hand, tool or not.
      * In single player isServer() is false, and the tool animations
        (RemoveBushAxe/Knife/LongBlade.xml) have an event with no name, so "Chop"
        only ever fires bare-handed.

    42.21 moved checkWeapon to the shared ItemUtils.checkWeapon, so it no longer
    errors on a server. Swapping the tool there reaches the player by itself:
    IsoGameCharacter.setPrimaryHandItem / setSecondaryHandItem set
    handItemShouldSendToClients, and the next preupdate sends an Equip packet to
    the owner, whose client sends it back for the server to pass on to everyone
    else. The condition goes with damageCheck -> reduceCondition -> syncItemFields.

    So on a server the tool in hand is taken in serverStart (the same item the
    client's start() takes, if it is a weapon: the vanilla code calls weapon
    methods on it), and vanilla's own animEvent does the rest. The server emulates
    one "Chop" every 1.5 s of a 2 s action (serverStart), so a bush costs one
    chop. In single player the same chop is done once when the bush comes out
    (complete, which Java calls there too). A tool that broke or left the hand
    during the action counts no more: the client's isValid ends the action once the
    broken condition arrives, and fast forward may fire another event before that.
--]]

if isClient() then return end

require "TimedActions/ISRemoveBush"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.RemoveBushToolWear ~= false
end

--- The action's tool, if it is still a working weapon in the primary hand.
local function toolInHand(action)
    local weapon = action.weapon
    if weapon and instanceof(weapon, "HandWeapon") and weapon:getCondition() > 0
            and action.character:getPrimaryHandItem() == weapon then
        return weapon
    end
    return nil
end

local vanillaServerStart = ISRemoveBush.serverStart

function ISRemoveBush:serverStart()
    if isEnabled() and not self.weapon then
        local item = self.character:getPrimaryHandItem()
        if item and instanceof(item, "HandWeapon") then
            self.weapon = item
        end
    end
    return vanillaServerStart(self)
end

local vanillaAnimEvent = ISRemoveBush.animEvent

function ISRemoveBush:animEvent(event, parameter)
    local weapon = self.weapon
    if weapon and isServer() and isEnabled() and not toolInHand(self) then
        -- Chop without the broken or put-away tool, then put it back for the
        -- rest of the action (complete's bare-handed check).
        self.weapon = nil
        vanillaAnimEvent(self, event, parameter)
        self.weapon = weapon
        return
    end
    return vanillaAnimEvent(self, event, parameter)
end

local vanillaComplete = ISRemoveBush.complete

function ISRemoveBush:complete()
    if not isServer() and isEnabled() then
        local weapon = toolInHand(self)
        if weapon then
            -- Vanilla's server-side "Chop", done once in single player.
            local modifier = 1
            if self.character:getDescriptor():isCharacterProfession(CharacterProfession.LUMBERJACK) then
                modifier = 0.5
            end
            self.character:addCombatMuscleStrain(weapon, 1, modifier)
            self:useEndurance()
            if weapon:damageCheck(0, 4, false) then
                ItemUtils.checkWeapon(self.character)
            end
        end
    end
    return vanillaComplete(self)
end
