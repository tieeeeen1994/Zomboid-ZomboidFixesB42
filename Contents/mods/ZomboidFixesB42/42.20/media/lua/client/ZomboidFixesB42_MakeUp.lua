--[[
    Zomboid Fixes B42.20 -- client, removing make-up in multiplayer

    The make-up window's Remove button (ISMakeUpUI:onRemoveMakeUp) only changes the
    client's copy (see shared/ZomboidFixesB42_MakeUp.lua). In multiplayer it now
    asks the server to take the make-up off and out of the inventory, and takes it
    off here at once so the window and the character update without waiting.
    Single player is left alone, where vanilla's removal is the real one.
--]]

if not isClient() then return end

require "ISUI/ISMakeUpUI"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MakeUpSync == true
end

local vanillaOnRemoveMakeUp = ISMakeUpUI.onRemoveMakeUp

function ISMakeUpUI:onRemoveMakeUp()
    if not isClient() or not isEnabled() then
        return vanillaOnRemoveMakeUp(self)
    end

    local option = self.removeMakeupCombo.options[self.removeMakeupCombo.selected]
    local selected = option and option.data
    if not selected or not selected.item then return end

    sendClientCommand(self.character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_REMOVE_MAKEUP, {
        id = selected.item:getID(),
    })

    -- Sends SyncClothing, which takes it off on the server too; the server's own
    -- removal then takes the item out of the inventory, wherever this lands first.
    -- Nothing is removed from the inventory here: the server's
    -- RemoveItemFromContainer does it, and the item may not be there at all.
    self.character:removeWornItem(selected.item, false)
    self:reinitCombos()
    self.needsUpdateAvatar = true
end
