--[[
    Zomboid Fixes B42.20 -- client, seen rooms stay lit after relogging

    A square the player has never seen is drawn dark: IsoGridSquare.CalcVisibility
    gives an unseen square a target dark multiplier of 0, and the native lighting
    reads the same per-player flag (LightingJNI.updateChunk: sq.isSeen(playerIndex)).
    In single player that flag is saved with the chunk (IsoGridSquare.save / load,
    one bit per player, ~2976 and ~3362), but only when
    `!GameClient.client && !GameServer.server`: a server writes 0 and a client
    ignores the byte. So in multiplayer every building interior the player has been
    through goes dark again whenever its chunk loads anew, after every relog or a
    long trip away (forum 99809). Nothing on the server knows what each player has
    seen. The client does not load map_meta.bin either (IsoWorld.init), so every
    RoomDef starts unexplored on every join, which also replays the music's "see
    unexplored room" cue.

    The client marks a RoomDef explored once the player sees one of its squares
    from close by (IsoGridSquare.checkRoomSeen: within 10 tiles, 50 inside the same
    building). This keeps those rooms, per server and account, in
    Zomboid/Lua/ZomboidFixesB42_SeenRooms_<ip>_<port>_<user>.txt (one "x,y,z" per
    room: the room's bounds corner and level, stable across sessions; room IDs are
    64-bit and lose precision as Lua numbers), and whenever a chunk loads sets every
    square of a remembered room in it seen for the local players, marks the room
    explored again and asks for the chunk's lighting to be redone. Rooms are
    remembered whole, so a room only glimpsed from its doorway comes back fully lit.
--]]

if not isClient() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.RememberSeenRooms == true
end

local POLL_MS = 2000        -- how often explored rooms near the player are recorded
local POLL_RADIUS = 40      -- tiles around the player searched for explored rooms
local SAVE_MS = 30000       -- how often a changed list is written

local seen = nil            -- "x,y,z" -> true, once the file is read
local dirty = false
local pendingChunks = {}    -- chunks loaded before the file could be read
local lastPollMs, lastSaveMs = 0, 0
local roomList = nil

local function roomKey(def)
    return string.format("%d,%d,%d", def:getX(), def:getY(), def:getZ())
end

local function fileName()
    -- The account name is known from the connection on, before the player exists
    -- and while the first chunks load.
    local user = getClientUsername()
    if not user or user == "" then
        local player = getSpecificPlayer(0)
        user = player and player:getUsername()
    end
    if not user or user == "" then return nil end
    local server = tostring(getServerIP() or "") .. "_" .. tostring(getServerPort() or "") .. "_" .. user
    return "ZomboidFixesB42_SeenRooms_" .. string.gsub(server, "[^%w]", "_") .. ".txt"
end

local function load()
    local name = fileName()
    if not name then return false end
    seen = {}
    local reader = getFileReader(name, false)
    if reader then
        local line = reader:readLine()
        while line do
            if line ~= "" then seen[line] = true end
            line = reader:readLine()
        end
        reader:close()
    end
    return true
end

local function save()
    if not seen or not dirty then return end
    local name = fileName()
    if not name then return end
    local writer = getFileWriter(name, true, false)
    if not writer then return end
    for key in pairs(seen) do
        writer:write(key .. "\n")
    end
    writer:close()
    dirty = false
end

--- World x, y of the chunk's corner, from any square it has.
local function chunkOrigin(chunk)
    for z = chunk:getMinLevel(), chunk:getMaxLevel() do
        for i = 0, 63 do
            local square = chunk:getGridSquare(i % 8, math.floor(i / 8), z)
            if square then
                return square:getX() - square:getX() % 8, square:getY() - square:getY() % 8
            end
        end
    end
    return nil
end

--- Set every square of the remembered rooms in this chunk seen.
local function applyToChunk(chunk)
    local x0, y0 = chunkOrigin(chunk)
    if not x0 then return end
    roomList = roomList or ArrayList.new()
    roomList:clear()
    getWorld():getMetaGrid():getRoomsIntersecting(x0, y0, 8, 8, roomList)
    local changed = false
    for i = 0, roomList:size() - 1 do
        local def = roomList:get(i)
        if seen[roomKey(def)] then
            def:setExplored(true)
            local z = def:getZ()
            local rects = def:getRects()
            for r = 0, rects:size() - 1 do
                local rect = rects:get(r)
                local xa, xb = math.max(rect:getX(), x0), math.min(rect:getX2(), x0 + 8) - 1
                local ya, yb = math.max(rect:getY(), y0), math.min(rect:getY2(), y0 + 8) - 1
                for x = xa, xb do
                    for y = ya, yb do
                        local square = chunk:getGridSquare(x - x0, y - y0, z)
                        if square then
                            for p = 0, getNumActivePlayers() - 1 do
                                if getSpecificPlayer(p) and not square:isSeen(p) then
                                    square:setIsSeen(p, true)
                                    changed = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    roomList:clear()
    if changed then
        for p = 0, getNumActivePlayers() - 1 do
            chunk:checkLightingLater_OnePlayer_AllLevels(p)
        end
    end
end

local function onLoadChunk(chunk)
    if not isEnabled() then return end
    if not seen then
        if not load() then
            table.insert(pendingChunks, chunk)
            return
        end
    end
    applyToChunk(chunk)
end

--- Record the rooms around the player the game now counts as explored.
local function recordExplored(player)
    roomList = roomList or ArrayList.new()
    roomList:clear()
    local x, y = math.floor(player:getX()), math.floor(player:getY())
    getWorld():getMetaGrid():getRoomsIntersecting(x - POLL_RADIUS, y - POLL_RADIUS, POLL_RADIUS * 2, POLL_RADIUS * 2, roomList)
    for i = 0, roomList:size() - 1 do
        local def = roomList:get(i)
        if def:isExplored() then
            local key = roomKey(def)
            if not seen[key] then
                seen[key] = true
                dirty = true
            end
        end
    end
    roomList:clear()
end

local function onTick()
    if not isEnabled() then return end
    local player = getSpecificPlayer(0)
    if not player then return end
    if not seen then
        if not load() then return end
    end
    if #pendingChunks > 0 then
        local chunks = pendingChunks
        pendingChunks = {}
        for _, chunk in ipairs(chunks) do applyToChunk(chunk) end
    end
    local now = getTimestampMs()
    if now - lastPollMs >= POLL_MS then
        lastPollMs = now
        for p = 0, getNumActivePlayers() - 1 do
            local other = getSpecificPlayer(p)
            if other then recordExplored(other) end
        end
    end
    if dirty and now - lastSaveMs >= SAVE_MS then
        lastSaveMs = now
        save()
    end
end

Events.LoadChunk.Add(onLoadChunk)
Events.OnTick.Add(onTick)
if Events.OnDisconnect then Events.OnDisconnect.Add(save) end
