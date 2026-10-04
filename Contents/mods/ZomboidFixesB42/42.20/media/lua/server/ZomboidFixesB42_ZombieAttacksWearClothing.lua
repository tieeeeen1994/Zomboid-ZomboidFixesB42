--[[
    Zomboid Fixes B42.20 -- server, wear from blocked zombie attacks

    How vanilla wears clothing (BodyDamage.AddRandomDamageFromZombie, 42.21 ~1251):
    the attacking zombie picks a body part, then one of three things happens:

      thump     Rand.Next(100) <= baseChance: no wound, then
                addHoleFromZombieAttacks(part, scratch = true)
      blocked   a scratch, laceration or bite whose
                Rand.Next(100) < getBodyPartClothingDefense(part, bite) (summed over
                the layers, at most 100): addHoleFromZombieAttacks(part, not bite)
      through   the wound lands: addHole(part, allLayers = true), and on a client
                ZombieHitPlayerPacket to the server, which rolls it all again
                (Bite.process)

    addHoleFromZombieAttacks (IsoGameCharacter ~13939) takes the outermost layer
    covering the part and calls addHole(part) with a
    max(30, 100 - thatLayer.getDefForPart(part, bite) / 1.5) % chance;
    BloodClothingType.addHole gives the outermost unbroken layer without a hole there
    a hole and getCondLossPerHole() condition loss, or, for armor that cannot have
    holes, 1 condition with a 1 in ConditionLowerChanceOneIn chance. Both go through
    setConditionAndSync, which only works off a client (the server sends ItemStats to
    the owner); an item at 0 is taken off and dropped by Clothing.setCondition ->
    Unwear(true), which the server replicates.

    In multiplayer the roll runs on the client that owns the zombie, so thumps and
    blocked attacks never reach the server and never wear anything. The victim's
    client now reports every attack that lands on it
    (client/ZomboidFixesB42_ZombieAttacksWearClothing.lua), whoever owns the zombie,
    and this file rolls vanilla's outcome with the server's copy of the clothing:
    part, thump or blocked (scratch, laceration or bite against the server's
    defense), and for those calls vanilla's own addHoleFromZombieAttacks on the
    player, then syncVisuals so every client gets the server's holes (which also
    replaces the holes the owner's client rolled locally). A "through" roll does
    nothing here: the zombie owner's own roll decides wounds as before.

    The report is trusted for what the client sees (that the attack landed, the side
    it came from, crawling, cantBite, how many attack) but can only wear down the
    reporter's own clothing. It is checked against the server: the player alive and
    not in god mode, a zombie with that online ID within a few tiles, at most one
    report per zombie per MIN_ZOMBIE_GAP_MS and RATE_LIMIT a second per player.

    Left out of the roll: the drag-down death case (the client does not report it)
    and a zombie's private `inactive` flag (+20 to the thump chance; no getter).
    A client SyncVisuals (dirt, a fall, a weapon hit) sent before this client has the
    server's ItemStats replaces the server's holes and condition with its own, so a
    wear can be undone in that window.
--]]

if not isServer() then return end

local MODULE = ZomboidFixesB42.MODULE

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ZombieAttacksWearClothing == true
end

-- Tiles around the server's position of the player searched for the zombie.
local SEARCH_RADIUS = 3
-- An attack animation is longer than this, so two reports of one zombie inside it
-- are one attack.
local MIN_ZOMBIE_GAP_MS = 300
-- Reports a player may send a second.
local RATE_LIMIT = 10

local HAND_L = BodyPartType.ToIndex(BodyPartType.Hand_L)
local TORSO_LOWER = BodyPartType.ToIndex(BodyPartType.Torso_Lower)
local HEAD = BodyPartType.ToIndex(BodyPartType.Head)
local NECK = BodyPartType.ToIndex(BodyPartType.Neck)
local GROIN = BodyPartType.ToIndex(BodyPartType.Groin)
local UPPER_LEG_L = BodyPartType.ToIndex(BodyPartType.UpperLeg_L)
local MAX = BodyPartType.ToIndex(BodyPartType.MAX)

local SIDES = { FRONT = true, BEHIND = true, LEFT = true, RIGHT = true }

local function trunc(x)
    if x >= 0 then return math.floor(x) end
    return math.ceil(x)
end

