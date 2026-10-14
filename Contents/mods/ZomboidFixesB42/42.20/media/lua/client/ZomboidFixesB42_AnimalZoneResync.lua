--[[
    Zomboid Fixes B42.20 -- client, animal pen resync

    The time an animal pen (DesignationZoneAnimal) spends unloaded is made up when
    it loads again. DesignationZone.update (zombie/iso/areas, 42.21) runs from
    IsoWorld.update every 2.5 s with no client check, so every client does it too:

        checkStreamed: either corner square of the zone not loaded -> streamed =
        false, hourLastSeen = (int) world age in hours; both loaded again ->
        streamed = true, doMeta(now - hourLastSeen)

    and DesignationZoneAnimal.doMeta replays those hours on this game's copies of
    the pen's animals (IsoAnimal.updateStatsAway: per hour AnimalData.hourGrow,
    checkEggs, a daily growUp; eatAndDrinkAfterMeta for hungry ones). On a client
    all of it stays local, since IsoGridSquare.AddWorldInventoryItem and
    removeWorldObject only send anything on the server:

      - eggs, feathers and dung are laid on random squares of the pen
        (IsoAnimal.addEgg, AnimalData.dropFeather, checkPoop): items only this
        game has. Picking one up hangs, then does nothing;
      - food on the ground is eaten (removed, or a part of it eaten) and food in a
        feeding trough taken out, ReplaceOnUse leftovers (an empty bag) put in its
        place; water is drunk from the trough: food and water the server still has
        are gone or wrong here.

    The server does the same replay for real when its own copy of the area loads
    (or the animals simply lived on while someone stayed there), and sends its
    results. So the player who comes back to a pen after a while sees about twice
    the eggs, feathers and dung, half of them fake, and less food than there is.
    Removing or adding a square's world objects locally also shifts their indices,
    and the server removes floor items by index (RemoveItemFromSquarePacket), so a
    later pickup on that square can remove the wrong item for this player.

    Nothing in Lua can stop the replay (streamed and hourLastSeen have no setters),
    so this repairs it. The zones are polled every CHECK_MS the way checkStreamed
    does; when one comes back after a whole game hour has turned, SETTLE_MS later
    (doMeta has run, and the server's own replay has arrived) the pen and every pen
    connected to it are checked in blocks of BLOCK x BLOCK squares, one block per
    SEND_GAP_MS: animalZoneCheck { x, y, z, w, h, items, troughs } lists every world
    item on the block ("x,y,id,fingerprint;...") and every feeding trough's water
    and items. The server compares with its own copy and answers animalZoneFix with
    the world items to drop (only this game has them), the ones to add back (with
    their object index on the square, so the indices line up again) or to correct
    (food partly eaten here), and trough items to drop; it re-sends the trough items
    and water it has itself (ID-addressed, so harmless to other players).

    The answer is applied APPLY_DELAY_MS after it arrives and only to what is still
    the same then, so a floor item the server picked up or added in the meantime
    (its own packet lands first) is not touched twice. Items are put back only on
    squares whose objects are still the ones listed in the check: a change there
    while the check was under way (a rake: ISPickupDung removes the dung on the
    server and then on each client by command, both locally, so the server's index
    for a missing item no longer fits) leaves that square alone and the block is
    checked again RETRY_MS later, up to MAX_TRIES times. Putting an item back at a
    stale index would misalign the square, and later pickups there would remove
    the wrong item for this player.

    Left alone: hutches (the server syncs every hutch every 3.5 s), the animals'
    own data that the replay ages here (AnimalPacket brings hunger, thirst, milk,
    wool, health and stress back; age, size and weight stay as replayed until the
    animal is loaded again), and an animal a meta predator kills here
    (sandbox AnimalMetaPredator).

    Multiplayer only. Option AnimalZoneResync.
--]]

if not isClient() then return end

require "ZomboidFixesB42_AnimalZoneResync"

local Resync = ZomboidFixesB42.AnimalZoneResync

local CHECK_MS = 1000
local SETTLE_MS = 5000
-- Checks of one pen network at most this often.
local ZONE_GAP_MS = 60000
local SEND_GAP_MS = 100
local APPLY_DELAY_MS = 1500
local RETRY_MS = 3000
local MAX_TRIES = 3
-- A check whose answer has not come by then is forgotten (no answer = no change).
local IN_FLIGHT_MS = 30000

