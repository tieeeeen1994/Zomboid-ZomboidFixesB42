--[[
    Zomboid Fixes B42.20 -- client, foraging

    In multiplayer the server owns the forage pool: it generates icons in
    forageServer.pools[user][zoneId], indexes them in forageServer.byId[user], and
    pushes them down with sendForagePool. An icon the server never issued is absent
    from that index, so it can never be picked up -- and applyServerPool only ever
    adds, never removes, which is why stale client-side icons sit there looking real.

    1. Creating icons. Every "Add Forage Icon Here" and "Create Bulk Icons" option
       funnels into ISSearchManager:createSpecificIcon, which builds the icon with a
       client-side UUID straight into the client's own manager.

       The fix is NOT to move that creation to the server. Icons that arrive through
       sendForagePool are only queued into iconStack, and the one thing that turns
       them into real ISForageIcons -- loadIcons() -- is reached from
       ISSearchManager:update() only after

           if (not self.isSearchMode) then ... return; end

       so a debug icon issued by the server does not appear at all unless the admin
       happens to be in search mode and within activeIconRadius. Vanilla's local
       creation has neither condition.

       So let vanilla create and show the icon exactly as it always did, then tell
       the server to register icons with those same IDs. The visuals stay immediate
       and the IDs match what the server has, so pickup works.

    2. "Move All Forage Icons In Zone To This Square". ISSearchManager:doMoveIcon
       opens with "if isClient() then return end", so this option is a complete
       no-op in multiplayer. Moved here locally -- which keeps working outside search
       mode, as vanilla does -- with the server moving its own records to match.

    3. "Clear And Refresh All Icons In This Zone". This calls
       forageSystem.debugRefreshZone on the client's own copy of the zone, then
       createIconsForZone -- which in multiplayer just re-requests the zone, and the
       server answers with the pool it already had. So nothing is cleared and nothing
       is refreshed. Here the server refreshes and drops its pool, then tells us to
       drop ours and ask again. Fresh icons still need search mode to appear, but
       that is true of the single player path too.

    4. Nothing ever asks the server to hand over the items. forageServer.onPickup
       exists and is correct but has no caller: there is no pickup packet among the
       four forage packet types, ForageSpotPacket only triggers the XP event, and the
       isServer() branch of ISForageAction:complete() cannot run on a dedicated
       server because timed action queues are client-side. On a multiplayer client
       complete() simply returns true and adds nothing -- the itemDataList the icon
       assembles and passes in is never read again.
--]]

require "Foraging/ISSearchManager"
require "Foraging/ISForageAction"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local vanillaCreateSpecificIcon = ISSearchManager.createSpecificIcon
local vanillaRefreshZoneIcons = ISSearchManager.refreshZoneIcons
local vanillaMoveAllZoneIconsToSquare = ISSearchManager.moveAllZoneIconsToSquare
local vanillaComplete = ISForageAction.complete

local function characterOf(manager)
    return manager.character or getPlayer()
end

-- 1. CREATING ICONS ---------------------------------------------------------

function ISSearchManager:createSpecificIcon(_square, _itemType, _zoneData, _isBonus, _isFocus, _count)
    if not isClient() then
        return vanillaCreateSpecificIcon(self, _square, _itemType, _zoneData, _isBonus, _isFocus, _count)
    end

    local character = characterOf(self)
    if not character or not _square or not _zoneData then
        return vanillaCreateSpecificIcon(self, _square, _itemType, _zoneData, _isBonus, _isFocus, _count)
    end

    -- Which icons existed before, so the new ones can be picked out afterwards.
    -- Cheaper and far less brittle than reimplementing vanilla's creation loop
    -- just to learn the IDs it generated.
    local before = {}
    for iconID in pairs(self.forageIcons) do
        before[iconID] = true
    end

    vanillaCreateSpecificIcon(self, _square, _itemType, _zoneData, _isBonus, _isFocus, _count)

    local newIds = {}
    for iconID in pairs(self.forageIcons) do
        if not before[iconID] then
            table.insert(newIds, iconID)
        end
    end
    if #newIds == 0 then return end

    -- The IDs are UUIDs, so a comma-joined list needs no escaping.
    sendClientCommand(character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FORAGE_DEBUG_ICON, {
        ids = table.concat(newIds, ","),
        x = tostring(_square:getX()),
        y = tostring(_square:getY()),
        z = tostring(_square:getZ()),
        itemType = _itemType,
    })
