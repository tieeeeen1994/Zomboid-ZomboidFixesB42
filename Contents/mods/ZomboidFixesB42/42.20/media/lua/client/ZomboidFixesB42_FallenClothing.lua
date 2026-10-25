--[[
    Zomboid Fixes B42.20 -- client, knocked-off hats and masks keep their place

    When a hat or mask is knocked off, the server puts it at the end of the
    square's object list at once, while this game shows it falling and adds its
    copy at the end up to a second later (server/ZomboidFixesB42_FallenClothing.lua
    has the Java). Whatever reached the square in between, like the scarf the same
    zombie attack tore and dropped, then sits before it here and after it on the
    server. Floor items are removed by object index, so picking up the scarf
    removed the mask here (and on every other client), and the mask came back
    after a relog.

    IsoFallingClothing.drop() fires OnContainerUpdate with the square it landed on
    (the only other caller passing a square is the removal of a corpse). DELAY_MS
    later, so that item packets already on their way land first, this file asks
    the server for the order of that square's floor items and puts its own in the
    same order. Only an answer that matches what is here is used: the same number
    of objects, the same world items, at the same set of positions, so only the
    world items swap places among themselves (PZArrayList.set: nothing else in the
    list moves). Anything else (an item still on its way, a ghost) is asked again
    RETRY_MS later, up to TRIES times, then left alone.
--]]

if not isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.FallenClothingSync == true
end

-- Wait after a landing before asking, so item packets already sent arrive first.
local DELAY_MS = 300
-- Wait before asking again after an answer that did not match.
local RETRY_MS = 1000
-- Questions asked per landing.
local TRIES = 3
-- An unanswered question (square not loaded on the server) is dropped after this.
local REPLY_TIMEOUT_MS = 5000

-- ["x,y,z"] = { x, y, z, due, tries, sentAt, again }
local squares = {}

local function keyOf(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

local function onContainerUpdate(object)
    if not isEnabled() or not instanceof(object, "IsoGridSquare") then return end
    local x, y, z = object:getX(), object:getY(), object:getZ()
    local key = keyOf(x, y, z)
    local entry = squares[key]
    if entry then
        -- Another item landed while asking: once this answer is in, ask again.
        if entry.sentAt then entry.again = true end
        return
    end
    squares[key] = { x = x, y = y, z = z, due = getTimestampMs() + DELAY_MS, tries = 0 }
end

local function onTick()
    -- Keys copied out first so entries can be removed while walking them.
    local keys = {}
    for key in pairs(squares) do
        keys[#keys + 1] = key
    end
    if #keys == 0 then return end

    local now = getTimestampMs()
    local player = getPlayer()
    for _, key in ipairs(keys) do
        local entry = squares[key]
        if entry.sentAt then
            if now - entry.sentAt > REPLY_TIMEOUT_MS then squares[key] = nil end
        elseif now >= entry.due and player then
            entry.tries = entry.tries + 1
            entry.sentAt = now
            sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FLOOR_ORDER, {
                x = entry.x, y = entry.y, z = entry.z,
            })
        end
    end
end

--- Puts this square's world items in the server's order. Returns false when the
-- square does not match the answer, so it is asked again.
local function apply(square, args)
    local objects = square:getObjects()
    if objects:size() ~= tonumber(args.count) then return false end

    -- [object index] = item ID on the server
    local wanted = {}
    local count = 0
    for index, id in string.gmatch(type(args.items) == "string" and args.items or "", "(%d+):([%d-]+)") do
        if id == "-" then return false end
        wanted[tonumber(index)] = tonumber(id)
        count = count + 1
    end

    -- [item ID] = this game's world object
    local byId = {}
    local moved = false
    local here = 0
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if instanceof(object, "IsoWorldInventoryObject") then
            local item = object:getItem()
            if not item or not wanted[i] then return false end
            byId[item:getID()] = object
            here = here + 1
            if item:getID() ~= wanted[i] then moved = true end
        end
    end
    if here ~= count then return false end
    if not moved then return true end

    for _, id in pairs(wanted) do
        if not byId[id] then return false end
    end
    for index, id in pairs(wanted) do
        objects:set(index, byId[id])
    end
    pcall(function() square:invalidateRenderChunkLevel(68) end)
    print(string.format("[ZomboidFixesB42] floor items at %d,%d,%d put back in the server's order",
        square:getX(), square:getY(), square:getZ()))
    return true
end

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_FLOOR_ORDER_REPLY then return end
    if type(args) ~= "table" then return end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not x or not y or not z then return end
    local key = keyOf(x, y, z)
    local entry = squares[key]
    if not entry or not entry.sentAt then return end

    local square = getCell() and getCell():getGridSquare(x, y, z)
    local done = not square or not isEnabled() or apply(square, args)
    entry.sentAt = nil
    if (done and entry.again) or (not done and entry.tries < TRIES) then
        if done then entry.tries = 0 end
        entry.again = false
        entry.due = getTimestampMs() + (done and DELAY_MS or RETRY_MS)
    else
        squares[key] = nil
    end
end

Events.OnContainerUpdate.Add(onContainerUpdate)
Events.OnTick.Add(onTick)
Events.OnServerCommand.Add(onServerCommand)

Events.OnInitWorld.Add(function()
    squares = {}
end)