-- [zone id] = { loaded = bool, leftHour = whole world hour it unloaded, lastCheck = ms }
local zones = {}
-- { zone, due } waiting for SETTLE_MS
local pending = {}
-- blocks to send: { x, y, z, w, h, troughs = { [key] = true } }
local blocks = {}
-- answers waiting for APPLY_DELAY_MS: { due, args }
local answers = {}
-- blocks sent and not answered yet: [x,y,z] = block (+ sentAt, signatures)
local inFlight = {}
-- blocks to check again: { due, block }
local retries = {}

local lastCheckMs = 0
local lastSendMs = 0

local function worldHour()
    return math.floor(getGameTime():getWorldAgeHours())
end

local function bothCornersLoaded(zone)
    local cell = getCell()
    if not cell then return false end
    local x, y, z = zone:getX(), zone:getY(), zone:getZ()
    return cell:getGridSquare(x, y, z) ~= nil
        and cell:getGridSquare(x + zone:getW() - 1, y + zone:getH() - 1, z) ~= nil
end

local function cornerUnloaded(zone)
    local cell = getCell()
    if not cell then return true end
    local x, y, z = zone:getX(), zone:getY(), zone:getZ()
    return cell:getGridSquare(x, y, z) == nil
        or cell:getGridSquare(x + zone:getW() - 1, y + zone:getH() - 1, z) == nil
end

-- ---------------------------------------------------------------------------
-- Watching the pens
-- ---------------------------------------------------------------------------

local function pollZones(now)
    local all = DesignationZoneAnimal.getAllZones()
    if not all then return end
    local seen = {}
    for i = 0, all:size() - 1 do
        local zone = all:get(i)
        local id = zone:getId()
        seen[id] = true
        local state = zones[id]
        if not state then
            local loaded = bothCornersLoaded(zone)
            zones[id] = { loaded = loaded, leftHour = (not loaded) and worldHour() or nil, lastCheck = 0 }
        elseif state.loaded and cornerUnloaded(zone) then
            state.loaded = false
            state.leftHour = worldHour()
        elseif not state.loaded and bothCornersLoaded(zone) then
            state.loaded = true
            -- doMeta replays whole hours only; none have passed, nothing happened.
            if state.leftHour and worldHour() > state.leftHour then
                table.insert(pending, { zone = zone, due = now + SETTLE_MS })
            end
            state.leftHour = nil
        end
    end
    for id in pairs(zones) do
        if not seen[id] then zones[id] = nil end
    end
end

