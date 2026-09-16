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
    for the server or anyone else. The client then keeps a broken item on instead
    of dropping it, and reports the break. The server's copy still has the flag, so
    its own Unwear takes the item off, drops it and replicates both to everyone,
    including this client.
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

-- Item IDs already reported this session. A broken item stays worn until the
-- server's reply arrives, and one report is enough.
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

local function checkItem(player, item)
    local id = item:getID()

    if item:isRemoveOnBroken() then
        item:setRemoveOnBroken(false)
        if not suppressed[id] then
            suppressed[id] = true
            suppressedCount = suppressedCount + 1
        end
    end

    if not suppressed[id] or reported[id] or item:getCondition() > 0 then return end

    reported[id] = true
    sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_BROKEN_CLOTHING, {
        id = tostring(id),
        holes = encodeHoles(item),
    })
end

--- Walk a local player's worn clothing. With restore set, put the flags back
-- instead.
local function checkPlayer(player, restore)
    local wornItems = player:getWornItems()
    if not wornItems then return end

    for i = 0, wornItems:size() - 1 do
        local item = wornItems:getItemByIndex(i)
        if item and instanceof(item, "Clothing") then
            if not restore then
                checkItem(player, item)
            elseif suppressed[item:getID()] then
                item:setRemoveOnBroken(true)
            end
        end
    end
end

local function checkLocalPlayers(restore)
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and not player:isDead() then
            checkPlayer(player, restore)
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
