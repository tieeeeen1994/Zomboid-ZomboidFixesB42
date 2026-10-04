--[[
    Zomboid Fixes B42.20 -- client, wear from blocked zombie attacks

    In single player, worn clothing loses condition from zombie attacks it stops.
    In multiplayer it never does, so armor with high defense is effectively
    unbreakable on a server.

    How vanilla wears clothing (BodyDamage.AddRandomDamageFromZombie, 42.21 ~1251):
    the attacking zombie picks a body part, then one of three things happens:

      thump     Rand.Next(100) <= baseChance: no wound, then
                addHoleFromZombieAttacks(part, scratch)
      blocked   a scratch, laceration or bite whose
                Rand.Next(100) < getBodyPartClothingDefense(part) (summed over the
                layers, at most 100): addHoleFromZombieAttacks(part, ...), return
      through   the wound lands: addHole(part, allLayers = true)

    addHoleFromZombieAttacks (IsoGameCharacter ~13939) takes the outermost layer
    covering the part and calls addHole(part) with a
    max(30, 100 - thatLayer.getDefForPart(part, bite) / 1.5) % chance.
    addHole -> BloodClothingType.addHole (~140) takes the outermost layer that
    covers the part, is not broken and has no hole there. If it can have holes, it
    gets one and loses getCondLossPerHole() condition. If it cannot (all hard
    armor), it loses 1 condition with a 1 in ConditionLowerChanceOneIn chance.
    Both condition changes go through setConditionAndSync, which does nothing on a
    client.

    In multiplayer this whole function runs on the client that owns the zombie
    (AttackState.animEvent "AttackCollisionCheck"; zombies another client owns run
    AttackNetworkState and never call it). Only the "through" case sends
    ZombieHitPlayerPacket, and the server then rolls the whole attack again
    (Bite.process). Thumps and blocked hits are never sent, so the server never
    hears of them, and the client's own roll changes no condition. A part whose
    armor has 100 defense is always blocked, so it never wears out at all, and
    80 defense wears about five times more slowly than in single player.

    What Lua can see: IsoGameCharacter.addHole fires OnClothingUpdated
    synchronously for a local player, so the event arrives inside the attack, once
    per hole attempt. The client's random numbers (which part, which layer, the
    1 in N roll) are not visible, and the zombie's AttackDidDamage variable does
    not help either (a thump returns true too). So this file rebuilds the attack
    from vanilla's own formulas, weighs every way it could have produced this
    event, and picks one:

      - the candidates are this client's zombies in AttackState (also
        FakeDeadAttackState, or any attacking zombie while the player is in a
        vehicle) targeting the player within reach;
      - for each candidate and body part: the chance the zombie picked that part
        (front, side or behind, crawling, neck and head rerolls), the chance of a
        thump, a blocked scratch or a blocked bite, and of the hole attempt,
        against the defense the player had just before the event;
      - what each case would have done to the layers (a new hole on one layer, on
        every layer, on the body visual, or nothing), compared with what really
        changed since the snapshot taken every frame while a zombie is attacking.
        Cases that do not match are dropped, so a new hole names its part and
        layer exactly, and only the hard armor case is left to chance;
      - "through" cases count in the weighing but do nothing when picked: the
        server's own roll handles them.

    The picked case is then finished the way vanilla's server would have: a hole
    costs getCondLossPerHole(), and armor loses 1 condition with a 1 in
    getConditionLowerChance() chance. The client lowers its own copy and calls
    syncVisuals(). SyncVisualsPacket carries every worn item's condition and the
    server applies it (setConditionNoSound), and it is ordered with the client's
    later ZombieHitPlayer packets, so the server's own re-rolls start from the
    worn-down value. An item worn down to 0 is handled by the Sync Broken Clothing
    fix (client/ZomboidFixesB42_BrokenClothing.lua) like any other break that
    happens on the client; without that fix it is dropped on this client only, as
    vanilla does with every client-side break.

    Left out: the drag-down death case, a zombie's private `inactive` flag (+20 to
    the thump chance; no getter), and clothing patches under a hole the event
    itself made. Weapon hits from other players (BodyDamage.DamageFromWeapon)
    have the same problem but are not handled here.
