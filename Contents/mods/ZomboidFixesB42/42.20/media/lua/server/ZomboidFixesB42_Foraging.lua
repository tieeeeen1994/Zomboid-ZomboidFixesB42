--[[
    Zomboid Fixes B42.20 -- server, foraging

    Registers the foraging debug tools' icons in the real, server-side forage pool,
    and performs the pickup that vanilla never gets round to calling.

    Icon creation is client-led on purpose. Icons handed down through
    sendForagePool are only queued into the client's iconStack, and the function
    that turns them into real ISForageIcons is reached from ISSearchManager:update()
    only when the player is in search mode -- so a server-issued debug icon would
    not show up at all. The client therefore creates and displays the icon exactly
    as vanilla always did, and sends its IDs here so the server can register icons
    to match. Once registered they are indistinguishable from ones the server
    generated itself, which is what makes them pickable.

    Everything else leans on forageServer's own state and validation rather than
    reimplementing it: records go into the same pools/byId tables that
    forageServer.generatePool fills, refreshing uses forageSystem.debugRefreshZone
    and forageServer.dropZonePool, and pickup goes through forageServer.onPickup,
    which already checks the icon was issued to this player and that they are close
    enough to it.
--]]

-- Not just "not a client": this depends on forageServer, which forageServer.lua
-- only defines when isServer() is true. In single player that global is nil.
if not isServer() then return end

require "Foraging/forageSystem"

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- The debug menu's largest option is x50; this only stops a tampered client from
-- registering an absurd number in one go.
local MAX_DEBUG_ICONS = 200

--- forageServer keys its tables by username. Mirrors its own local pname().
local function userOf(player)
    return player and (player:getUsername() or player:getDisplayName())
end

--- Mirrors forageServer's local rollCount(), so a debug icon yields the same
-- spread of items as a naturally generated one.
local function rollCount(itemDef)
    if not itemDef then return 1 end
    if itemDef.minCount == itemDef.maxCount then
        return itemDef.minCount or 1
    end
    return ZombRand(itemDef.minCount, itemDef.maxCount) + 1
end

--- Shared preamble for the debug tools: check the caller, then resolve the zone
-- they clicked in. Returns nil when anything is not right.
local function resolveDebugRequest(player, args, name)
    local role = player and player:getRole()
    if not role or not role:hasCapability(Capability.UseDebugContextMenu) then
        print("ZomboidFixesB42." .. name .. " The player's access level is not sufficient to perform this action")
        return nil
    end

    local user = userOf(player)
    if not user then return nil end

    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not x or not y or not z then return nil end

    local zoneData = forageSystem.getForageZoneAt(x, y)
    if not zoneData then
        print("ZomboidFixesB42." .. name .. " no forage zone at " .. x .. "," .. y)
        return nil
    end

    return user, zoneData, x, y, z
end

--- The player's pool for a zone, plus their icon index, creating both if needed.
local function poolFor(player, user, zoneData)
    local entry = forageServer.ensurePool(player, zoneData, forageServer.focus[user])
    if not entry then return nil end

    local byId = forageServer.byId[user]
    if not byId then
        byId = {}
        forageServer.byId[user] = byId
    end

    return entry, byId
end

--- Register icons the client has just created and is already displaying.
local function onCreateForageIcon(player, args)
    local user, zoneData, x, y, z = resolveDebugRequest(player, args, "createForageIcon")
    if not user then return end

    local itemType = args.itemType
    if type(itemType) ~= "string" or type(args.ids) ~= "string" then return end

    local itemDef = forageSystem.itemDefs[itemType]
    if not itemDef or not itemDef.categories or not itemDef.categories[1] then return end

    local entry, byId = poolFor(player, user, zoneData)
    if not entry then return end

    local added = 0
    for iconID in string.gmatch(args.ids, "([^,]+)") do
        if added >= MAX_DEBUG_ICONS then break end

        -- Skipping IDs already known keeps a resent command from duplicating one.
        if not byId[iconID] then
            local rec = {
                iconID = iconID, zoneId = zoneData.id,
                x = x, y = y, z = z,
                itemType = itemType, catName = itemDef.categories[1],
                count = rollCount(itemDef),
            }
            entry.icons[iconID] = rec
            byId[iconID] = rec
            added = added + 1
        end
    end
end

--- "Clear And Refresh All Icons In This Zone".
-- Refreshes the authoritative zone (which refills it and stores it back through
-- forageClient.updateZone -- on the server that alias is forageServer), then drops
-- this player's pool so their next request regenerates it from scratch.
--
-- Only the requesting player's pool is dropped. The zone data is shared, but the
-- pools are per player, and yanking forage out from under everyone else is not
-- what this debug option is for.
local function onRefreshForageZone(player, args)
    local user, zoneData = resolveDebugRequest(player, args, "refreshForageZone")
    if not user then return end

    forageSystem.debugRefreshZone(zoneData)
    forageServer.dropZonePool(user, zoneData.id)
    forageServer.syncForageData()

    -- Clearing lastReqMs first stops forageServer.onRequestZone's 250ms rate limit
    -- from swallowing the re-request the client makes on receiving this.
    forageServer.lastReqMs[user] = nil
    sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FORAGE_ZONE_RESET, {
        zone = zoneData.id,
    })
end

--- "Move All Forage Icons In Zone To This Square".
-- The client has already moved its own icons; this moves the records so they stay
-- pickable at the new spot. Records are edited in place rather than regenerated so
-- the icons keep their identities.
local function onMoveForageIcons(player, args)
    local user, zoneData, x, y, z = resolveDebugRequest(player, args, "moveForageIcons")
    if not user then return end

    local pools = forageServer.pools[user]
    local entry = pools and pools[zoneData.id]
    if not entry then return end

    local square = getCell():getGridSquare(x, y, z)
    if not square then return end

    for _, rec in pairs(entry.icons) do
        local itemDef = forageSystem.itemDefs[rec.itemType]
        local catDef = forageSystem.catDefs[rec.catName]
        if itemDef and catDef and forageSystem.isValidSquare(square, itemDef, catDef) then
            rec.x, rec.y, rec.z = x, y, z
        end
    end
end

local function onForagePickup(player, args)
    if not player then return end

    local iconID = args.icon
    if type(iconID) ~= "string" or iconID == "" then return end

    -- An unresolvable container is not a failure: onPickup falls back to the
    -- player's own inventory, which is what vanilla would have used.
    local container
    if type(args.container) == "string" and args.container ~= "" then
        container = ZomboidFixesB42.decodeContainer(args.container, player)
    end

    -- onPickup checks the icon was issued to this player and that they are within
    -- forageServer.maxPickupDistance, then grants the items, applies the fatigue
    -- and endurance penalties and decrements the zone.
    forageServer.onPickup(player, iconID, container)
end

local handlers = {
    [ZomboidFixesB42.CMD_FORAGE_DEBUG_ICON] = onCreateForageIcon,
    [ZomboidFixesB42.CMD_FORAGE_REFRESH_ZONE] = onRefreshForageZone,
    [ZomboidFixesB42.CMD_FORAGE_MOVE_ICONS] = onMoveForageIcons,
    [ZomboidFixesB42.CMD_FORAGE_PICKUP] = onForagePickup,
}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ForagingDebugFixes == true
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or not isEnabled() then return end

    local handler = handlers[command]
    if handler then
        handler(player, args or {})
    end
end

Events.OnClientCommand.Add(onClientCommand)
