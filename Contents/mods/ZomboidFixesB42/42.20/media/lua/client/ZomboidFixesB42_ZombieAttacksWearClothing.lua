--[[
    Zomboid Fixes B42.20 -- client, wear from blocked zombie attacks

    In single player, worn clothing loses condition from zombie attacks it stops.
    In multiplayer it never does, so armor with high defense is effectively
    unbreakable on a server. See server/ZomboidFixesB42_ZombieAttacksWearClothing.lua
    for vanilla's roll and what the server does with a report.

    Who sees the attack (42.21): the whole roll (BodyDamage.AddRandomDamageFromZombie)
    runs on the client that owns the zombie, from AttackState's "AttackCollisionCheck"
    anim event, on that client's copy of the victim. When the victim's own client
    owns the zombie, a stopped attack adds holes on its own copy and changes no
    condition (setConditionAndSync does nothing on a client). When another player's
    client owns it, the holes land on that client's copy of the victim, no Lua event
    fires (IsoGameCharacter.addHole fires OnClothingUpdated only for a local player),
    and the victim's client runs AttackNetworkState, which only plays the scratch or
    bite sound. Either way only an attack that gets through reaches the server
    (ZombieHitPlayerPacket). An earlier version of this fix read the victim's own
    OnClothingUpdated and so missed every attack by a zombie another client owned,
    which in a group is most of them.

    So the victim's client is the source of the hit: it watches every zombie
    targeting a local player, its own (AttackState) and other clients' (remote,
    AttackNetworkState), and reports each attack that lands. Both states set the
    zombie's attack outcome to "success" at the "SetAttackOutcome" anim event, just
    before the collision check (AttackState: the zombie's bAttack; AttackNetworkState:
    the owner's outcome), so a change to "success" is one attack. It is reported when
    vanilla's triggerPlayerReaction would let it land on this client's view: in reach
    (1.0, crawlers 1.3), same floor, nothing between the two squares
    (IsoGridSquare.isSomethingTo), the player not attacking or shoving toward it, not
    on the floor, not being dragged down. The report carries what only this client
    knows for sure: which side the zombie hit from (testDotSide), whether it crawls or
    cannot bite, and how many zombies are attacking. The server rolls the rest on its
    own copy of the clothing.

    Left out: zombies feigning death (FakeDeadAttackState) and attacks on a player in
    a vehicle, which do not go through the attack outcome.
--]]

if not isClient() then return end

local MODULE = ZomboidFixesB42.MODULE

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ZombieAttacksWearClothing == true
end

-- Reach of AttackState.triggerPlayerReaction (1.0, crawlers 1.3), with a little slack.
local REACH = 1.05
local REACH_CRAWLER = 1.35
-- Squares around the player searched for attackers.
local SCAN_RADIUS = 2

-- [player number] = { [zombie online ID] = attack outcome last seen }
local outcomes = {}

--- Whether vanilla would let this attack land, as this client sees it.
local function landsOn(player, zombie)
    if player:isDead() or player:isOnFloor() or player:isGodMod() then return false end
    if player:getVehicle() or zombie:isNoTeeth() then return false end
    if player:getHitReaction() == "EndDeath" then return false end
    if math.abs(zombie:getZ() - player:getZ()) >= 0.2 then return false end
    if zombie:DistTo(player) > (zombie:isCrawling() and REACH_CRAWLER or REACH) then return false end

    local side = player:testDotSide(zombie)
    local front = side == "FRONT"
    local aimAtFloor = player:isAimAtFloor()
    local attackType = player:getVariableString("AttackType")
    if front and not aimAtFloor and attackType ~= nil and attackType ~= "" then return false end
    if player:isDoShove() then
        if front and not aimAtFloor then return false end
        if (side == "LEFT" or side == "RIGHT") and ZombRand(100) > 75 then return false end
    end

    local from, to = zombie:getCurrentSquare(), player:getCurrentSquare()
    if not from or not to or to:isSomethingTo(from) then return false end
    return true, side
end

local function report(player, zombie, side)
    sendClientCommand(player, MODULE, ZomboidFixesB42.CMD_ZOMBIE_ATTACK_WEAR, {
        zombie = zombie:getOnlineID(),
        side = side,
        crawling = zombie:isCrawling(),
        canBite = not zombie:cantBite(),
        attackers = math.max(1, player:getSurroundingAttackingZombies()),
    })
end

local function scan(player)
    local num = player:getPlayerNum()
    local before = outcomes[num] or {}
    local now = {}
    outcomes[num] = now

    local square = player:getCurrentSquare()
    if not square or player:isDead() then return end
    local cell = getCell()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for dx = -SCAN_RADIUS, SCAN_RADIUS do
        for dy = -SCAN_RADIUS, SCAN_RADIUS do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq then
                local objects = sq:getMovingObjects()
                for i = 0, objects:size() - 1 do
                    local zombie = objects:get(i)
                    if instanceof(zombie, "IsoZombie") and zombie:getTarget() == player then
                        local id = zombie:getOnlineID()
                        local outcome = zombie:getAttackOutcome() or ""
                        now[id] = outcome
                        local last = before[id]
                        -- A zombie first seen mid-attack is not counted: it may
                        -- have been seen landing it already.
                        if outcome == "success" and last ~= nil and last ~= "success" then
                            local lands, side = landsOn(player, zombie)
                            if lands then report(player, zombie, side) end
                        end
                    end
                end
            end
        end
    end
end

local function onPlayerUpdate(player)
    if not isEnabled() or not player:isLocalPlayer() then return end
    scan(player)
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)
