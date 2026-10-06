--[[
    Zomboid Fixes B42.20 -- client, debug "Remove Egg" on a hutch nest box

    Right-clicking a nest box in the hutch window with the Animal Cheat on gives a
    debug "Remove Egg" option (ISHutchNestBox:onRightMouseUp, ISHutchUI.lua ~160).
    In multiplayer ISHutchNestBox:onCheatRemoveEgg only does this:

        sendClientCommandV(self.playerObj, "animal", "removeEggFromNestBox",
                "x", ..., "y", ..., "z", ..., "nestIdx", self.index)

    and the server side of it (ClientCommands.lua ~802,
    Commands.animal.removeEggFromNestBox) is:

        local egg = nestBox:removeEgg(ZombRand(nestBox:getEggsNb()))
        hutch:sync()
        player:getInventory():AddItem(egg)

    AddItem on the server tells nobody. The hutch sync takes the egg out of the
    nest box on every client, but the admin's client is never sent the item, so the
    egg is simply gone from their point of view until they relog. The normal grab
    (ISHutchGrabEgg:animEvent) does the same thing and then calls
    sendAddItemToContainer, which is the line missing here. It also has no nil
    checks: a hutch that is gone, a bad index, or a nest box emptied by someone
    else in the meantime (removeEgg(0) on an empty list) end in a Lua error.

    Vanilla's animal commands live in a local Commands table, so they cannot be
    patched from a mod; the request goes to our own server command instead. Single
    player is left alone, where vanilla takes the egg on the game itself.
--]]

if not isClient() then return end

require "ISUI/Hutch/ISHutchUI"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.HutchRemoveEggCheat == true
end

local vanillaOnCheatRemoveEgg = ISHutchNestBox.onCheatRemoveEgg

function ISHutchNestBox:onCheatRemoveEgg()
    local hutch = self.hutchUI and self.hutchUI.hutch
    if not isClient() or not isEnabled() or not hutch then
        return vanillaOnCheatRemoveEgg(self)
    end

    -- The client's copy of the nest box is not touched: the server's hutch sync
    -- takes the egg out of it, and the egg itself arrives in the inventory.
    sendClientCommand(self.playerObj, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_HUTCH_REMOVE_EGG, {
        x = hutch:getX(),
        y = hutch:getY(),
        z = hutch:getZ(),
        nestIdx = self.index,
    })
end
