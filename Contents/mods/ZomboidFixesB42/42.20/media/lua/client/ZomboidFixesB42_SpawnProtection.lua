--[[
    Zomboid Fixes B42.20 -- client, admin spawn protection

    The server fully restores an admin as they join (see the server file). This
    side restores the client's own copy too, so the character is not drawn dying
    before the server's sync arrives, and gives them god mode for the number of
    seconds set in the sandbox option, then takes it away again.

    God mode goes through the admin panel's own path: setGodMod on the local
    player, then sendPlayerExtraInfo, which the server accepts from a role that can
    toggle its own god mode and passes on to everyone else. It is sent from the
    first tick rather than from OnCreatePlayer, which fires before the server knows
    the player (IngameState.enter only waits for the online ID after OnGameStart).

    An admin who already had god mode on when they loaded keeps it: it is only
    switched off at the end if this file switched it on.
--]]

if not isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- Local players created and not yet protected, by player index.
local pending = {}
-- Local players in god mode from this file: { player, endsAt }, by player index.
local protected = {}

local function protectionSeconds()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars and tonumber(vars.AdminSpawnProtection) or 0
end

local function isAdmin(player)
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.ToggleGodModHimself)
end

local function restoreLocal(player)
    player:getBodyDamage():RestoreToFullHealth()
    player:setHealth(1)
end

local function setGodMode(player, on)
    player:setGodMod(on)
    sendPlayerExtraInfo(player)
end

local function onCreatePlayer(playerIndex, player)
    if not player or protectionSeconds() <= 0 then return end
    pending[playerIndex] = player
    if isAdmin(player) then restoreLocal(player) end
end

local function startProtection(playerIndex, player)
    if not isAdmin(player) then return end
    restoreLocal(player)
    if player:isGodMod() then return end
    setGodMode(player, true)
    protected[playerIndex] = {
        player = player,
        endsAt = getTimestampMs() + protectionSeconds() * 1000,
    }
end

local function onTick()
    for playerIndex, player in pairs(pending) do
        if player:getOnlineID() >= 0 then
            pending[playerIndex] = nil
            if getSpecificPlayer(playerIndex) == player then
                startProtection(playerIndex, player)
            end
        end
    end

    local now = getTimestampMs()
    for playerIndex, entry in pairs(protected) do
        local player = entry.player
        if getSpecificPlayer(playerIndex) ~= player or player:isDead() then
            protected[playerIndex] = nil
        elseif now >= entry.endsAt then
            protected[playerIndex] = nil
            if player:isGodMod() then setGodMode(player, false) end
        end
    end
end

Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnTick.Add(onTick)
