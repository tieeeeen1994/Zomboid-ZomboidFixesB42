--[[
    Zomboid Fixes B42.20 -- client, admin tag

    The red admin tag over a staff member's head is decided by
    IsoPlayer.calculateShowAdminTag(), which shows it if any of these are on:

        invisible, god mode, ghost mode, noclip, instant timed actions,
        unlimited carry, unlimited endurance, build, farming, fishing, health,
        mechanics, movables, see all, hear all, zombies don't attack

    The admin panel's own help text says "If nothing in the list is selected the red
    Admin tag above your head won't be displayed" -- but the list has nine cheats that
    calculation never looks at: fast move, unlimited ammo, know all recipes, brush
    tool, LootZed, loot log, animal cheats, animal extra values and always day. Turn
    one of those on by itself and nobody can tell.

    Why this is a per-tick override rather than a one-off set: the tag is not stored,
    it is recomputed. IsoGameCharacter.updateInternal() runs every tick for every
    player and does

        if role has Capability.ToggleWriteRoleNameAbove then
            setShowAdminTag(calculateShowAdminTag())
        else
            setShowAdminTag(false)

    so anything set from Lua is overwritten the next frame. It is read back in a
    separate phase, renderlast() -> updateUserName(). IngameState.updateInternal runs
    IsoWorld.update() -- where every character recomputes -- before it fires OnTick,
    and rendering comes after both, so a value set in OnTick is the one that gets
    drawn.

    This runs on each client for every player it can see, because that is where the
    tag is computed and drawn. The cheat flags it reads are the per-player ones that
    ExtraInfoPacket replicates, not the admin panel's client-side globals such as
    ISBuildMenu.cheat, which only describe the local player.

    With AdminTagEveryCheat off and HideAdminTag off this does nothing, and the
    tag is vanilla's own calculation again from the next tick.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- One getter per cheat in ISAdminPowerUI, in the panel's own order. Kept to the
-- replicated per-player flags so the answer is right for other players as well as
-- for yourself.
local CHEAT_GETTERS = {
    "isInvisible",
    "isGodMod",
    "isNoClip",
    "isFastMoveCheat",
    "isTimedActionInstantCheat",
    "isUnlimitedCarry",
    "isUnlimitedEndurance",
    "isUnlimitedAmmo",
    "isKnowAllRecipes",
    "isBuildCheat",
    "isFarmingCheat",
    "isFishingCheat",
    "isHealthCheat",
    "isMechanicsCheat",
    "isMovablesCheat",
    "canSeeAll",
    "canHearAll",
    "isZombiesDontAttack",
    "isCanUseBrushTool",
    "canUseLootZed",
    "canUseLootLog",
    "isAnimalCheat",
    "isAnimalExtraValuesCheat",
    "isAlwaysDayCheat",
}

local function hideTagSetting()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.HideAdminTag == true
end

local function everyCheatSetting()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.AdminTagEveryCheat == true
end

local function hasAnyCheat(player)
    -- Vanilla's own answer first. It also counts ghost mode, which is not on the
    -- panel, and anything a later build adds to it.
    if player:calculateShowAdminTag() then return true end

    for _, getter in ipairs(CHEAT_GETTERS) do
        local method = player[getter]
        if method and method(player) then
            return true
        end
    end
    return false
end

local function shouldShowTag(player, hidden)
    -- Same gate vanilla applies: without this capability the tag is never shown.
    local role = player:getRole()
    local capability = Capability.ToggleWriteRoleNameAbove
    if not role or not capability or not role:hasCapability(capability) then
        return false
    end

    if hidden then return false end

    return hasAnyCheat(player)
end

local function applyTo(player, hidden)
    if not player or instanceof(player, "IsoAnimal") then return end

    local show = shouldShowTag(player, hidden)
    if player:isShowAdminTag() ~= show then
        player:setShowAdminTag(show)
    end
end

local function onTick()
    local hidden = hideTagSetting()
    if not hidden and not everyCheatSetting() then return end

    -- Everyone this client knows about. Empty in single player.
    local online = getOnlinePlayers()
    if online then
        for i = 0, online:size() - 1 do
            applyTo(online:get(i), hidden)
        end
    end

    -- Local players, which covers single player and split screen.
    for i = 0, getNumActivePlayers() - 1 do
        applyTo(getSpecificPlayer(i), hidden)
    end
end

Events.OnTick.Add(onTick)
