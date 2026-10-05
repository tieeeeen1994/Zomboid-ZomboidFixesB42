--[[
    Zomboid Fixes B42.20 -- client, clothing wear down rework

    In single player, worn clothing loses condition from the zombie attacks it stops,
    and clothing torn down to nothing comes off and lands on the floor. In
    multiplayer neither works. Here each player's own game rolls every zombie attack
    that lands on it and sends each one to the server as its own event; the server
    applies the events to its copy of the clothing with vanilla's code and syncs the
    result to everyone (server/ZomboidFixesB42_ClothingWear.lua). Events add up, so
    their order does not matter and none replaces another.

    1. Wear from zombie attacks

    BodyDamage.AddRandomDamageFromZombie (42.21 ~1252) picks a body part, then:

      thump     Rand.Next(100) <= baseChance: no wound, then
                addHoleFromZombieAttacks(part, scratch = true)
      blocked   a scratch, laceration or bite whose
                Rand.Next(100) < getBodyPartClothingDefense(part, bite):
                addHoleFromZombieAttacks(part, not bite)
      through   the wound lands: addHole(part, allLayers = true), and on a client
                ZombieHitPlayerPacket to the server, which rolls it all again
                (Bite.process) and wears the clothing on its own copy

    The condition loss in there (BloodClothingType.setConditionAndSync: a hole costs
    getCondLossPerHole, armor that cannot have holes 1 in ConditionLowerChanceOneIn)
    does nothing on a client. The whole roll runs on the client that owns the
    zombie, from AttackState's "AttackCollisionCheck" anim event, on that client's
    copy of the victim. So in multiplayer a thump or a blocked attack never costs
    condition: by the victim's own zombie it adds holes on the victim's game only; by
    a zombie another player's game runs it lands on that game's copy of the victim,
    and the victim gets nothing at all (AttackNetworkState only plays the sound).
    Only a wound reaches the server.

    So the victim's game rolls it. Every zombie targeting a local player, its own
    (AttackState) and other games' (AttackNetworkState), sets its attack outcome to
    "success" at the "SetAttackOutcome" anim event, at the end of the start anim; the
    success anim (not looped) holds the collision check and ends with
    ZombieBiteDone=true, after which the state is left and the next swing starts
    over at "start". So a change to "success" is one swing. When vanilla's
    triggerPlayerReaction would let it land on this game's view (in reach, same
    floor, nothing between the squares, the player not attacking or shoving toward
    it, not on the floor), this file rolls vanilla's outcome with the local clothing
    (side, attackers, traits, defense) and, for a thump or a blocked attack, sends
    clothingWear { zombie, part, scratch }. A "through" roll sends nothing: wounds and
    the wear that comes with them stay with the zombie's owner and the server.

    The event leaves when the swing ends (ZombieBiteDone, or the outcome leaving
    "success"), after the collision check. That matters for the victim's own
    zombies, whose vanilla roll also runs here and adds holes with no condition: the
    server's sync that answers the event then replaces them. A swing whose vanilla
    roll changed the clothing (OnClothingUpdated with getAttackedBy() that zombie)
    but which this file rolled as a wound sends an event with no part, which only
    asks for that sync. Nothing here changes the local clothing.

    Left out: zombies feigning death (FakeDeadAttackState), attacks on a player in a
    vehicle, the drag-down death, and a zombie's private `inactive` flag (+20 to the
    thump chance; no getter). The wound (vanilla's roll, rolled again on the server)
    and the wear (this roll) are separate rolls with the same odds, so one swing can
    be both or neither; on average the wear matches single player.

    2. Broken clothing

    Worn clothing that reaches condition 0 is taken off and dropped by
    Clothing.setCondition() -> Unwear(true):

        c.removeWornItem(this)
        triggerEvent("OnClothingUpdated", c)
        if drop and not in a vehicle:
            if GameServer.server: sendRemoveItemFromContainer(...)
            c.getInventory().Remove(this)
            square.AddWorldInventoryItem(this, ...)    -- only transmits on the server

    The wear above breaks items on the server, which replicates all of it. A break
    on a client would leave a broken item on that client's floor that exists nowhere
    else, while the server keeps it worn and intact, which comes back on relog.

    The drop only happens when the item's removeOnBroken flag is set, and nothing
    else reads that flag. It comes from the item script when the item is created and
    is neither saved nor networked, so clearing it on the client's copy of worn
    clothing changes nothing for the server or anyone else. The client then keeps a
    broken item instead of dropping it, takes it off without dropping it, and reports
    the break. The server drops its own copy and replicates that to everyone,
    including this client.

    Taking it off locally straight away matters: every sync sends SyncClothing with
    the client's worn list, and when the server gets a worn item it does not have in
    the inventory, it creates a new one with that ID and puts it on.

    3. Worn ghosts

    When the server breaks an item, vanilla's server-side Unwear sends SyncClothing
    without it, but a SyncClothing this client sent a moment earlier, still listing
    it, can cross it. The server then creates a copy (SyncClothingPacket.process:
    CreateItem + setID, worn but in no inventory) and echoes its list back, and this
    client does the same: the item is no longer in its inventory, so it creates one
    too. For the owner the packet copies no tint or texture (only for remote
    players), so the copy shows in the script's default look (a white scarf for a
    green one) on the character but not in the inventory, until relog. Its ID is the
    real item's, which lies on the floor, and picking that up then fails on the
    client.

    So every tick a worn item that is not in the main inventory is a ghost. After
    GHOST_GRACE_MS, in case the item is still on its way: if an item with that ID is
    in the main inventory, it is worn instead; if no item with that ID is anywhere in
    the inventory, the ghost is taken off. Either way the client's setWornItem sends
    SyncClothing, and the server drops its own copy from it.
