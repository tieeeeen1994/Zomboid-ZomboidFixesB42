--[[
    Zomboid Fixes B42.20 -- shared, putting on and taking off a padlock in multiplayer

    ISPadlockAction (shared/TimedActions/ISPadlockAction.lua, 42.21) does its work in
    complete(), on the server. Taking a padlock off:

        local padlock = instanceItem("Base.Padlock")
        self.character:getInventory():AddItem(padlock);
        sendAddItemToContainer(self.character:getInventory(), padlock);
        local keyToUse = self.character:getInventory():haveThisKeyId(self.thump:getKeyId());
        padlock:setNumberOfKey(1);
        padlock:setKeyId(keyToUse:getKeyId());
        keyToUse:getContainer():Remove(keyToUse);
        sendRemoveItemFromContainer(self.character:getInventory(), keyToUse);

      * The padlock is sent before its key count and key ID are set, so the owner's
        copy has no keys and no key ID. Nothing sends them later
        (SyncItemFieldsPacket has neither), and the "Put Padlock" option needs
        getNumberOfKey() > 0 (ISWorldObjectContextMenuLogic ~1464), so the padlock
        just taken off cannot be put on again until the player relogs.
      * haveThisKeyId also looks inside key rings (ItemContainer ~3258), and the key
        is removed from the ring on the server but the removal is sent for the main
        inventory, so the owner's key ring keeps a key the server no longer has.
      * No key at all (dropped while walking over) ends in a Lua error.

    Putting one on removes the padlock from the main inventory only, while the
    removal is sent for the same container, so a padlock in a bag would stay. The
    option only offers a padlock from the main inventory (FindAndReturn), so that is
    only made safe here.

    So complete() sets the padlock up before sending it and removes each item from
    the container it is really in, and refuses (returns false, the server rejects
    the action) when the padlock or the key is gone.
--]]

require "TimedActions/ISPadlockAction"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.PadlockFixes == true
end

local function removeItem(item, fallback)
    local container = item:getContainer() or fallback
    sendRemoveItemFromContainer(container, item)
    container:Remove(item)
end

local vanillaComplete = ISPadlockAction.complete

function ISPadlockAction:complete()
    if not isEnabled() then
        return vanillaComplete(self)
    end

    local inventory = self.character:getInventory()
    local thump = self.thump
    if not thump then return false end

    if self.lock then
        local padlock = self.padlock
        if not padlock then return false end

        thump:setLockedByPadlock(true)
        thump:setKeyId(padlock:getKeyId())
        local keys = inventory:AddItems("Base.KeyPadlock", padlock:getNumberOfKey())
        for i = 0, keys:size() - 1 do
            local key = keys:get(i)
            key:setKeyId(padlock:getKeyId())
            sendAddItemToContainer(inventory, key)
        end
        removeItem(padlock, inventory)
        thump:sync()
    else
        local key = inventory:haveThisKeyId(thump:getKeyId())
        if not key then return false end

        thump:setLockedByPadlock(false)
        local padlock = instanceItem("Base.Padlock")
        padlock:setNumberOfKey(1)
        padlock:setKeyId(key:getKeyId())
        inventory:AddItem(padlock)
        sendAddItemToContainer(inventory, padlock)
        removeItem(key, inventory)
        thump:setKeyId(-1)
        thump:sync()
    end

    if not isServer() then
        local pdata = getPlayerData(self.character:getPlayerNum())
        pdata.lootInventory:refreshBackpacks()
        pdata.playerInventory:refreshBackpacks()
    end
    return true
end
