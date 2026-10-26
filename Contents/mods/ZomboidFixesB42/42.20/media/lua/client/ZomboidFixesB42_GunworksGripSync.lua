--[[
    Zomboid Fixes B42.20 -- client, Gunworks held-pose animations come back on rebuilt characters

    Gunworks (workshop 3722064198, WeaponSystems/Utils/GripAnim.lua) lets a gun mod give a gun a held pose of its own:
    while a registered gun is in the primary hand it sets the animation variable GunworksGripAnim to the gun's animId,
    and the mod's AnimSet nodes gate on it (Heavy Ordnance's RPG, Guns of Tien's short SMG stance). It derives the
    variable for the local player from OnPlayerUpdate and for remote players from an OnTick sweep, and writes it only
    when it changes:

        local lastGripByOnlineId = {}
        ...
        if lastGripByOnlineId[onlineId] == desired then return end
        lastGripByOnlineId[onlineId] = desired
        player:setVariable(GripAnim.ANIM_VARIABLE, desired)

    The cache remembers the last value per online ID, not per character. An animation variable lives on the IsoPlayer
    object, and the game builds a new one with the same online ID in several cases:
    - a remote player leaves the client's range: GameClient.timeoutRemotePlayers drops them after 5 s without a
      PlayerPacket, and the next packet rebuilds them (ConnectedPacket);
    - a player relogs, or another player is given the same ID;
    - a respawn, or loading another world without the game reloading its Lua;
    - split-screen players, who share one ID.
    The new character holds the same gun, the cache says the variable is already set, and it is never written: other
    players see the gun in vanilla's nodes (a gun turned upright for its own pose then sits off the hands, an RPG is
    held like a rifle) until its holder changes weapons. Gunworks' reload selector (ReloadAnim/Sync.lua) had the same
    problem and compares against the variable on the character instead; the grip does not.

    So every few ticks each local player, and on a client every player it has loaded, is compared the same way:
    the grip Gunworks would choose (GripAnim.GetGripForGun, its own lookup) against the variable the character really
    has, and a mismatch is written. Gunworks' own pass still does every change of weapon; this only repairs the
    characters its cache skipped. Does nothing unless Gunworks is loaded.
--]]

local VARIABLE = "GunworksGripAnim"
local EVERY_TICKS = 10

local GripAnim = nil
local ticks = 0

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.GunworksGripSync == true
end

local function syncPlayer(player)
    if not player then return end
    local handler = GripAnim.GetGripForGun(player:getPrimaryHandItem())
    local want = handler and handler.animId or ""
    local have = player:getVariableString(VARIABLE) or ""
    if want == have then return end
    if want ~= "" then
        player:setVariable(VARIABLE, want)
    else
        player:clearVariable(VARIABLE)
    end
end

local function onTick()
    ticks = ticks + 1
    if ticks < EVERY_TICKS then return end
    ticks = 0
    if not isEnabled() then return end
    for i = 0, getNumActivePlayers() - 1 do
        syncPlayer(getSpecificPlayer(i))
    end
    if isClient() then
        local players = getOnlinePlayers()
        if players then
            for i = 0, players:size() - 1 do
                syncPlayer(players:get(i))
            end
        end
    end
end

local function onGameStart()
    local ok, module = pcall(require, "WeaponSystems/Utils/GripAnim")
    if not ok or type(module) ~= "table" or type(module.GetGripForGun) ~= "function" then return end
    GripAnim = module
    Events.OnTick.Remove(onTick)
    Events.OnTick.Add(onTick)
end

Events.OnGameStart.Add(onGameStart)
