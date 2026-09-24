--[[
    Zomboid Fixes B42.20 -- shared

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

-- server -> clients
ZomboidFixesB42.CMD_ANIMAL_GENDER_SYNC = "animalGenderSync"
ZomboidFixesB42.CMD_FORAGE_ZONE_RESET = "forageZoneReset"
ZomboidFixesB42.CMD_TRANSFER_DECLINED = "transferDeclined"
ZomboidFixesB42.CMD_FAST_FORWARD_STATE = "fastForwardState"
ZomboidFixesB42.CMD_BODY_STATS_STATE = "bodyStatsState"

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
-- ISInventoryTransferAction maxTime (container to inventory is around 50 before
-- weight and capacity scaling). Deliberately short rather than zero: at maxTime 1
-- the action finishes inside a single frame, which loses the animation, the
-- job-delta progress on the item and any sense that a queue is draining. Tune here.
ZomboidFixesB42.TRANSFER_MAX_TIME = 5

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

    p                          the player's own main inventory
    i|<itemID>                 a bag or other item-backed container
    v|<vehicleID>|<partID>     a vehicle part container
    w|<x>|<y>|<z>|<obj>|<con>  a container on a world object, by the object's index
                               on the square and the container's index on the object

    Anything else returns nil, and the caller falls back to vanilla behaviour.
    Floor containers and corpses are deliberately not encoded -- see the comment
    on ZomboidFixesB42.encodeContainer.
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

    -- A bag. The server finds it by item ID inside the player's own inventory
    -- tree, so a bag sitting in a crate resolves to nil and falls back.
    local holder = container:getContainingItem()
    if holder then
        return "i" .. SEP .. tostring(holder:getID())
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
            return table.concat({ "w", square:getX(), square:getY(), square:getZ(), i, containerIndex }, SEP)
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

    if kind == "i" then
        local holder = findItemById(player:getInventory(), tonumber(parts[2]) or -1, 0)
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
        if index < 0 or index >= objects:size() then return nil end
        local object = objects:get(index)
        if not object then return nil end

        local containerIndex = tonumber(parts[6])
        if not containerIndex or containerIndex < 0 or containerIndex >= object:getContainerCount() then
            return nil
        end
        return object:getContainerByIndex(containerIndex)
    end

    return nil
end

--- Where a container is in the world, for the reach check. Returns nil for
-- containers the player is carrying, which are always in reach.
function ZomboidFixesB42.containerPosition(container)
    local parent = container:getParent()
    if parent then
        return parent:getX(), parent:getY()
    end
    local square = container:getSourceGrid()
    if square then
        return square:getX(), square:getY()
    end
    return nil
end