--- Vanilla's roll up to the outcome. Returns the body part index and the
-- `scratch` argument of addHoleFromZombieAttacks for a thump or a blocked attack,
-- nil for an attack that got through (or a crawler's skipped one).
local function roll(player, side, crawling, canBite, attackers)
    local behind = side == "BEHIND"
    local leftOrRight = side == "LEFT" or side == "RIGHT"
    local rear = SandboxVars.RearVulnerability or 3

    local baseChance = 15 + player:getMeleeCombatMod() - (attackers - 1) * 10
    local biteChance = 85 - (attackers - 1) * 30
    if player:hasTrait(CharacterTrait.THICK_SKINNED) then baseChance = trunc(baseChance * 1.3) end
    if player:hasTrait(CharacterTrait.THIN_SKINNED) then baseChance = trunc(baseChance / 1.3) end
    if behind then
        baseChance, biteChance = baseChance - 15, biteChance - 25
        if rear == 1 then
            baseChance, biteChance = baseChance + 15, biteChance + 25
        elseif rear == 2 then
            baseChance, biteChance = baseChance + 7, biteChance + 17
        end
        if attackers > 2 then biteChance = biteChance - 15 end
    end
    if leftOrRight then
        baseChance, biteChance = baseChance - 30, biteChance - 7
        if rear == 1 then
            baseChance, biteChance = baseChance + 30, biteChance + 7
        elseif rear == 2 then
            baseChance, biteChance = baseChance + 15, biteChance + 4
        end
    end

    local part
    if not crawling then
        if ZombRand(10) == 0 then
            part = ZombRand(HAND_L, GROIN + 1)
        else
            part = ZombRand(HAND_L, NECK + 1)
        end
        local neckChance = 10 * attackers + (behind and 5 or 0) + (leftOrRight and 2 or 0)
        if behind and ZombRand(100) < neckChance then part = NECK end
        if part == HEAD or part == NECK then
            local percent = behind and 90 or (leftOrRight and 80 or 70)
            if ZombRand(100) > percent then
                repeat
                    part = ZombRand(TORSO_LOWER + 1)
                until part ~= HEAD and part ~= NECK and part ~= GROIN
            end
        end
    else
        if ZombRand(2) ~= 0 then return nil end
        if ZombRand(10) == 0 then
            part = ZombRand(GROIN, MAX)
        else
            part = ZombRand(UPPER_LEG_L, MAX)
        end
    end

    if ZombRand(100) <= baseChance then
        return part, true
    end
    -- Vanilla also rolls scratch or laceration first; both are checked against the
    -- scratch defense, so only the bite roll matters here.
    local bite = canBite and ZombRand(100) > biteChance
    local defense = player:getBodyPartClothingDefense(part, bite, false)
    if ZombRand(100) < defense then
        return part, not bite
    end
    return nil
end

local function findZombie(player, id)
    local square = player:getCurrentSquare()
    if not square then return nil end
    local cell = getCell()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for dz = -1, 1 do
        for dx = -SEARCH_RADIUS, SEARCH_RADIUS do
            for dy = -SEARCH_RADIUS, SEARCH_RADIUS do
                local sq = cell:getGridSquare(x + dx, y + dy, z + dz)
                if sq then
                    local objects = sq:getMovingObjects()
                    for i = 0, objects:size() - 1 do
                        local object = objects:get(i)
                        if instanceof(object, "IsoZombie") and object:getOnlineID() == id then
                            return object
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- [player online ID] = { second = whole second, count = reports in it }
local rates = {}
-- ["player:zombie"] = time of the last report
local lastReport = {}
local lastCleanup = 0

local function accept(player, zombieId)
    local now = getTimestampMs()
    local playerId = player:getOnlineID()

    local second = math.floor(now / 1000)
    local rate = rates[playerId]
    if not rate or rate.second ~= second then
        rate = { second = second, count = 0 }
        rates[playerId] = rate
    end
    rate.count = rate.count + 1
    if rate.count > RATE_LIMIT then return false end

    local key = playerId .. ":" .. zombieId
    local last = lastReport[key]
    if last and now - last < MIN_ZOMBIE_GAP_MS then return false end
    lastReport[key] = now

    if now - lastCleanup > 60000 then
        lastCleanup = now
        local stale = {}
        for k, t in pairs(lastReport) do
            if now - t > 10000 then stale[#stale + 1] = k end
        end
        for _, k in ipairs(stale) do lastReport[k] = nil end
    end
    return true
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= ZomboidFixesB42.CMD_ZOMBIE_ATTACK_WEAR then return end
    if not isEnabled() or not player or type(args) ~= "table" then return end
    if player:isDead() or player:isGodMod() then return end

    local zombieId = tonumber(args.zombie)
    if not zombieId or not SIDES[args.side] then return end
    local attackers = tonumber(args.attackers) or 1
    attackers = math.max(1, math.min(10, math.floor(attackers)))
    if not accept(player, zombieId) then return end

    local zombie = findZombie(player, zombieId)
    if not zombie or zombie:isDead() then return end

    local part, scratch = roll(player, args.side, args.crawling == true, args.canBite ~= false, attackers)
    if not part then return end
    player:addHoleFromZombieAttacks(BloodBodyPartType.FromIndex(part), scratch)
    player:syncVisuals()
end

Events.OnClientCommand.Add(onClientCommand)