--]]

if not isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ClothingWearRework == true
end

-- ---------------------------------------------------------------------------
-- 2. Broken clothing
-- ---------------------------------------------------------------------------

-- Item IDs whose removeOnBroken flag this file cleared, so it knows which breaks
-- vanilla would have dropped and which flags to put back if the option goes off.
local suppressed = {}
local suppressedCount = 0

-- Item IDs already reported this session, so one break is only reported once.
local reported = {}

--- The holes on an item, as body part indices joined with commas.
local function encodeHoles(item)
    local visual = item:getVisual()
    if not visual then return "" end

    local holes = {}
    for i = 0, BloodBodyPartType.MAX:index() - 1 do
        if visual:getHole(BloodBodyPartType.FromIndex(i)) > 0 then
            table.insert(holes, tostring(i))
        end
    end
    return table.concat(holes, ",")
end

--- Returns true when the item broke and should be taken off and reported.
local function checkItem(item)
    local id = item:getID()

    if item:isRemoveOnBroken() then
        item:setRemoveOnBroken(false)
        if not suppressed[id] then
            suppressed[id] = true
            suppressedCount = suppressedCount + 1
        end
    end

    if not suppressed[id] or reported[id] or item:getCondition() > 0 then return false end

    reported[id] = true
    return true
end

--- Walk a local player's worn clothing. With restore set, put the flags back
-- instead.
local function checkPlayer(player, restore)
    local wornItems = player:getWornItems()
    if not wornItems then return end

    local broken = {}
    for i = 0, wornItems:size() - 1 do
        local item = wornItems:getItemByIndex(i)
        if item and instanceof(item, "Clothing") then
            if not restore then
                if checkItem(item) then
                    table.insert(broken, item)
                end
            elseif suppressed[item:getID()] then
                item:setRemoveOnBroken(true)
            end
        end
    end

    -- Taken off after the loop so the worn list is not changed while walking it.
    -- This only unwears: the item stays in the inventory until the server drops
    -- it, and the SyncClothing this sends no longer lists it (see the top of the
    -- file). Taken off before reporting, so that SyncClothing is already on its
    -- way when the server starts waiting for it.
    if #broken > 0 then
        for _, item in ipairs(broken) do
            player:removeWornItem(item, false)
        end
        for _, item in ipairs(broken) do
            sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_BROKEN_CLOTHING, {
                id = tostring(item:getID()),
                holes = encodeHoles(item),
            })
        end
        triggerEvent("OnClothingUpdated", player)
    end
