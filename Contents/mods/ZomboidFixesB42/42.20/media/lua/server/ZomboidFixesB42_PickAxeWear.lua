--[[
    Zomboid Fixes B42.20 -- server and single player, clearing rocks, stumps and ore
    wears the tool

    Breaking up ground cover with a hammer, sledgehammer, club hammer, pickaxe or
    stone maul (small rocks, iron and copper ore, flint and limestone boulders) or
    a stump with a stump-removing tool runs ISPickAxeGroundCoverItem
    (shared/TimedActions/ISPickAxeGroundCoverItem.lua, 42.21). new() and start()
    keep the tool in self.pickAxe, and the swing sounds and arm strain in animEvent
    read it, but the wear at the end of complete() (~146) reads another name:

        if not self.character:isBuildCheat() and self.pickaxe then
            self.pickaxe:damageCheck(0,2,false)
        end

    self.pickaxe is never set, so the tool never wears, in single player or on a
    server. complete() only runs on the server and in single player; the server's
    table comes from new() with the server's character, so its self.pickAxe is the
    server's item in hand. This does vanilla's wear after vanilla's complete(), and
    swaps a tool that broke for the best weapon left like the sledgehammer's
    destroy does (ItemUtils.checkWeapon). damageCheck -> reduceCondition ->
    syncItemFields sends the condition, and the hand swap reaches the player by
    itself (Equip packet, see server/ZomboidFixesB42_RemoveBush.lua). The server's
    request to refresh the inventory window is answered by
    client/ZomboidFixesB42_RemoveBush.lua; both share the RemoveBushToolWear option.
--]]

if isClient() then return end

require "TimedActions/ISPickAxeGroundCoverItem"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.RemoveBushToolWear ~= false
end

local vanillaComplete = ISPickAxeGroundCoverItem.complete

function ISPickAxeGroundCoverItem:complete()
    local result = vanillaComplete(self)
    -- Only while vanilla still misses it (self.pickaxe unset), so a later fix
    -- or another mod setting it does not wear the tool twice.
    if self.item and not self.pickaxe and isEnabled() and not self.character:isBuildCheat() then
        local tool = self.pickAxe
        if tool and tool:getCondition() > 0 and self.character:getPrimaryHandItem() == tool then
            if tool:damageCheck(0, 2, false) then
                ItemUtils.checkWeapon(self.character)
            end
        end
    end
    return result
end
