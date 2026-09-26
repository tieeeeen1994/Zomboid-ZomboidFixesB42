--[[
    Zomboid Fixes B42.20 -- shared

    Written against Build 42.20.4 (revision b0bbce05d5). Java names in the comments
    come from a Vineflower decompile of projectzomboid.jar; line numbers, where
    given, shift between builds.

    How the mod is laid out:

      - One feature is client/ZomboidFixesB42_<Feature>.lua and
        server/ZomboidFixesB42_<Feature>.lua, plus shared/ when both sides need it.
        Each file opens with a comment on the vanilla bug and the Java behind it.
        Server files start with `if isClient() then return end` (or `if not
        isServer()` when single player has nothing to do), and client files that
        only matter on a server with `if not isClient() then return end`.
      - Every new fix gets a sandbox option on the ZomboidFixesB42 page, off by
        default, read as SandboxVars.ZomboidFixesB42.<Option>, with its name and
        a long tooltip in Translate/EN/Sandbox.json ("[BETA] ..." for beta ones).
        UI text goes in Translate/EN/IG_UI.json as IGUI_ZomboidFixesB42_*.
      - Every feature has a line in README.md, workshop.txt and mod.info, and the
        three are kept in step.
      - Server handlers check the sender's capability
        (player:getRole():hasCapability(Capability.X)), check and clamp every
        argument, and log what admins do.

    Roles: zombie/characters/Capability.java lists every capability. By default
    (Roles.java) admin has all of them, and moderator all but UseMovablesCheat,
    SaveWorld, QuitWorld, ChangeAndReloadServerOptions, ReloadLuaFiles,
    BypassLuaChecksum, RolesWrite and ConnectWithDebug. gm and observer have short
    hand-picked lists; observer's includes god mode, invisibility and noclip for
    themselves, CanSeePlayersStats and UseDebugContextMenu.

    Item transfers --------------------------------------------------------------

    In single player the "Fast Timed Actions" cheat makes item transfers instant,
    because ISInventoryTransferAction sets maxTime = 1 and the client moves the
    item itself.

    In multiplayer none of that applies. ISInventoryTransferAction:new() overwrites
    maxTime with -1 for clients, the real duration is computed server side by the
    private Java method zombie.core.Transaction.getDuration() -- which has no cheat
    check in it at all -- and the server holds the item until that timer elapses.
    The client never calls transferItem() itself, so nothing it does locally can
    speed the transfer up.

    So the only way to mirror the single player behaviour is to skip the transaction
    system entirely for a cheating admin: the client asks the server to do the move,
    and the server does it immediately and replicates the result.

    This file holds the part both sides need -- addressing a container over the wire.
    Containers are not serialisable, so each one is encoded as a short string that
    the server can resolve back to a real container.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

--[[ Commands and packets --------------------------------------------------------

    Client and server talk through sendClientCommand and sendServerCommand with the
    command names below. Each server file adds its own OnClientCommand handler and
    ignores the other commands.

    sendClientCommand travels in the ClientCommand packet: priority 1, RakNet
    RELIABLE, which is not ordered, so two commands can arrive the other way round.
    A client silently drops packets of one type beyond the server's
    MaxPacketsPerSecond (300 by default) a second (PacketsCache.isLimitExceeded).
    Arguments are serialised by TableNetworkUtils: strings, numbers, booleans and
    nested tables, plus items, directions and dead bodies. Anything else is left out.

    In single player sendClientCommand goes to SinglePlayerClient and fires
    OnClientCommand locally, so a server file guarded by `if isClient() then return
    end` handles it there too. sendServerCommand does nothing outside a server, so a
    feature that asks and waits for an answer needs its own single player path.

    Server-side Lua has no getPlayerFromUsername (it is client only, it reads
    GameClient.instance), so walk getOnlinePlayers(). getPlayerByOnlineID works on
    both sides. writeLog(logger, text) writes the server's <date>_<logger>.txt; the
    "admin" logger is the one /addxp and the other admin commands use.

    The game's own packets are INetworkPacket classes annotated @PacketSetting.
    handlingType bits: 1 the server handles it, 2 the client does, 4 the client
    does while loading. PacketTypes.PacketType.onServerPacket drops a packet unless
    the sender's role holds its requiredCapability
    (PacketAuthorization.isAuthorized), then runs parseServer, isConsistent, the
    anticheats and processServer. On the server INetworkPacket.send(IsoPlayer, type,
    ...) goes to that player's connection only; on a client INetworkPacket.send(type,
    ...) goes to the server.
--]]

ZomboidFixesB42.MODULE = "ZomboidFixesB42"

-- client -> server
ZomboidFixesB42.CMD_TRANSFER = "instantTransfer"
ZomboidFixesB42.CMD_ANIMAL_GENDER = "setAnimalGender"
ZomboidFixesB42.CMD_FORAGE_DEBUG_ICON = "createForageIcon"
ZomboidFixesB42.CMD_FORAGE_PICKUP = "foragePickup"
ZomboidFixesB42.CMD_FORAGE_REFRESH_ZONE = "refreshForageZone"
ZomboidFixesB42.CMD_FORAGE_MOVE_ICONS = "moveForageIcons"
ZomboidFixesB42.CMD_ITEM_EDIT = "applyItemEdit"
ZomboidFixesB42.CMD_BROKEN_CLOTHING = "brokenClothing"
ZomboidFixesB42.CMD_FLUID_DEBUG = "addFluidDebug"
ZomboidFixesB42.CMD_FAST_FORWARD_VOTE = "fastForwardVote"
ZomboidFixesB42.CMD_FAST_FORWARD_HELLO = "fastForwardHello"
ZomboidFixesB42.CMD_TURBO_INSERT = "turboInsertCartridge"
ZomboidFixesB42.CMD_TURBO_EJECT = "turboEjectCartridge"
ZomboidFixesB42.CMD_TURBO_BATTERY = "turboInsertBattery"
ZomboidFixesB42.CMD_TURBO_REPORT = "turboReport"
ZomboidFixesB42.CMD_TURBO_DATA = "turboSaveData"
ZomboidFixesB42.CMD_BODY_STATS_REQUEST = "bodyStatsRequest"
ZomboidFixesB42.CMD_BODY_STATS_SET = "bodyStatsSet"
ZomboidFixesB42.CMD_CHOPPER = "chopper"
ZomboidFixesB42.CMD_TRANSFER_TIMED = "timedTransfer"
ZomboidFixesB42.CMD_TRANSFER_TIMED_CANCEL = "timedTransferCancel"

-- server -> clients
ZomboidFixesB42.CMD_ANIMAL_GENDER_SYNC = "animalGenderSync"
ZomboidFixesB42.CMD_FORAGE_ZONE_RESET = "forageZoneReset"
ZomboidFixesB42.CMD_TRANSFER_DECLINED = "transferDeclined"
ZomboidFixesB42.CMD_FAST_FORWARD_STATE = "fastForwardState"
ZomboidFixesB42.CMD_BODY_STATS_STATE = "bodyStatsState"
ZomboidFixesB42.CMD_CHOPPER_RESULT = "chopperResult"

-- The single player speed buttons, as zombie.ui.SpeedControls sets them: play,
-- fast forward, faster forward and wait. Multiplayer fast forward offers exactly
-- these, so a vote can only ever be one of them.
ZomboidFixesB42.FAST_FORWARD_SPEEDS = { 1, 5, 20, 40 }

function ZomboidFixesB42.isFastForwardSpeed(speed)
    for _, allowed in ipairs(ZomboidFixesB42.FAST_FORWARD_SPEEDS) do
        if speed == allowed then return true end
    end
    return false
end

-- Where a Turbo Game console keeps what its games save, in the item's mod data.
ZomboidFixesB42.TURBO_DATA_KEY = "zomboidFixesTurboGame"

-- Every key the games save in Turbo Game's global mod data table, and the cartridge
-- whose game saves it. Each game has keys of its own; Flappy Bird's is the only one
-- not named after its game.
local TURBO = "TurboGame."
ZomboidFixesB42.TURBO_GAME_KEYS = {
    arkanoidBest = TURBO .. "ArkanoidCartridge",
    asteroidsBest = TURBO .. "AsteroidsCartridge",
    candyBest = TURBO .. "CandyCartridge",
    dinoBest = TURBO .. "DinoCartridge",
    bestScore = TURBO .. "FlappyBirdCartridge",
    froggerBest = TURBO .. "FroggerCartridge",
    minesweeperBest = TURBO .. "MinesweeperCartridge",
    pacmanBest = TURBO .. "PacManCartridge",
    pongBest = TURBO .. "PongCartridge",
    roadFighterBest = TURBO .. "RoadFighterCartridge",
    snakeBest = TURBO .. "SnakeCartridge",
    spaceInvadersBest = TURBO .. "SpaceInvadersCartridge",
    tetrisBest = TURBO .. "TetrisCartridge",
    sudokuWinsEasy = TURBO .. "SudokuCartridge",
    sudokuWinsMedium = TURBO .. "SudokuCartridge",
    sudokuWinsHard = TURBO .. "SudokuCartridge",
    sudokuDifficulty = TURBO .. "SudokuCartridge",
    sudokuPuzzle = TURBO .. "SudokuCartridge",
    sudokuSolution = TURBO .. "SudokuCartridge",
    sudokuUserGrid = TURBO .. "SudokuCartridge",
    sudokuNotes = TURBO .. "SudokuCartridge",
    sudokuElapsed = TURBO .. "SudokuCartridge",
    sudokuGameState = TURBO .. "SudokuCartridge",
}

-- A zombie this close to a player, on the same floor, counts as near them.
local NEAR_ZOMBIE = 4
-- A zombie this close that is already coming for the player counts too.
local HUNTING_ZOMBIE = 7

--- Whether a living zombie is close to a player, or closing in on them. Never true
-- in ghost mode, where zombies ignore the player.
function ZomboidFixesB42.isZombieNear(player)
    if player:isGhostMode() then return false end
    local cell = getCell()
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for x = px - HUNTING_ZOMBIE, px + HUNTING_ZOMBIE do
        for y = py - HUNTING_ZOMBIE, py + HUNTING_ZOMBIE do
            local square = cell:getGridSquare(x, y, pz)
            if square then
                local movers = square:getMovingObjects()
                for i = 0, movers:size() - 1 do
                    local zombie = movers:get(i)
                    if instanceof(zombie, "IsoZombie") and not zombie:isDead() then
                        local distance = player:DistTo(zombie)
                        if distance <= NEAR_ZOMBIE or zombie:getTarget() == player then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- How long a cheated item transfer takes, in the same units as the vanilla
-- ISInventoryTransferAction maxTime. 1 is what ISInventoryTransferAction:new gives
-- single player under the cheat (isTimedActionInstant), so the transfer is over in
-- a tick and shows no progress bar. In multiplayer it still lasts until the
-- server's move has arrived; see the client file.
ZomboidFixesB42.TRANSFER_MAX_TIME = 1

--- How long moving one item takes at normal speed, in timed action units (20 ms of
-- real time on a server). The server's own length, zombie.core.Transaction.getDuration
-- (Java, not reachable from Lua), per item; a batch takes as long as its slowest
-- item. It is the same formula as ISInventoryTransferAction:new. Left out: vanilla's
-- streak of instant moves for world items weighing 0.1 or less.
function ZomboidFixesB42.transferUnits(player, item, src, dst)
    if not src or not dst or dst:getType() == "TradeUI" or src:getType() == "TradeUI" then return 0 end
    local units = 120
    local capacityDelta = 1
    local inventory = player:getInventory()
    if src == inventory then
        if dst:isInCharacterInventory(player) then
            local max = dst:getMaxWeight()
            if max > 0 then capacityDelta = dst:getCapacityWeight() / max end
        else
            units = 50
        end
    elseif not src:isInCharacterInventory(player) and dst:isInCharacterInventory(player) then
        units = 50
    end
    if capacityDelta < 0.4 then capacityDelta = 0.4 end
    if item then
        units = units * math.min(item:getActualWeight(), 3) * capacityDelta
    end
    if getCore():getGameMode() == "LastStand" then units = units * 0.3 end
    if dst:getType() == "floor" then
        if src == inventory then
            units = units * 0.1
        elseif not src:isInCharacterInventory(player) then
            units = units * 0.2
        end
    end
    if player:hasTrait(CharacterTrait.DEXTROUS) then units = units * 0.5 end
    if player:hasTrait(CharacterTrait.ALL_THUMBS) or player:isWearingAwkwardGloves() then units = units * 2 end
    return units
end

-- How far a player may be from a container and still transfer into or out of it.
-- This is defence in depth rather than game balance: the command is already gated
-- on access level and on the cheat flag, and this only stops a tampered client
-- from reaching containers across the map. Deliberately generous.
ZomboidFixesB42.MAX_REACH = 8

local SEP = "|"

-- Stands in for "the ground" wherever a container is encoded. See the floor note
-- in encodeContainer for why it carries no coordinates.
ZomboidFixesB42.FLOOR = "f"

--[[ Encoding ----------------------------------------------------------------

    p                                 the player's own main inventory
    i|<itemID>                        a bag the player is carrying, at any depth
    g|<itemID>                        a bag lying on the ground next to the player
    n|<itemID>|<encoded container>    a bag inside another container: a crate, a
                                      car trunk, or a bag in either
    v|<vehicleID>|<partID>            a vehicle part container
    w|<x>|<y>|<z>|<obj>|<con>|<type>  a container on a world object, by the
                                      object's index on the square, the
                                      container's index on the object and the
                                      container's type

    Anything else returns nil, and the caller falls back to vanilla behaviour.
    Floor containers and corpses are deliberately not encoded -- see the comment
    on ZomboidFixesB42.encodeContainer.

    A bag used to be sent as i| wherever it was. The server only looks for i| in
    the player's own inventory, so every transfer into or out of a backpack on the
    ground or in a crate was refused, item by item, and the items stayed put.
--]]

--- Describe a container as a string the server can resolve.
-- Returns nil when the container cannot be addressed safely, which is the signal
-- to leave the transfer alone and let the vanilla transaction handle it.
function ZomboidFixesB42.encodeContainer(container, character)
    if not container or not character then return nil end

    if container == character:getInventory() then
        return "p"
    end

    -- The floor is a marker, not an address. There is no single floor container to
    -- point at: the inventory page builds one per player with a nil square, the
    -- server fabricates a throwaway per packet, and the items are really
    -- IsoWorldInventoryObjects in a square's object list. Which square matters is
    -- also per item (where it is lying) or per drop (where there is room), so the
    -- caller has to resolve it itself -- decodeContainer deliberately returns nil
    -- for this.
    if container:getType() == "floor" then return ZomboidFixesB42.FLOOR end

    -- A bag, found by item ID wherever it is: in the player's own inventory tree,
    -- on the ground around them, or inside a container that can itself be encoded.
    local holder = container:getContainingItem()
    if holder then
        local id = tostring(holder:getID())
        if container:isInCharacterInventory(character) then
            return "i" .. SEP .. id
        end
        if holder:getWorldItem() then
            return "g" .. SEP .. id
        end
        local outer = holder:getContainer()
        local outerEncoded = outer and outer ~= container and ZomboidFixesB42.encodeContainer(outer, character)
        if not outerEncoded or outerEncoded == ZomboidFixesB42.FLOOR then return nil end
        return "n" .. SEP .. id .. SEP .. outerEncoded
    end

    local parent = container:getParent()

    -- Vehicle part containers: the container's type is the part ID.
    if parent and instanceof(parent, "BaseVehicle") then
        return "v" .. SEP .. tostring(parent:getId()) .. SEP .. container:getType()
    end

    local square = container:getSourceGrid() or (parent and parent:getSquare())
    if not parent or not square then return nil end

    -- A container on a world object. An object can hold more than one container
    -- (getContainerCount), so the exact one is encoded too rather than assuming
    -- getContainer(). Corpses are not in getObjects(), so they fall out of this
    -- loop and return nil, which is what we want.
    local containerIndex = parent:getContainerIndex(container)
    if containerIndex < 0 then return nil end

    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        if objects:get(i) == parent then
            return table.concat({ "w", square:getX(), square:getY(), square:getZ(), i, containerIndex, container:getType() }, SEP)
        end
    end

    return nil
end

--- Find an item lying on the ground within arm's reach, and the square it is on.
-- Searching only the player's own square and the eight around it is both how far
-- the inventory page's floor panel reaches and a natural reach check.
function ZomboidFixesB42.findItemOnGround(player, itemId)
    local cell = getCell()
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())

    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = cell:getGridSquare(px + dx, py + dy, pz)
            local worldObjects = square and square:getWorldObjects()
            if worldObjects then
                for i = 0, worldObjects:size() - 1 do
                    local worldObject = worldObjects:get(i)
                    local item = worldObject and worldObject:getItem()
                    if item and item:getID() == itemId then
                        return item, square
                    end
                end
            end
        end
    end
    return nil