end

-- ---------------------------------------------------------------------------
-- 3. Worn ghosts
-- ---------------------------------------------------------------------------

-- How long a worn item may be missing from the inventory before it counts as a
-- ghost (see the top of the file).
local GHOST_GRACE_MS = 2000

-- [player number] = { [item ID] = first time it was seen missing }
local ghostSince = {}

--- Take off, or swap for the real item, worn items that are not in the main
-- inventory (see the top of the file).
local function checkGhosts(player)
    local wornItems = player:getWornItems()
    if not wornItems then return end

    local num = player:getPlayerNum()
    local seen = ghostSince[num] or {}
    local missing = {}
    local now = getTimestampMs()
    local inventory = player:getInventory()

    local due = {}
    for i = 0, wornItems:size() - 1 do
        local worn = wornItems:get(i)
        local item = worn and worn:getItem()
        if item and item:getContainer() ~= inventory then
            local id = item:getID()
            missing[id] = seen[id] or now
            if now - missing[id] >= GHOST_GRACE_MS then
                table.insert(due, { item = item, location = worn:getLocation() })
            end
        end
    end
    ghostSince[num] = missing

    -- Changed after the loop so the worn list is not changed while walking it.
    local changed = false
    for _, ghost in ipairs(due) do
        local id = ghost.item:getID()
        local real = inventory:getItemWithID(id)
        local fixed = false
        if real then
            player:removeWornItem(ghost.item, false)
            player:setWornItem(ghost.location, real)
            print("[ZomboidFixesB42] worn " .. ghost.item:getFullType() .. " (" .. tostring(id)
                .. ") was a copy, now wearing the one in the inventory")
            fixed = true
        elseif not ZomboidFixesB42.findItemById(inventory, id) then
            player:removeWornItem(ghost.item, false)
            print("[ZomboidFixesB42] worn " .. ghost.item:getFullType() .. " (" .. tostring(id)
                .. ") is in no inventory, taken off")
            fixed = true
        end
        -- In a bag: a real item, worn from the wrong place. Left alone.
        if fixed then
            missing[id] = nil
            changed = true
        end
    end

    if changed then
        triggerEvent("OnClothingUpdated", player)
    end
end

-- ---------------------------------------------------------------------------
-- 1. Wear from zombie attacks
-- ---------------------------------------------------------------------------

-- Reach of AttackState.triggerPlayerReaction (1.0, crawlers 1.3), with a little slack.
local REACH = 1.05
local REACH_CRAWLER = 1.35
-- Squares around the player searched for attackers.
local SCAN_RADIUS = 2
-- A swing is sent at the latest this long after it was rolled, in case its end
-- was never seen.
local SWING_TIMEOUT_MS = 2000

local HAND_L = BodyPartType.ToIndex(BodyPartType.Hand_L)
local TORSO_LOWER = BodyPartType.ToIndex(BodyPartType.Torso_Lower)
local HEAD = BodyPartType.ToIndex(BodyPartType.Head)
local NECK = BodyPartType.ToIndex(BodyPartType.Neck)
local GROIN = BodyPartType.ToIndex(BodyPartType.Groin)
local UPPER_LEG_L = BodyPartType.ToIndex(BodyPartType.UpperLeg_L)
local MAX = BodyPartType.ToIndex(BodyPartType.MAX)

-- [player number] = { [zombie online ID] = attack outcome last seen }
local outcomes = {}

-- [player number] = { [zombie online ID] = { zombie, part, scratch, dirty, at } },
-- swings rolled and waiting for their end.
local swings = {}

local function trunc(x)
    if x >= 0 then return math.floor(x) end
    return math.ceil(x)
