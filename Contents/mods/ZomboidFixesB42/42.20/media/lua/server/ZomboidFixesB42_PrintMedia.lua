--[[
    Zomboid Fixes B42.20 -- server, read brochures, fliers and maps show on the world map

    The world map's print media layer (ISWorldMap:renderPrintMedia) draws an icon for
    every media ID in character:getReadPrintMedia(), a set saved with the player.
    In multiplayer it is filled on one side only:

      * Brochures and fliers: ISReadABook:complete runs on the server and calls
        self.character:addReadPrintMedia(mediaID) there. Nothing sends the set to the
        owner (sendSyncPlayerFields 0x7 covers recipes, traits and read books), so
        the icons only appear after a relog, when the player is loaded from the
        server. The auto-reveal of the locations (getCore()
        :getOptionAutoRevealPrintMediaMapLocations()) is also asked of the server's
        Core, not the player's own option.
      * Paper maps: ISInventoryPaneContextMenu.onCheckMap calls
        playerObj:addReadMap(map) on the client only, so the server never saves it
        and a relog forgets the map was read.

    So the server tells the owner each media ID it adds
    (client/ZomboidFixesB42_PrintMedia.lua adds it and reveals the locations if the
    player's own option says so), and records a map the client says it read, after
    finding that map in the player's inventory.
--]]

if isClient() then return end

require "TimedActions/ISReadABook"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.PrintMediaSync == true
end

local vanillaComplete = ISReadABook.complete

function ISReadABook:complete(...)
    local item = self.item
    local mediaID = item and item:hasModData() and item:getModData().printMedia and item:getModData().printMedia.id
    local result = vanillaComplete(self, ...)
    if isServer() and isEnabled() and result ~= false and type(mediaID) == "string" and mediaID ~= ""
            and not self.forceStopped and self.character:isPrintMediaRead(mediaID) then
        sendServerCommand(self.character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_PRINT_MEDIA_READ, { id = mediaID, player = self.character:getOnlineID() })
    end
    return result
end

local function onMapRead(player, args)
    if not player or not isEnabled() then return end
    local id = tonumber(args.id)
    if not id then return end
    local map = ZomboidFixesB42.findItemById(player:getInventory(), id)
    if not map or not instanceof(map, "MapItem") then return end
    player:addReadMap(map)
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_MAP_READ then return end
    onMapRead(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