--- Queues the blocks of a pen and every pen connected to it.
local function queuePenNetwork(zone, now)
    local ok, connected = pcall(DesignationZoneAnimal.getAllDZones, nil, zone, nil)
    local list = {}
    if ok and connected then
        for i = 0, connected:size() - 1 do list[#list + 1] = connected:get(i) end
    else
        list[1] = zone
    end

    -- Checked recently as part of another pen's network: skip the whole network.
    for _, z in ipairs(list) do
        local state = zones[z:getId()]
        if state and now - state.lastCheck < ZONE_GAP_MS then return end
    end

    local size = Resync.BLOCK
    for _, z in ipairs(list) do
        local state = zones[z:getId()]
        if state then state.lastCheck = now end

        local troughs = {}
        local zoneTroughs = z:getTroughs()
        if zoneTroughs then
            for i = 0, zoneTroughs:size() - 1 do
                local square = zoneTroughs:get(i):getSquare()
                if square then troughs[Resync.key(square:getX(), square:getY())] = true end
            end
        end

        local x0, y0, zz, w, h = z:getX(), z:getY(), z:getZ(), z:getW(), z:getH()
        for bx = x0, x0 + w - 1, size do
            for by = y0, y0 + h - 1, size do
                table.insert(blocks, {
                    x = bx, y = by, z = zz,
                    w = math.min(size, x0 + w - bx), h = math.min(size, y0 + h - by),
                    troughs = troughs,
                })
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Sending a block
-- ---------------------------------------------------------------------------

local function findTrough(square)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if instanceof(object, "IsoFeedingTrough") and object:getContainer() then return object end
    end
    return nil
end

local function blockKey(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

--- What the square's objects are: their count and the world items' IDs in order.
local function squareSignature(square)
    local parts = { tostring(square:getObjects():size()) }
    local worldObjects = square:getWorldObjects()
    for i = 0, worldObjects:size() - 1 do
        local item = worldObjects:get(i):getItem()
        parts[#parts + 1] = item and tostring(item:getID()) or "-"
    end
    return table.concat(parts, ",")
end

local function sendBlock(block)
    local player = getPlayer()
    local cell = getCell()
    if not player or not cell then return end

    local items, troughs, signatures = {}, {}, {}
    for x = block.x, block.x + block.w - 1 do
        for y = block.y, block.y + block.h - 1 do
            local square = cell:getGridSquare(x, y, block.z)
            if square then
                signatures[Resync.key(x, y)] = squareSignature(square)
                local worldObjects = square:getWorldObjects()
                for i = 0, worldObjects:size() - 1 do
                    local item = worldObjects:get(i):getItem()
                    if item then
                        items[#items + 1] = string.format("%d,%d,%d,%s", x, y, item:getID(), Resync.fingerprint(item))
                    end
                end
                local key = Resync.key(x, y)
                if block.troughs[key] then
                    local trough = findTrough(square)
                    if trough then
                        local contents = {}
                        local list = trough:getContainer():getItems()
                        for i = 0, list:size() - 1 do
                            local item = list:get(i)
                            contents[#contents + 1] = string.format("%d:%s", item:getID(), Resync.fingerprint(item))
                        end
                        troughs[#troughs + 1] = string.format("%d,%d,%.3f,%s", x, y, trough:getWater(), table.concat(contents, "|"))
                    end
                end
            end
        end
    end
    if #items > Resync.MAX_ENTRIES then return end

    block.sentAt = getTimestampMs()
    block.signatures = signatures
    block.tries = (block.tries or 0) + 1
    inFlight[blockKey(block.x, block.y, block.z)] = block
    sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_ANIMAL_ZONE_CHECK, {
        x = block.x, y = block.y, z = block.z, w = block.w, h = block.h,
        items = table.concat(items, ";"),
        troughs = table.concat(troughs, ";"),
    })
end

-- ---------------------------------------------------------------------------
-- Applying the answer
-- ---------------------------------------------------------------------------

local function findWorldObject(square, id)
    local worldObjects = square:getWorldObjects()
    for i = 0, worldObjects:size() - 1 do
        local worldObject = worldObjects:get(i)
        local item = worldObject:getItem()
        if item and item:getID() == id then return worldObject end
    end
    return nil
end

local function dropGhost(square, id)
    local worldObject = findWorldObject(square, id)
    if not worldObject then return end
    pcall(DesignationZoneAnimal.removeItemFromGround, worldObject)
    local item = worldObject:getItem()
    square:removeWorldObject(worldObject)
    if item then item:setWorldItem(nil) end
end

local function setValues(item, rec, full)
    if instanceof(item, "Food") then
        if rec.hung then item:setHungChange(rec.hung) end
        if rec.thirst then item:setThirstChange(rec.thirst) end
        if full then
            if rec.base then item:setBaseHunger(rec.base) end
            if rec.cal then item:setCalories(rec.cal) end
            if rec.carb then item:setCarbohydrates(rec.carb) end
            if rec.lip then item:setLipids(rec.lip) end
            if rec.prot then item:setProteins(rec.prot) end
            if rec.age then item:setAge(rec.age) end
            if rec.cooked ~= nil then item:setCooked(rec.cooked) end
            if rec.burnt ~= nil then item:setBurnt(rec.burnt) end
            if rec.frozen ~= nil then item:setFrozen(rec.frozen) end
        end
    elseif instanceof(item, "DrainableComboItem") and rec.uses then
        item:setCurrentUses(rec.uses)
    end
end

--- Puts back a world item the server has and this game lost, at the server's
-- object index so later index-addressed removals on the square line up.
local function addBack(square, rec)
    local item = instanceItem(rec.type)
    if not item then return end
    item:setID(rec.id)
    pcall(setValues, item, rec, true)

    -- What IsoGridSquare.AddWorldInventoryItem does, but inserted at the index
    -- instead of appended.
    local objects = square:getObjects()
    local index = rec.index
    local ok, worldObject = false, nil
    if index and index >= 0 and index <= objects:size() then
        ok, worldObject = pcall(IsoWorldInventoryObject.new, item, square, rec.ox or 0, rec.oy or 0, rec.oz or 0)
    end
    if not ok or not worldObject then
        square:AddWorldInventoryItem(item, rec.ox or 0, rec.oy or 0, rec.oz or 0, false)
        return
    end
    worldObject:setName(item:getName())
    objects:add(index, worldObject)
    square:getWorldObjects():add(worldObject)
    item:setWorldItem(worldObject)
    worldObject:addToWorld()
    pcall(DesignationZoneAnimal.addItemOnGround, worldObject, square)
    worldObject:invalidateRenderChunkLevel(68)
end

local function eachEntry(text, pattern, fn)
    if type(text) ~= "string" or text == "" then return end
    for entry in string.gmatch(text, "[^;]+") do
        local a, b, c = string.match(entry, pattern)
        if a then fn(tonumber(a), tonumber(b), tonumber(c)) end
    end
end

local function apply(args)
    local cell = getCell()
    local z = tonumber(args.z)
    if not cell or not z then return end

    -- Squares changed since the check was sent, worked out before this answer
    -- changes anything.
    local block
    local x0, y0 = tonumber(args.x), tonumber(args.y)
    if x0 and y0 then
        local key = blockKey(x0, y0, z)
        block = inFlight[key]
        inFlight[key] = nil
    end
    local stale = {}
    if block and block.signatures then
        for key, signature in pairs(block.signatures) do
            local x, y = string.match(key, "^(%-?%d+),(%-?%d+)$")
            local square = cell:getGridSquare(tonumber(x), tonumber(y), z)
            if not square or squareSignature(square) ~= signature then stale[key] = true end
        end
    end
    local retry = false

    eachEntry(args.ghosts, "^(%-?%d+),(%-?%d+),(%-?%d+)$", function(x, y, id)
        local square = cell:getGridSquare(x, y, z)
        if square then dropGhost(square, id) end
    end)

    local refresh = {}
    eachEntry(args.troughGhosts, "^(%-?%d+),(%-?%d+),(%-?%d+)$", function(x, y, id)
        local square = cell:getGridSquare(x, y, z)
        local trough = square and findTrough(square)
        if trough then
            local container = trough:getContainer()
            local item = container:getItemWithID(id)
            if item then
                container:DoRemoveItem(item)
                container:setDrawDirty(true)
            end
            refresh[trough] = true
        end
    end)
    eachEntry(args.troughs, "^(%-?%d+),(%-?%d+)$", function(x, y)
        local square = cell:getGridSquare(x, y, z)
        local trough = square and findTrough(square)
        if trough then refresh[trough] = true end
    end)
    for trough in pairs(refresh) do
        pcall(function() trough:checkOverlayAfterAnimalEat() end)
    end

    if type(args.records) == "table" then
        for _, rec in ipairs(args.records) do
            local x, y, id = tonumber(rec.x), tonumber(rec.y), tonumber(rec.id)
            local square = x and y and cell:getGridSquare(x, y, z)
            if square and id then
                local worldObject = findWorldObject(square, id)
                if worldObject then
                    pcall(setValues, worldObject:getItem(), rec, false)
                elseif rec.missing and type(rec.type) == "string" then
                    if stale[Resync.key(x, y)] then
                        retry = true
                    else
                        rec.id = id
                        addBack(square, rec)
                    end
                end
            end
        end
    end

    if retry and block.tries < MAX_TRIES then
        table.insert(retries, { due = getTimestampMs() + RETRY_MS, block = block })
    end
end

-- ---------------------------------------------------------------------------

local function onTick()
    local now = getTimestampMs()

    if #answers > 0 then
        local keep = {}
        for _, answer in ipairs(answers) do
            if now >= answer.due then apply(answer.args) else keep[#keep + 1] = answer end
        end
        answers = keep
    end

    local expired = {}
    for key, block in pairs(inFlight) do
        if now - block.sentAt > IN_FLIGHT_MS then expired[#expired + 1] = key end
    end
    for _, key in ipairs(expired) do inFlight[key] = nil end

    if not Resync.isEnabled() then
        pending = {}
        blocks = {}
        retries = {}
        return
    end

    if now - lastCheckMs >= CHECK_MS then
        lastCheckMs = now
        pollZones(now)
    end

    if #pending > 0 then
        local keep = {}
        for _, entry in ipairs(pending) do
            if now >= entry.due then queuePenNetwork(entry.zone, now) else keep[#keep + 1] = entry end
        end
        pending = keep
    end

    if #retries > 0 then
        local keep = {}
        for _, entry in ipairs(retries) do
            if now >= entry.due then table.insert(blocks, entry.block) else keep[#keep + 1] = entry end
        end
        retries = keep
    end

    if #blocks > 0 and now - lastSendMs >= SEND_GAP_MS then
        lastSendMs = now
        sendBlock(table.remove(blocks, 1))
    end
end

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_ANIMAL_ZONE_FIX then return end
    if type(args) ~= "table" then return end
    table.insert(answers, { due = getTimestampMs() + APPLY_DELAY_MS, args = args })
end

Events.OnTick.Add(onTick)
Events.OnServerCommand.Add(onServerCommand)

Events.OnInitWorld.Add(function()
    zones = {}
    pending = {}
    blocks = {}
    answers = {}
    inFlight = {}
    retries = {}
end)