end

local function splitEncoded(encoded)
    local parts = {}
    for field in string.gmatch(encoded, "([^" .. SEP .. "]+)") do
        table.insert(parts, field)
    end
    return parts
end

--- Find an item by ID anywhere in a container tree.
local function findItemById(container, id, depth)
    if not container or depth > 10 then return nil end
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getID() == id then return item end
        if instanceof(item, "InventoryContainer") then
            local found = findItemById(item:getInventory(), id, depth + 1)
            if found then return found end
        end
    end
    return nil
end

--- Find an item by ID anywhere in a container tree. Used to address an item over
-- the wire: the ID alone is enough, and searching only from the player's own
-- inventory means they cannot reach anything they are not carrying.
function ZomboidFixesB42.findItemById(container, id)
    if not container or type(id) ~= "number" then return nil end
    return findItemById(container, id, 0)
end

--- Resolve an encoded container back to a real one, from the server's point of view.
-- Returns the container, or nil if it cannot be resolved.
function ZomboidFixesB42.decodeContainer(encoded, player)
    if type(encoded) ~= "string" or not player then return nil end

    -- The ground has to be handled per item by the caller, which knows whether it
    -- is picking up (the square the item lies on) or dropping (a square with room).
    if encoded == ZomboidFixesB42.FLOOR then return nil end

    local parts = splitEncoded(encoded)
    local kind = parts[1]

    if kind == "p" then
        return player:getInventory()
    end

    if kind == "i" or kind == "g" or kind == "n" then
        local id = tonumber(parts[2]) or -1
        local holder
        if kind == "i" then
            holder = findItemById(player:getInventory(), id, 0)
        elseif kind == "g" then
            holder = ZomboidFixesB42.findItemOnGround(player, id)
        else
            -- Everything after the second separator is the outer container's own
            -- encoding, separators and all.
            local outer = ZomboidFixesB42.decodeContainer(string.match(encoded, "^n|[^|]*|(.+)$"), player)
            holder = outer and outer:getItemWithID(id)
        end
        if not holder or not instanceof(holder, "InventoryContainer") then return nil end
        return holder:getInventory()
    end

    if kind == "v" then
        local vehicle = getVehicleById(tonumber(parts[2]) or -1)
        if not vehicle then return nil end
        local part = vehicle:getPartById(parts[3])
        return part and part:getItemContainer() or nil
    end

    if kind == "w" then
        local square = getCell():getGridSquare(tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]))
        if not square then return nil end
        local objects = square:getObjects()
        local index = tonumber(parts[5]) or -1
        local containerIndex = tonumber(parts[6]) or -1
        local containerType = parts[7]

        local function containerOn(object)
            if not object or containerIndex < 0 or containerIndex >= object:getContainerCount() then return nil end
            local found = object:getContainerByIndex(containerIndex)
            if found and containerType and found:getType() ~= containerType then return nil end
            return found
        end

        if index >= 0 and index < objects:size() then
            local found = containerOn(objects:get(index))
            if found then return found end
        end
        -- Nothing promises the square's object list is in the same order on the
        -- client and the server, so an index that points at the wrong object is
        -- answered by looking for the container by its type instead.
        if containerType then
            for i = 0, objects:size() - 1 do
                local found = containerOn(objects:get(i))
                if found then return found end
            end
        end
        return nil
    end

    return nil
end

--- Where a container is in the world, for the reach check. Returns nil when it
-- has no position at all. A bag is where its holder is: in the player's hands, on
-- the ground or in the container it sits in.
function ZomboidFixesB42.containerPosition(container, depth)
    local parent = container:getParent()
    if parent then
        return parent:getX(), parent:getY()
    end
    local square = container:getSourceGrid()
    if square then
        return square:getX(), square:getY()
    end
    local holder = container:getContainingItem()
    if holder then
        local worldItem = holder:getWorldItem()
        if worldItem then
            return worldItem:getX(), worldItem:getY()
        end
        local outer = holder:getContainer()
        depth = depth or 0
        if outer and outer ~= container and depth < 10 then
            return ZomboidFixesB42.containerPosition(outer, depth + 1)
        end
    end
    return nil
end
