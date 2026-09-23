--[[
    Zomboid Fixes B42.20 -- server, admin spawn protection

    An admin brought back to a character that died -- by reviving it on the server
    -- loads in with that character's body exactly as it was, and dies again straight
    away. This fully restores an admin the moment they appear on the server: every
    wound healed, infection cured, stats reset (BodyDamage.RestoreToFullHealth, the
    same as the debug heal). The client file then gives them god mode for a while.

    The server has no Lua event for a player joining (OnCreatePlayer only fires on
    the client), so it watches the online list every tick. A player who connects is
    in that list before the tick that first updates them in the world, so the heal
    lands before anything can finish them off.

    The heal is applied here because the server owns health and stats; the body
    parts are synced at once, and the stats once the player exists in the world,
    which syncPlayerStats requires.

    Only for admins: anyone whose role can switch on their own god mode. Everyone
    else loads in as vanilla, so relogging is never a free heal for players.
--]]

if not isServer() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- Every body part field, as vanilla's own health cheat passes to syncBodyPart.
local ALL_BODY_PART_FIELDS = 0xFFFFFFFFFFF
-- Every stat. SyncPlayerStatsPacket only walks bits up to the number of stats, so
-- setting the rest is harmless.
local ALL_STATS = 0x7FFFFFFF

-- Usernames online as of the last tick, to notice who has just joined. Kept even
-- while the option is off, so turning it on mid-session does not treat everyone
-- already playing as new.
local online = {}
-- Healed players whose stats still have to be sent once they exist in the world.
local unsynced = {}

local function protectionSeconds()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars and tonumber(vars.AdminSpawnProtection) or 0
end

local function isAdmin(player)
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.ToggleGodModHimself)
end

local function restore(player)
    local body = player:getBodyDamage()
    body:RestoreToFullHealth()
    -- isDead() also reads the character's own health, which the body does not reset.
    player:setHealth(1)

    local parts = body:getBodyParts()
    for i = 0, parts:size() - 1 do
        syncBodyPart(parts:get(i), ALL_BODY_PART_FIELDS)
    end
    table.insert(unsynced, player)

    print("[ZomboidFixesB42] Spawn protection: fully restored admin " .. tostring(player:getUsername()))
end

local function syncPending(current)
    local still = {}
    for _, player in ipairs(unsynced) do
        if current[player:getUsername()] then
            if player:isExistInTheWorld() then
                syncPlayerStats(player, ALL_STATS)
            else
                table.insert(still, player)
            end
        end
    end
    unsynced = still
end

local function onTick()
    local enabled = protectionSeconds() > 0
    local list = getOnlinePlayers()
    local current = {}

    if list then
        for i = 0, list:size() - 1 do
            local player = list:get(i)
            local name = player and player:getUsername()
            if name then
                current[name] = true
                if enabled and not online[name] and isAdmin(player) then
                    restore(player)
                end
            end
        end
    end

    online = current
    if #unsynced > 0 then syncPending(current) end
end

Events.OnTick.Add(onTick)
