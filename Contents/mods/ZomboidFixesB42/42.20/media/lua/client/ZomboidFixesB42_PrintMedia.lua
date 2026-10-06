--[[
    Zomboid Fixes B42.20 -- client, read brochures, fliers and maps show on the world map

    The client half of server/ZomboidFixesB42_PrintMedia.lua: adds the media IDs the
    server reports to this player's read print media (the world map's print media
    icons), reveals their locations on the world map when this player's own "auto
    reveal print media map locations" option is on (as ISReadABook
    :revealPrintMediaLocationsOnMap does in single player, and sending the same
    map.setKnownInSquares the map window sends), and tells the server about each
    paper map read.
--]]

if not isClient() then return end

require "ISUI/ISInventoryPaneContextMenu"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.PrintMediaSync == true
end

local function reveal(player, mediaID)
    local details = PrintMediaDefinitions and PrintMediaDefinitions.MiscDetails[mediaID]
    if not details then return end
    for i = 1, 5 do
        local locations = details["location" .. i]
        if locations == nil then break end
        for _, sq in ipairs(locations) do
            WorldMapVisited.getInstance():setKnownInSquares(sq.x1, sq.y1, sq.x2, sq.y2)
            sendClientCommand(player, "map", "setKnownInSquares", { x1 = sq.x1, y1 = sq.y1, x2 = sq.x2, y2 = sq.y2 })
        end
    end
end

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_PRINT_MEDIA_READ then return end
    if not isEnabled() or type(args) ~= "table" or type(args.id) ~= "string" then return end
    local player = (args.player and getPlayerByOnlineID(args.player)) or getPlayer()
    if not player then return end
    player:addReadPrintMedia(args.id)
    if getCore():getOptionAutoRevealPrintMediaMapLocations() then
        reveal(player, args.id)
    end
end

Events.OnServerCommand.Add(onServerCommand)

local vanillaOnCheckMap = ISInventoryPaneContextMenu.onCheckMap

ISInventoryPaneContextMenu.onCheckMap = function(map, player, ...)
    local result = vanillaOnCheckMap(map, player, ...)
    local playerObj = getSpecificPlayer(player)
    -- Only once the map was really opened (vanilla first queues a transfer when the
    -- map is not in the inventory, and calls this again when it arrives).
    if isEnabled() and playerObj and map and playerObj:hasReadMap(map)
            and playerObj:getInventory():containsRecursive(map) then
        sendClientCommand(playerObj, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_MAP_READ, { id = map:getID() })
    end
    return result
end