--]]

if not isClient() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ZombieAttacksWearClothing == true
end

local NUM_PARTS = BodyPartType.ToIndex(BodyPartType.MAX)
local TORSO_LOWER = BodyPartType.ToIndex(BodyPartType.Torso_Lower)
local HEAD = BodyPartType.ToIndex(BodyPartType.Head)
local NECK = BodyPartType.ToIndex(BodyPartType.Neck)
local GROIN = BodyPartType.ToIndex(BodyPartType.Groin)
local UPPER_LEG_L = BodyPartType.ToIndex(BodyPartType.UpperLeg_L)

-- Reach of the attack checks (AttackState.triggerPlayerReaction: 1.0, crawlers
-- 1.3; FakeDeadAttackState: a 1.5 cone), with a little slack.
local REACH = 1.05
local REACH_CRAWLER = 1.35
local REACH_FAKE_DEAD = 1.6

local function trunc(x)
    if x >= 0 then return math.floor(x) end
    return math.ceil(x)
end

--- P(Rand.Next(100) < x).
local function chanceBelow(x)
    return math.max(0, math.min(100, math.ceil(x))) / 100
end

--- P(Rand.Next(100) > x), x an integer.
local function chanceAbove(x)
    return math.max(0, math.min(100, 99 - x)) / 100
end

-- Covered body part indices per item script, { [index] = true } or false.
-- BloodLocation can be changed by item fixes, so this is emptied now and then.
local coveredCache = {}

local function coveredParts(scriptItem)
    local key = scriptItem:getFullName()
    local cached = coveredCache[key]
    if cached ~= nil then return cached end

    local result = false
    local types = scriptItem:getBloodClothingType()
    if types then
        local parts = BloodClothingType.getCoveredParts(types)
        if parts and parts:size() > 0 then
            result = {}
            for i = 0, parts:size() - 1 do
                result[parts:get(i):index()] = true
            end
        end
    end
    coveredCache[key] = result
    return result
end

local visualsBuffer = nil

