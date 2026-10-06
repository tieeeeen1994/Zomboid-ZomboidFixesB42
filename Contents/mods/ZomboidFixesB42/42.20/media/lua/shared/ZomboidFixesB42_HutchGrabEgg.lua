--[[
    Zomboid Fixes B42.20 -- shared, grabbing eggs from a nest box takes them all

    "Grab eggs" on a nest box is ISHutchGrabEgg
    (shared/TimedActions/Animals/ISHutchGrabEgg.lua, 42.21). It takes one egg per
    timePerEgg (40 ticks) and is meant to end once the box is empty, but how it
    gets there differs:

      * On a server, getDuration returns -1 (an action with no end of its own) and
        serverStart asks for an "update" event every timePerEgg * 20 ms:

            emulateAnimEvent(self.netAction, period, "update", nil)

        Each event takes one egg. When the last one is gone the hutch sync empties
        the client's nest box, the client's isValid turns false and the client
        cancels the action. That works.

        With Timed Action Instant on, getDuration sets timePerEgg = 1 and returns
        (eggs + 5): an action of (eggs + 5) * 20 ms with an event every 20 ms. But
        zombie.network.server.AnimEventEmulator.update runs once per server update
        (IngameState.update, 10 a second) and fires each event at most once per
        call, so the server takes one egg per 100 ms, not per 20 ms. The action
        ends (ActionManager completes it at its endTime, complete() takes nothing)
        after about a fifth of the eggs: 10 eggs = 300 ms = 3 eggs, and the rest
        stay in the box.

      * In single player update() counts timer += getMultiplier() and takes one egg
        each time timer / timePerEgg moves on -- but only one, however far it moved.
        With fast forward a single update can skip several eggs' worth, and the
        action still ends at maxTime with the skipped eggs left behind. With Timed
        Action Instant the action is over almost at once.

    Both end in complete(), which vanilla leaves empty. So complete() takes what is
    still in the nest box, with the same work per egg as an event (Husbandry XP, the
    egg into the inventory, sent to the owner on a server). An action stopped early
    (walked away, cancelled) runs serverStop / stop instead and keeps the vanilla
    partial grab; the normal server run is cancelled by the client before it could
    complete, so only the runs that came up short are affected.

    Also, the "update" event takes removeEgg(0) without looking: an event that
    arrives after the box is empty (the client's cancel still on its way, or extra
    events fired during multiplayer fast forward) throws IndexOutOfBounds. Such an
    event is skipped.
--]]

require "TimedActions/Animals/ISHutchGrabEgg"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.HutchGrabAllEggs == true
end

local function hasEgg(action)
    return action.nestbox ~= nil and action.nestbox:getEggsNb() > 0
end

local vanillaAnimEvent = ISHutchGrabEgg.animEvent

function ISHutchGrabEgg:animEvent(event, parameter)
    if isEnabled() and event == "update" and not hasEgg(self) then return end
    return vanillaAnimEvent(self, event, parameter)
end

local vanillaComplete = ISHutchGrabEgg.complete

function ISHutchGrabEgg:complete()
    if not isEnabled() or isClient() or not hasEgg(self) or not self.hutch then
        return vanillaComplete(self)
    end

    local inventory = self.character:getInventory()
    -- A nest box holds at most 10 eggs (IsoHutch.NestBox.maxEggs); the cap only
    -- guards against a box that would somehow refill while it is being emptied.
    local taken = 0
    while hasEgg(self) and taken < 10 do
        local egg = self.nestbox:removeEgg(0)
        taken = taken + 1
        if egg then
            addXp(self.character, Perks.Husbandry, 1)
            inventory:AddItem(egg)
            if isServer() then
                sendAddItemToContainer(inventory, egg)
            end
        end
    end
    self.hutch:sync()

    return vanillaComplete(self)
end