end

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

--- Vanilla's roll up to the outcome. Returns the body part index and the
-- `scratch` argument of addHoleFromZombieAttacks for a thump or a blocked attack,
-- nil for an attack that got through (or a crawler's skipped one).
local function roll(player, zombie, side)
    local behind = side == "BEHIND"
    local leftOrRight = side == "LEFT" or side == "RIGHT"
    local rear = SandboxVars.RearVulnerability or 3
    local attackers = math.max(1, player:getSurroundingAttackingZombies())

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
    if not zombie:isCrawling() then
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
    local bite = not zombie:cantBite() and ZombRand(100) > biteChance
    local defense = player:getBodyPartClothingDefense(part, bite, false)
    if ZombRand(100) < defense then
        return part, not bite
    end
    return nil
end

--- Send a swing whose end has come. A wound (no part) is only sent when vanilla's
-- local roll of an own zombie changed the clothing, to get the server's copy back.
local function sendSwing(player, id, swing)
    if not swing.part and not swing.dirty then return end
    sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_CLOTHING_WEAR, {
        zombie = id,
        part = swing.part,
        scratch = swing.scratch,
    })
end

local function scan(player)
    local num = player:getPlayerNum()
    local before = outcomes[num] or {}
    local now = {}
    outcomes[num] = now
    local pending = swings[num] or {}
    swings[num] = pending

    local square = player:getCurrentSquare()
    if square and not player:isDead() then
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
                                if lands then
                                    local old = pending[id]
                                    if old then sendSwing(player, id, old) end
                                    local part, scratch = roll(player, zombie, side)
                                    pending[id] = {
                                        zombie = zombie,
                                        part = part,
                                        scratch = scratch == true,
                                        at = getTimestampMs(),
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Swings that are over: the zombie left "success" (or is gone), finished the
    -- bite, or was never seen to end.
    local time = getTimestampMs()
    local done = {}
    for id, swing in pairs(pending) do
        local ended = now[id] ~= "success"
            or swing.zombie:getVariableString("ZombieBiteDone") == "true"
            or time - swing.at > SWING_TIMEOUT_MS
        if ended then table.insert(done, id) end
    end
    for _, id in ipairs(done) do
        sendSwing(player, id, pending[id])
        pending[id] = nil
    end
end

--- Vanilla's local roll of an own zombie's swing changed the clothing: the
-- server's copy has to come back even if this file rolled a wound.
local function markLocalRoll(player)
    local pending = swings[player:getPlayerNum()]
    if not pending then return end
    local attacker = player:getAttackedBy()
    if not attacker or not instanceof(attacker, "IsoZombie") or attacker:isRemoteZombie() then return end
    local swing = pending[attacker:getOnlineID()]
    if swing then swing.dirty = true end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function onPlayerUpdate(player)
    if not isEnabled() or not player:isLocalPlayer() then return end
    scan(player)
end

local function checkLocalPlayers(restore)
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and not player:isDead() then
            checkPlayer(player, restore)
            if not restore then
                checkGhosts(player)
            end
        end
    end
end

local function onTick()
    if isEnabled() then
        checkLocalPlayers(false)
    elseif suppressedCount > 0 then
        -- Switched off mid-game. Worn items get their flag back now; anything
        -- taken off meanwhile only matters once worn again, and gets it back on
        -- the next relog.
        checkLocalPlayers(true)
        suppressed = {}
        suppressedCount = 0
    end
end

-- Also on the clothing event, which fires the moment something is put on, so a
-- hit landing in the same frame still finds the flag cleared. It also fires from
-- inside vanilla's local roll of an own zombie's swing (addHole).
local function onClothingUpdated(character)
    if not isEnabled() then return end
    if not instanceof(character, "IsoPlayer") or not character:isLocalPlayer() then return end
    markLocalRoll(character)
    checkPlayer(character, false)
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)
Events.OnTick.Add(onTick)
Events.OnClothingUpdated.Add(onClothingUpdated)
