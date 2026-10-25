--[[
    Zomboid Fixes B42.20 -- server, knocked-off hats and masks keep their place

    A hat, helmet, mask or pair of glasses knocked off a player or a zombie
    (IsoGameCharacter.helmetFall, 42.21 ~7970: server only, from a zombie attack
    that is not a thump, BodyDamage ~1433, a fall, fallenOnKnees, a weapon hit on a
    zombie) is put on the server's floor with AddWorldInventoryItem(..., transmit =
    false), at the end of the square's object list. Clients only get a
    ZombieHelmetFalling packet, which makes each of them throw an IsoFallingClothing
    that lands up to 60 frames later and then adds its own copy, also at the end.

    Anything that reaches the same square in that second lands before it on the
    clients and after it on the server. The usual case: the zombie attack that
    knocks a gas mask off goes on to tear a hole in the scarf under it, the scarf
    breaks and drops (transmitted at once, AddItemToMap), and the clients end up
    with [scarf, mask] where the server has [mask, scarf]. Floor items are removed
    on clients by object index (RemoveItemFromSquarePacket), so picking the scarf up
    removes the mask on every client, the scarf stays on other players' floors,
    and the mask is back (on the server all along) after a relog.

    So a client asks for the server's order of a square's floor items when a
    falling item lands there (client/ZomboidFixesB42_FallenClothing.lua), and this
    file answers with the object index and item ID of every world item on the
    square. The answer only describes the square; nothing is changed here.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.FallenClothingSync == true
end

-- A client only asks for squares it has loaded around itself.
local MAX_DISTANCE = 150
-- Requests a player may send a second.
local RATE_LIMIT = 20

-- [player online ID] = { second = whole second, count = requests in it }
local rates = {}

local function withinRate(player)
    local second = math.floor(getTimestampMs() / 1000)
    local id = player:getOnlineID()
    local rate = rates[id]
    if not rate or rate.second ~= second then
        rate = { second = second, count = 0 }
        rates[id] = rate
    end
    rate.count = rate.count + 1
    return rate.count <= RATE_LIMIT
end

local function int(value)
    local n = tonumber(value)
    if not n or n ~= math.floor(n) then return nil end
    return n
end

local function onFloorOrder(player, args)
    if not isEnabled() or not player or not withinRate(player) then return end

    local x, y, z = int(args.x), int(args.y), int(args.z)
    if not x or not y or not z then return end
    local dx, dy = player:getX() - x, player:getY() - y
    if dx * dx + dy * dy > MAX_DISTANCE * MAX_DISTANCE then return end

    local square = getCell():getGridSquare(x, y, z)
    if not square then return end

    local objects = square:getObjects()
    local items = {}
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if instanceof(object, "IsoWorldInventoryObject") then
            local item = object:getItem()
            items[#items + 1] = i .. ":" .. (item and tostring(item:getID()) or "-")
        end
    end

    sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FLOOR_ORDER_REPLY, {
        x = x, y = y, z = z,
        count = objects:size(),
        items = table.concat(items, ";"),
    })
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_FLOOR_ORDER then return end
    onFloorOrder(player, type(args) == "table" and args or {})
end

Events.OnClientCommand.Add(onClientCommand)
