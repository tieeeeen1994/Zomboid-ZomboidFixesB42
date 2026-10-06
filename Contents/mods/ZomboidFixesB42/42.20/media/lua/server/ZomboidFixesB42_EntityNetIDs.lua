--[[
    Zomboid Fixes B42.20 -- server, crafting stations the server cannot find

    Crafting at a station (forge, kiln, furnace, workbench) sends the station's
    CraftBench component with the action as its entity net ID
    (PZNetKahluaTableImpl.saveComponent: component:getGameEntity():getEntityNetID()).
    An IsoObject's net ID is x + y<<16 + z<<32 + objectIndex<<40, worked out from its
    current index in the square's object list (IsoObject.getEntityNetID ~5701). The
    server finds the station again with GameEntityManager.GetEntity(id), a map filled
    when the entity is registered.

    That map is only corrected lazily: getEntityNetID notices that the object's index
    changed and moves its map entry (GameEntityManager.checkEntityIDChange), but only
    when something calls it on the server. When an object below the station on its
    square is removed (furniture picked up, a wall item taken down) the station's
    index drops by one; the client works the new ID out at once, while the server's
    map keeps the old one until the next sendSyncEntity or a reload. Every craft
    there then fails in loadComponent with a NullPointerException ("gameEntity" is
    null) while the server reads the request, and the server never answers, so the
    action sits at 100% (see client/ZomboidFixesB42_StuckActions.lua): 12 attempts
    out of 12 at the same kiln in forum topic 100905.

    So once a second, the server calls getEntityNetID on every registered entity
    within two tiles of each online player, on their floor, which moves any stale
    entry before the player can craft there. An unchanged index costs one indexOf.
    A station whose object lists differ between client and server (a desync, not a
    stale entry) is still out of reach.
--]]

if isClient() then return end

local RADIUS = 2
local PERIOD_MS = 1000

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.EntityNetIDRefresh == true
end

local lastMs = 0

local function refreshAround(cell, player)
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for dx = -RADIUS, RADIUS do
        for dy = -RADIUS, RADIUS do
            local square = cell:getGridSquare(px + dx, py + dy, pz)
            if square then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    -- Only entities in the engine have a map entry to move; calling it
                    -- on anything else would give that object an ID with no entry.
                    if object and object:hasComponents() and object:isAddedToEngine() then
                        object:getEntityNetID()
                    end
                end
            end
        end
    end
end

local function onTick()
    if not isServer() or not isEnabled() then return end
    local now = getTimestampMs()
    if now - lastMs < PERIOD_MS then return end
    lastMs = now

    local players = getOnlinePlayers()
    local cell = getCell()
    if not players or not cell then return end
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player and not player:isDead() then
            refreshAround(cell, player)
        end
    end
end

Events.OnTick.Add(onTick)
