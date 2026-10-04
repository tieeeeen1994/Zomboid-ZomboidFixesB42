--[[
    Zomboid Fixes B42.20 -- client, broken clothing

    Worn clothing that reaches condition 0 is taken off and dropped, by
    Clothing.setCondition() -> Unwear(true):

        c.removeWornItem(this)
        triggerEvent("OnClothingUpdated", c)
        if drop and not in a vehicle:
            if GameServer.server: sendRemoveItemFromContainer(...)
            c.getInventory().Remove(this)
            square.AddWorldInventoryItem(this, ...)    -- only transmits on the server

    Every step of that is replicated only when it runs on the server. But holes, and
    the condition loss that comes with them, are mostly rolled on the client: a
    zombie scratch (BodyDamage.AddRandomDamageFromZombie) adds the hole locally and
    only then sends ZombieHitPlayerPacket, and the server rolls the attack again
    with its own random numbers, which rarely breaks the same item. So the client
    ends up with a broken item on the floor that exists nowhere else, while the
    server still has it worn and intact -- which is what comes back on relog. The
    SyncVisuals packet that would carry the condition does not help either: it is
    rejected once the client has one worn item fewer than the server.

    Lua cannot step into the middle of setCondition, but the drop only happens when
    the item's removeOnBroken flag is set, and nothing else reads that flag. It
    comes from the item script when the item is created and is neither saved nor
    networked, so clearing it on the client's copy of worn clothing changes nothing
    for the server or anyone else. The client then keeps the broken item instead of
    dropping it, takes it off without dropping it, and reports the break. The server
    drops its own copy and replicates that to everyone, including this client.

    Taking it off locally straight away matters. Every hit, and a few other things,
    call IsoPlayer.syncVisuals, which sends SyncClothing with the client's worn
    list. When the server gets a worn item it does not have in the inventory, it
    creates a new one with that ID and puts it on. So if the client still listed the
    broken item as worn after the server had dropped it, the server would make a
    fresh, undamaged copy while the broken one lay on the floor.

    That still happens when the server breaks the item itself (a hit that got
    through, rolled again on the server): vanilla's server-side Unwear sends
    SyncClothing without it (setWornItem sends one to everyone), but a SyncClothing
    this client sent a moment earlier, still listing it, can cross it. The server
    then creates the copy (SyncClothingPacket.process: CreateItem + setID, worn but in
    no inventory) and echoes its list back, and this client does the same: the item
    is no longer in its inventory, so it creates one too. For the owner the packet
    copies no tint or texture (only for remote players), so the copy shows in the
    script's default look -- a white scarf for a green one -- on the character but
    not in the inventory, until relog (it is never saved). Its ID is the real item's,
    which now lies on the floor, and picking that up then fails on the client.

    So every tick a worn item that is not in the main inventory is a ghost. Vanilla
    keeps every worn item there; ItemContainer.Remove on a client takes an item out
    without unwearing it. After GHOST_GRACE_MS, in case the item is still on its way:
    if an item with that ID is in the main inventory, it is worn instead (the copy
    came from a SyncClothing that overtook the item, which travels on another
    ordering channel); if no item with that ID is anywhere in the inventory, the
    ghost is taken off. Either way the client's setWornItem sends SyncClothing, and
    the server drops its own copy from it. Nothing is deleted on either side: a
    ghost belongs to no container, and the server's SyncClothing only unwears.
--]]

if not isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.SyncBrokenClothing == true
end

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
-- hit landing in the same frame still finds the flag cleared.
local function onClothingUpdated(character)
    if not isEnabled() then return end
    if not instanceof(character, "IsoPlayer") or not character:isLocalPlayer() then return end
    checkPlayer(character, false)
end

Events.OnTick.Add(onTick)
Events.OnClothingUpdated.Add(onClothingUpdated)