--- The player's layers in vanilla's order (outermost last), with their holes,
-- plus the holes on the body visual.
local function takeSnapshot(player)
    visualsBuffer = visualsBuffer or ItemVisuals.new()
    player:getItemVisuals(visualsBuffer)

    local layers = {}
    local ids = {}
    for i = 0, visualsBuffer:size() - 1 do
        local visual = visualsBuffer:get(i)
        local scriptItem = visual:getScriptItem()
        local item = visual:getInventoryItem()
        local clothing = item and instanceof(item, "Clothing") and item or nil
        local layer = {
            visual = visual,
            item = item,
            clothing = clothing,
            covered = scriptItem and coveredParts(scriptItem) or false,
            holes = {},
            -- Lua cannot read the script's canHaveHoles for a non-clothing layer
            -- (a bag); the script default is true.
            canHaveHoles = clothing == nil or clothing:getCanHaveHoles() == true,
            hasScript = scriptItem ~= nil,
        }
        if layer.covered then
            for p in pairs(layer.covered) do
                if visual:getHole(BloodBodyPartType.FromIndex(p)) > 0 then
                    layer.holes[p] = true
                end
            end
        end
        layers[#layers + 1] = layer
        ids[#ids + 1] = item and tostring(item:getID()) or "-"
    end

    local human = {}
    local humanVisual = player:getHumanVisual()
    if humanVisual then
        for p = 0, NUM_PARTS - 1 do
            if humanVisual:getHole(BloodBodyPartType.FromIndex(p)) > 0 then
                human[p] = true
            end
        end
    end

    return { layers = layers, human = human, key = table.concat(ids, ",") }
end

--- Holes that appeared since `before`, as a sorted string ("L3:8 H8").
local function observedChange(before, after)
    local changes = {}
    for i, layer in ipairs(after.layers) do
        for p in pairs(layer.holes) do
            if not before.layers[i].holes[p] then
                changes[#changes + 1] = "L" .. i .. ":" .. p
            end
        end
    end
    for p in pairs(after.human) do
        if not before.human[p] then
            changes[#changes + 1] = "H" .. p
        end
    end
    table.sort(changes)
    return table.concat(changes, " ")
end

--- A layer's defense on a part just before the event (Clothing.getDefForPart).
local function defenseBefore(layer, afterLayer, p, bite)
    local item = layer.clothing
    if not item or layer.holes[p] then return 0 end
    if not afterLayer.holes[p] then
        return item:getDefForPart(BloodBodyPartType.FromIndex(p), bite, false)
    end
    -- The event itself made this hole, so getDefForPart now reads 0.
    local defense = bite and item:getBiteDefense() or item:getScratchDefense()
    local modifier = item:getNeckProtectionModifier()
    if p == NECK and modifier < 1 then
        defense = defense * modifier
    end
    return defense
end

--- IsoGameCharacter.getBodyPartClothingDefense, before the event.
local function partDefense(before, after, p, bite)
    local total = 0
    for i, layer in ipairs(before.layers) do
        if layer.clothing and layer.covered and layer.covered[p] and not layer.holes[p] then
            total = total + defenseBefore(layer, after.layers[i], p, bite)
        end
    end
    return math.min(100, total)
end

--- The chance addHoleFromZombieAttacks goes on to addHole.
local function holeAttemptChance(before, after, p, bite)
    for i = #before.layers, 1, -1 do
        local layer = before.layers[i]
        if layer.covered and layer.covered[p] then
            if not layer.clothing then return 0 end
            return chanceBelow(math.max(30, 100 - defenseBefore(layer, after.layers[i], p, bite) / 1.5))
        end
    end
    return 0
end

local function canTakeHole(layer, p)
    if not layer.hasScript or not layer.covered or not layer.covered[p] or layer.holes[p] then return false end
    return layer.item == nil or not layer.item:isBroken()
end

--- What addHole(p) on one layer would change, and the layer it hits.
local function singleLayerEffect(before, p)
    for i = #before.layers, 1, -1 do
        local layer = before.layers[i]
        if canTakeHole(layer, p) then
            if layer.canHaveHoles then
                return "L" .. i .. ":" .. p, layer
            end
            return "", layer
        end
    end
    if before.human[p] then return "", nil end
    return "H" .. p, nil
end

--- What addHole(p, allLayers = true) would change.
local function allLayersEffect(before, p)
    local changes = {}
    for i = #before.layers, 1, -1 do
        local layer = before.layers[i]
        if canTakeHole(layer, p) and layer.canHaveHoles then
            changes[#changes + 1] = "L" .. i .. ":" .. p
        end
    end
    if not before.human[p] then
        changes[#changes + 1] = "H" .. p
    end
    table.sort(changes)
    return table.concat(changes, " ")
end

--- The chance the zombie picked each body part (AddRandomDamageFromZombie,
-- partIndex < 0). A crawler gives up half its attacks (Rand.Next(2)) before
-- picking, so it is half as likely to be the one behind an event.
local function partChances(zombie, behind, leftOrRight, attackers)
    local chances = {}
    for p = 0, NUM_PARTS - 1 do chances[p] = 0 end

    if zombie:isCrawling() then
        for p = GROIN, NUM_PARTS - 1 do
            chances[p] = chances[p] + 0.05 / (NUM_PARTS - GROIN)
        end
        for p = UPPER_LEG_L, NUM_PARTS - 1 do
            chances[p] = chances[p] + 0.45 / (NUM_PARTS - UPPER_LEG_L)
        end
        return chances
    end

    for p = 0, GROIN do
        chances[p] = chances[p] + 0.1 / (GROIN + 1)
    end
    for p = 0, NECK do
        chances[p] = chances[p] + 0.9 / (NECK + 1)
    end

    if behind then
        local neck = chanceBelow(10 * attackers + 5)
        for p = 0, NUM_PARTS - 1 do
            chances[p] = chances[p] * (1 - neck)
        end
        chances[NECK] = chances[NECK] + neck
    end

    local percent = behind and 90 or (leftOrRight and 80 or 70)
    local reroll = chanceAbove(percent)
    local moved = (chances[HEAD] + chances[NECK]) * reroll
    chances[HEAD] = chances[HEAD] * (1 - reroll)
    chances[NECK] = chances[NECK] * (1 - reroll)
    for p = 0, TORSO_LOWER do
        chances[p] = chances[p] + moved / (TORSO_LOWER + 1)
    end
    return chances
end

--- Contact and bite chances of one zombie's attack on the player.
local function attackChances(player, zombie, attackers)
    local side = player:testDotSide(zombie)
    local behind = side == "BEHIND"
    local leftOrRight = side == "LEFT" or side == "RIGHT"
    local rear = SandboxVars and SandboxVars.RearVulnerability or 3

    local baseChance = 15 + player:getMeleeCombatMod() - (attackers - 1) * 10
    local biteChance = 85 - (attackers - 1) * 30
    if player:hasTrait(CharacterTrait.THICK_SKINNED) then
        baseChance = trunc(baseChance * 1.3)
    end
    if player:hasTrait(CharacterTrait.THIN_SKINNED) then
        baseChance = trunc(baseChance / 1.3)
    end
    if behind then
        baseChance = baseChance - 15
        biteChance = biteChance - 25
        if rear == 1 then
            baseChance = baseChance + 15
            biteChance = biteChance + 25
        elseif rear == 2 then
            baseChance = baseChance + 7
            biteChance = biteChance + 17
        end
        if attackers > 2 then
            biteChance = biteChance - 15
        end
    end
    if leftOrRight then
        baseChance = baseChance - 30
        biteChance = biteChance - 7
        if rear == 1 then
            baseChance = baseChance + 30
            biteChance = biteChance + 7
        elseif rear == 2 then
            baseChance = baseChance + 15
            biteChance = biteChance + 4
        end
    end

    local contact = chanceAbove(baseChance)
    local bite = zombie:cantBite() and 0 or chanceAbove(biteChance)
    return contact, bite, behind, leftOrRight
end

local function canHitNow(zombie, player)
    if zombie:getTarget() ~= player or zombie:isRemoteZombie() then return false end
    local distance = zombie:DistTo(player)
    if zombie:isCurrentState(AttackState.instance()) then
        return distance <= (zombie:isCrawling() and REACH_CRAWLER or REACH)
    end
    if zombie:isCurrentState(FakeDeadAttackState.instance()) then
        return distance <= REACH_FAKE_DEAD
    end
    -- AttackVehicleState is not exposed to Lua.
    return player:getVehicle() ~= nil and zombie:isAttacking()
end

--- This client's zombies that could be hitting the player right now. With
-- firstOnly, stops at the first one.
local function attackingZombies(player, firstOnly)
    local result = {}
    local square = player:getCurrentSquare()
    if not square then return result end

    local radius = player:getVehicle() and 2 or 1
    local cell = getCell()
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(x + dx, y + dy, z)
            if sq then
                local objects = sq:getMovingObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if instanceof(object, "IsoZombie") and canHitNow(object, player) then
                        result[#result + 1] = object
                        if firstOnly then return result end
                    end
                end
            end
        end
    end
    return result
end

--- Every way the event could have happened, with its weight. Each entry is
-- { weight, layer } where layer is the one to wear, or nil for a case that wears
-- nothing here (the hit went through, or hit no clothing).
local function weighCases(player, zombies, before, after, observed)
    local cases = {}
    local total = 0
    local attackers = math.max(1, player:getSurroundingAttackingZombies())

    for _, zombie in ipairs(zombies) do
        local contact, bite, behind, leftOrRight = attackChances(player, zombie, attackers)
        local parts = partChances(zombie, behind, leftOrRight, attackers)
        for p = 0, NUM_PARTS - 1 do
            local pick = parts[p]
            if pick > 0 then
                local scratchBlock = chanceBelow(partDefense(before, after, p, false))
                local biteBlock = chanceBelow(partDefense(before, after, p, true))
                local scratchAttempt = holeAttemptChance(before, after, p, false)
                local biteAttempt = holeAttemptChance(before, after, p, true)

                local effect, layer = singleLayerEffect(before, p)
                if effect == observed then
                    local weight = pick * ((1 - contact) * scratchAttempt
                        + contact * (1 - bite) * scratchBlock * scratchAttempt
                        + contact * bite * biteBlock * biteAttempt)
                    if weight > 0 then
                        cases[#cases + 1] = { weight = weight, layer = layer }
                        total = total + weight
                    end
                end

                if allLayersEffect(before, p) == observed then
                    local weight = pick * contact * ((1 - bite) * (1 - scratchBlock) + bite * (1 - biteBlock))
                    if weight > 0 then
                        cases[#cases + 1] = { weight = weight, layer = nil }
                        total = total + weight
                    end
                end
            end
        end
    end
    return cases, total
end

local function pickCase(cases, total)
    local roll = ZombRandFloat(0, total)
    for _, case in ipairs(cases) do
        roll = roll - case.weight
        if roll <= 0 then return case end
    end
    return cases[#cases]
end

--- Finish the hole attempt as BloodClothingType.addHole does on a server.
-- Returns true when the condition changed.
local function wearLayer(layer)
    local item = layer.clothing
    if not item or item:getCondition() <= 0 then return false end

    local condition = item:getCondition()
    if layer.canHaveHoles then
        condition = trunc(condition - item:getCondLossPerHole())
    else
        -- Rand.NextBool(n) is always true for n <= 1.
        local oneIn = item:getConditionLowerChance()
        if oneIn > 1 and ZombRand(oneIn) ~= 0 then return false end
        condition = condition - 1
    end
    item:setCondition(math.max(0, condition))
    return true
end

-- The last snapshot per local player number, kept only while a zombie can hit.
local snapshots = {}

local function onClothingUpdated(character)
    if not isEnabled() then return end
    if not instanceof(character, "IsoPlayer") or not character:isLocalPlayer() or character:isDead() then return end

    local num = character:getPlayerNum()
    local before = snapshots[num]
    if not before then return end

    local after = takeSnapshot(character)
    snapshots[num] = after
    -- Something put on or taken off: not a hole attempt.
    if after.key ~= before.key then return end

    local zombies = attackingZombies(character, false)
    if #zombies == 0 then return end

    local observed = observedChange(before, after)
    local cases, total = weighCases(character, zombies, before, after, observed)
    if total <= 0 then return end

    local case = pickCase(cases, total)
    if not case.layer then return end

    local item = case.layer.clothing
    local old = item and item:getCondition()
    if wearLayer(case.layer) then
        print("[ZomboidFixesB42] blocked hit wore " .. item:getFullType() .. " " .. tostring(old)
            .. " -> " .. tostring(item:getCondition()))
        -- Right away, while the item is still worn: once it is taken off (a
        -- break), the server rejects a SyncVisuals with fewer worn items.
        character:syncVisuals()
    end
end

local function onPlayerUpdate(player)
    if not isEnabled() or not player:isLocalPlayer() then return end
    local num = player:getPlayerNum()
    if player:isDead() or #attackingZombies(player, true) == 0 then
        snapshots[num] = nil
    else
        snapshots[num] = takeSnapshot(player)
    end
end

Events.OnClothingUpdated.Add(onClothingUpdated)
Events.OnPlayerUpdate.Add(onPlayerUpdate)
Events.EveryTenMinutes.Add(function()
    coveredCache = {}
end)