end

-- 2. MOVING ICONS ----------------------------------------------------------

--- The body of ISSearchManager:doMoveIcon, which refuses to run on a client.
local function moveIconLocally(icon, x, y, z)
    icon:removeIsoMarker()
    icon:removeWorldMarker()
    icon.xCoord, icon.yCoord, icon.zCoord = x, y, z
    icon.icon.x, icon.icon.y, icon.icon.z = x, y, z
    icon:getGridSquare()
    triggerEvent("onUpdateIcon", icon.zoneData, icon.iconID, icon)
end

function ISSearchManager:moveAllZoneIconsToSquare(_square)
    if not isClient() then
        return vanillaMoveAllZoneIconsToSquare(self, _square)
    end

    local character = characterOf(self)
    if not _square or not character then return end

    local zoneData = self:getAndActivateZoneAtXY(_square:getX(), _square:getY())
    if not zoneData then return end

    local x, y, z = _square:getX(), _square:getY(), _square:getZ()

    -- Same loop and validity test as the vanilla function, with the move done
    -- here rather than in the client-blocked doMoveIcon.
    for iconID, icon in pairs(self.forageIcons) do
        if zoneData.forageIcons[iconID] and forageSystem.isValidSquare(_square, icon.itemDef, icon.catDef) then
            moveIconLocally(icon, x, y, z)
        end
    end

    sendClientCommand(character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FORAGE_MOVE_ICONS, {
        x = tostring(x),
        y = tostring(y),
        z = tostring(z),
    })
end

-- 3. REFRESHING A ZONE -----------------------------------------------------

function ISSearchManager:refreshZoneIcons(_square)
    if not isClient() then
        return vanillaRefreshZoneIcons(self, _square)
    end

    local character = characterOf(self)
    if not _square or not character then return end

    sendClientCommand(character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FORAGE_REFRESH_ZONE, {
        x = tostring(_square:getX()),
        y = tostring(_square:getY()),
        z = tostring(_square:getZ()),
    })
end

--- Drop every locally materialised icon belonging to a zone.
-- Goes through the onUpdateIcon event rather than removeIcon directly, because
-- that is the path vanilla uses: it resets the icon, clears its markers, removes
-- it from all of the manager's category tables and clears it out of the zone data,
-- for every manager (so split screen is handled too).
local function clearLocalZoneIcons(zoneId)
    for _, manager in pairs(ISSearchManager.players) do
        local stale = {}
        for iconID, icon in pairs(manager.forageIcons) do
            local zoneData = icon.zoneData
            if zoneData and zoneData.id == zoneId then
                stale[iconID] = zoneData
            end
        end

        for iconID, zoneData in pairs(stale) do
            triggerEvent("onUpdateIcon", zoneData, iconID, nil)
            -- removeIcon only walks iconCategories, which does not include these.
            -- Left behind they would stop the replacement icon being spotted again.
            manager.seenIcons[iconID] = nil
            manager.xpIcons[iconID] = nil
            manager.movedIcons[iconID] = nil
        end
    end
end

--- The server has refreshed a zone and wants us to start over.
local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_FORAGE_ZONE_RESET then return end
    if type(args) ~= "table" or type(args.zone) ~= "string" then return end

    clearLocalZoneIcons(args.zone)

    -- Ask for the pool the ordinary way, so it arrives after the clear rather
    -- than racing it.
    local player = getPlayer()
    if player and forageClient then
        forageClient.requestZone(player)
    end
end

Events.OnServerCommand.Add(onServerCommand)

-- 4. PICKING UP ------------------------------------------------------------

function ISForageAction:complete()
    if not isClient() then
        return vanillaComplete(self)
    end

    -- Only the server can grant the items, and only it knows whether this icon is
    -- real. Reporting success either way matches what vanilla does here.
    sendClientCommand(self.character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FORAGE_PICKUP, {
        icon = tostring(self.iconID),
        container = ZomboidFixesB42.encodeContainer(self.targetContainer, self.character) or "",
    })

    return true
end
