--[[
    Zomboid Fixes B42.20 -- server, animal pen resync

    A client replays the hours an animal pen spent unloaded on its own copy of the
    pen when it loads again (client/ZomboidFixesB42_AnimalZoneResync.lua has the
    Java): fake eggs, feathers and dung, and food on the ground and in feeding
    troughs eaten or drunk only there. The client then lists one block of the pen
    at a time, animalZoneCheck { x, y, z, w, h, items, troughs }:

        items    "x,y,id,fingerprint;..."      every world item on the block
        troughs  "x,y,water,id:fp|id:fp;..."   each feeding trough there

    and this compares the block with the server's copy and answers animalZoneFix:

        ghosts        "x,y,id;..."   world items only the client has: dropped there
        records       { x, y, id, missing, index, type, ox, oy, oz, food values }
                      a world item the client lacks (missing: put back at this
                      object index) or has with another fingerprint (corrected)
        troughGhosts  "x,y,id;..."   trough items only the client has
        troughs       "x,y;..."      troughs whose contents were re-sent

    Trough items the client lacks or has with other values are sent again with
    sendReplaceItemInContainer (the client drops the item with that ID, if any, and
    adds the server's copy; it goes to every client near the trough, which changes
    nothing for one that already has it), and trough water that differs with
    sendSyncEntity (the trough's FluidContainer component, as vanilla's
    feedingTrough.addWaterDebug does). Squares the server has not loaded are
    skipped. Only reads and re-sends what the server has: a client can never add,
    remove or change anything on the server through this.

    Checked: the block is at most BLOCK x BLOCK, touches an animal pen, lies within
    MAX_DISTANCE of the player, and a player sends at most RATE_LIMIT blocks a
    second. Option AnimalZoneResync.
--]]

if isClient() then return end

require "ZomboidFixesB42_AnimalZoneResync"

local Resync = ZomboidFixesB42.AnimalZoneResync

local MAX_DISTANCE = 150
local RATE_LIMIT = 30
-- Trough water that differs by more than this is sent again (the client's copy
-- is printed with 3 decimals).
local WATER_EPSILON = 0.01

-- [player online ID] = { second, count }
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

--- "x,y,id,fp;..." -> [key] = { [id] = fp }
local function parseItems(text)
    local map = {}
    if type(text) ~= "string" then return map end
    for entry in string.gmatch(text, "[^;]+") do
        local x, y, id, fp = string.match(entry, "^(%-?%d+),(%-?%d+),(%-?%d+),(.*)$")
        if x then
            local key = Resync.key(tonumber(x), tonumber(y))
            map[key] = map[key] or {}
            map[key][tonumber(id)] = fp
        end
    end
    return map
end

--- "x,y,water,id:fp|...;..." -> [key] = { water, items = { [id] = fp } }
local function parseTroughs(text)
    local map = {}
    if type(text) ~= "string" then return map end
    for entry in string.gmatch(text, "[^;]+") do
        local x, y, water, contents = string.match(entry, "^(%-?%d+),(%-?%d+),([%d%.%-]+),(.*)$")
        if x then
            local trough = { water = tonumber(water) or 0, items = {} }
            for pair in string.gmatch(contents, "[^|]+") do
                local id, fp = string.match(pair, "^(%-?%d+):(.*)$")
                if id then trough.items[tonumber(id)] = fp end
            end
            map[Resync.key(tonumber(x), tonumber(y))] = trough
        end
    end
    return map
end

local function findTrough(square)
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if instanceof(object, "IsoFeedingTrough") and object:getContainer() then return object end
    end
    return nil
end

local function record(x, y, worldObject, item, missing, index)
    local rec = { x = x, y = y, id = item:getID(), missing = missing }
    if missing then
        rec.type = item:getFullType()
        rec.index = index
        rec.ox = worldObject:getOffX()
        rec.oy = worldObject:getOffY()
        rec.oz = worldObject:getOffZ()
    end
    if instanceof(item, "Food") then
        rec.hung = item:getHungChange()
        rec.thirst = item:getThirstChange()
        if missing then
            rec.base = item:getBaseHunger()
            rec.cal = item:getCalories()
            rec.carb = item:getCarbohydrates()
            rec.lip = item:getLipids()
            rec.prot = item:getProteins()
            rec.age = item:getAge()
            rec.cooked = item:isCooked()
            rec.burnt = item:isBurnt()
            rec.frozen = item:isFrozen()
        end
    elseif instanceof(item, "DrainableComboItem") then
        rec.uses = item:getCurrentUses()
    end
    return rec
end

local function checkTrough(x, y, square, reported, answer)
    local trough = findTrough(square)
    if not trough then return end
    local container = trough:getContainer()
    local seen = {}
    local resent = false
    local list = container:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local id = item:getID()
        seen[id] = true
        if reported.items[id] ~= Resync.fingerprint(item) then
            sendReplaceItemInContainer(container, item, item)
            resent = true
        end
    end
    local ghosts = 0
    for id in pairs(reported.items) do
        if not seen[id] then
            answer.troughGhosts[#answer.troughGhosts + 1] = string.format("%d,%d,%d", x, y, id)
            ghosts = ghosts + 1
        end
    end
    if math.abs(trough:getWater() - reported.water) > WATER_EPSILON then
        trough:sendSyncEntity(nil)
        resent = true
    end
    if resent or ghosts > 0 then
        answer.troughs[#answer.troughs + 1] = string.format("%d,%d", x, y)
    end
end

local function onCheck(player, args)
    if not Resync.isEnabled() or not player or not withinRate(player) then return end

    local x0, y0, z = int(args.x), int(args.y), int(args.z)
    local w, h = int(args.w), int(args.h)
    if not x0 or not y0 or not z or not w or not h then return end
    if w < 1 or h < 1 or w > Resync.BLOCK or h > Resync.BLOCK then return end
    if not DesignationZoneAnimal.getZone(x0, y0, z) and not DesignationZoneAnimal.getZone(x0 + w - 1, y0 + h - 1, z) then
        return
    end
    local dx = player:getX() - (x0 + w / 2)
    local dy = player:getY() - (y0 + h / 2)
    if dx * dx + dy * dy > MAX_DISTANCE * MAX_DISTANCE then return end

    local reportedItems = parseItems(args.items)
    local reportedTroughs = parseTroughs(args.troughs)

    local answer = { x = x0, y = y0, z = z, ghosts = {}, records = {}, troughGhosts = {}, troughs = {} }
    local cell = getCell()
    for x = x0, x0 + w - 1 do
        for y = y0, y0 + h - 1 do
            local square = cell:getGridSquare(x, y, z)
            if square then
                local key = Resync.key(x, y)
                local reported = reportedItems[key] or {}
                local seen = {}
                local objects = square:getObjects()
                local worldObjects = square:getWorldObjects()
                local missing = {}
                for i = 0, worldObjects:size() - 1 do
                    local worldObject = worldObjects:get(i)
                    local item = worldObject:getItem()
                    if item then
                        local id = item:getID()
                        seen[id] = true
                        local fp = reported[id]
                        if fp == nil then
                            missing[#missing + 1] = record(x, y, worldObject, item, true, objects:indexOf(worldObject))
                        elseif fp ~= Resync.fingerprint(item) then
                            answer.records[#answer.records + 1] = record(x, y, worldObject, item, false)
                        end
                    end
                end
                -- Put back in index order, so each insert lands where the server has it.
                table.sort(missing, function(a, b) return a.index < b.index end)
                for _, rec in ipairs(missing) do answer.records[#answer.records + 1] = rec end
                for id in pairs(reported) do
                    if not seen[id] then
                        answer.ghosts[#answer.ghosts + 1] = string.format("%d,%d,%d", x, y, id)
                    end
                end
                if reportedTroughs[key] then
                    checkTrough(x, y, square, reportedTroughs[key], answer)
                end
            end
        end
    end

    if #answer.ghosts == 0 and #answer.records == 0 and #answer.troughGhosts == 0 and #answer.troughs == 0 then
        return
    end
    local ghostCount, recordCount = #answer.ghosts, #answer.records
    answer.ghosts = table.concat(answer.ghosts, ";")
    answer.troughGhosts = table.concat(answer.troughGhosts, ";")
    answer.troughs = table.concat(answer.troughs, ";")
    sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_ANIMAL_ZONE_FIX, answer)
    if ghostCount > 0 or recordCount > 0 then
        print(string.format("[ZomboidFixesB42] animal pen resync for %s at %d,%d,%d: %d fake items, %d missing or changed",
            player:getUsername(), x0, y0, z, ghostCount, recordCount))
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_ANIMAL_ZONE_CHECK then return end
    onCheck(player, type(args) == "table" and args or {})
end

Events.OnClientCommand.Add(onClientCommand)
