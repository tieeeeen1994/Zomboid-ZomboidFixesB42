--[[
    Zomboid Fixes B42.20 -- server, rain collectors and drying racks survive a crash

    After a server crash, a killed process or a restored backup, rain collectors,
    wells, amphoras and drying racks stop working (nothing to fill, drink from or
    dry on, until picked up and placed again), and buckets, pots and other
    rain-catching items on the ground turn into plain items that can never hold
    water again, even once picked up.

    Why (Java, 42.21): these objects are entities, and some of their components
    keep running while nobody is near. When a chunk unloads, IsoChunk.removeFromWorld
    calls removeFromWorldToMeta on every object, and GameEntityManager.UnregisterEntity
    moves ALL of an object's components into a MetaEntity if one of them "runs in
    meta" and qualifies (ComponentType flag 2: FluidContainer only while it catches
    rain, getRainCatcher() > 0; CraftLogic, FurnaceLogic, MashingLogic, DryingLogic,
    DryingCraftLogic and Resources always). The object keeps a MetaTagComponent with
    the MetaEntity's ID and is saved in the chunk file like that. MetaEntities are
    saved on their own in <save>/entity_data.bin.

    When the chunk loads again, GameEntityManager.RegisterEntity removes the MetaTag
    and looks the ID up. Found: the components move back and the chunk is flagged
    for a hot save (requiresHotSave), so the chunk file stops pointing at a
    MetaEntity. Not found: it just returns, and the object is left with no
    components at all. The next save writes it like that, for good.

    The hot save never happens on a dedicated server: ServerMap.ServerCell.update
    only processes hot saves when !GameServer.server, so a loaded chunk is written
    only when it unloads again or on a full save (/save, SaveWorldEveryMinutes, a
    clean quit). Meanwhile any other chunk that unloads with such an object
    rewrites entity_data.bin (IsoGridSquare.save sets GameEntityManager.needSave,
    written within a second), now without the MetaEntities that were moved back.
    From then until the next full save, every such loaded chunk is on disk as a
    MetaTag pointing at nothing, so a crash or a kill loses the whole object.
    Backups are worse: ZipBackup copies the live save folder, entity_data.bin is
    rewritten (truncated, then written) outside IsoChunk.WriteLock, and a copy
    taken mid-write loses every MetaEntity in the world at once.

    The other way round also happens (a chunk written with the components while
    entity_data.bin still has its MetaEntity, e.g. a crash in the middle of a full
    save): RegisterEntity then finds the stale MetaEntity under the object's ID and
    returns early, so the object is never added to the entity engine (no rain, no
    drying, no network sync by ID) while the stale MetaEntity is simulated and
    saved forever.

    What this does, on servers only (single player hot-saves chunks together with
    entity_data.bin, ChunkSaveWorker):

      * Repair, as every chunk loads. An entity object (MapObjects.OnLoadWithSprite
        on the sprites of every entity script that can go to meta) left with no
        components gets them again from its script, like a newly built one
        (GameEntityFactory.CreateIsoObjectEntity, what ISBuildIsoEntity does);
        whatever it held is lost. An object that has them but is not in the engine
        gets a MetaTag with its own ID and is added to the world again, so
        RegisterEntity takes over the stale MetaEntity and drops it. A world item
        whose rain-catching container is gone gets an empty one from its item
        script. IsoObject, IsoThumpable and IsoWorldInventoryObject addToWorld can
        run twice on a server: every list they add to is a set or checked first.
        Clients get the result from sendSyncEntity (their copy is registered when
        it came with a MetaTag) and IsoObject.sync (SyncIsoObject creates a missing
        FluidContainer by square and index).
      * Repair of items already picked up broken: rain-catching items with no
        FluidContainer in the inventory of a player who joins, and in the
        containers of every vehicle as it loads, get an empty one, sent to clients
        with sendReplaceItemInContainer (same ID; an equipped or attached item is
        only fixed on the server and shows fixed after a relog).
      * Prevention: a chunk that holds such an object is saved again shortly after
        it loads (IsoChunk.Save, a few chunks per tick), which is the hot save the
        server skips. Skipped while BackupsPeriod is set: ZipBackup holds
        IsoChunk.WriteLock for the whole backup, and a chunk save waiting on it
        would stop the server until the backup ends.
--]]

if isClient() or not isServer() then return end

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.RepairLostEntities ~= false
end

local function log(text)
    print("[ZomboidFixesB42] " .. text)
end

-- Run-in-meta component types that always qualify for meta storage (no
-- isQualifiesForMetaStorage override). FluidContainer is checked on its own.
local LOGIC_TYPES = {
    ComponentType.CraftLogic,
    ComponentType.FurnaceLogic,
    ComponentType.MashingLogic,
    ComponentType.DryingLogic,
    ComponentType.DryingCraftLogic,
    ComponentType.Resources,
}

local function scriptGoesToMeta(script)
    local fluid = script:getComponentScriptFor(ComponentType.FluidContainer)
    if fluid and fluid:getRainCatcher() > 0 then return true end
    for i = 1, #LOGIC_TYPES do
        if script:containsComponent(LOGIC_TYPES[i]) then return true end
    end
    return false
end

local function entityGoesToMeta(entity)
    local fluid = entity:getFluidContainer()
    if fluid and fluid:getRainCatcher() > 0 then return true end
    for i = 1, #LOGIC_TYPES do
        if entity:hasComponent(LOGIC_TYPES[i]) then return true end
    end
    return false
end

-- Classes whose addToWorld does more than the set-like list additions of
-- IsoObject / IsoThumpable / IsoWorldInventoryObject (every other override in
-- zombie/iso/objects). Their components are still repaired, but they only join
-- the entity engine at their next load.
local OWN_ADD_TO_WORLD = {
    "IsoBarbecue", "IsoCarBatteryCharger", "IsoClothingDryer", "IsoClothingWasher",
    "IsoCombinationWasherDryer", "IsoCompost", "IsoDeadBody", "IsoDoor",
    "IsoFeedingTrough", "IsoFire", "IsoFireplace", "IsoGenerator", "IsoHutch",
    "IsoJukebox", "IsoLightSwitch", "IsoMannequin", "IsoStackedWasherDryer",
    "IsoStove", "IsoTrap", "IsoWaveSignal", "IsoWindow",
}

local function canAddAgain(obj)
    for i = 1, #OWN_ADD_TO_WORLD do
        if instanceof(obj, OWN_ADD_TO_WORLD[i]) then return false end
    end
    return true
end

local function where(obj)
    local square = obj:getSquare()
    if not square then return "?" end
    return tostring(square:getX()) .. "," .. tostring(square:getY()) .. "," .. tostring(square:getZ())
end

-- Chunks to save again, oldest first; `queued` keys them by chunk. Each entry
-- keeps a square of the chunk: once the chunk unloads, the square's chunk is
-- cleared (IsoChunk.removeFromWorld, softClear) or it belongs to another one.
local SAVES_PER_TICK = 2
local saveQueue = {}
local queued = {}

local function chunkSavesAllowed()
    local period = getServerOptions():getInteger("BackupsPeriod")
    return not period or period <= 0
end

local function queueSave(square)
    local chunk = square and square:getChunk()
    if not chunk or queued[chunk] then return end
    queued[chunk] = true
    saveQueue[#saveQueue + 1] = { chunk = chunk, square = square }
end

local function saveQueuedChunks()
    if #saveQueue == 0 then return end
    if not isEnabled() or not chunkSavesAllowed() then
        saveQueue = {}
        queued = {}
        return
    end
    for _ = 1, SAVES_PER_TICK do
        local entry = table.remove(saveQueue, 1)
        if not entry then return end
        queued[entry.chunk] = nil
        if entry.square:getChunk() == entry.chunk then
            local ok, err = pcall(function() entry.chunk:Save(true) end)
            if not ok then
                log("Could not save the chunk at " .. where(entry.square) .. ": " .. tostring(err))
            end
        end
    end
end

-- Registers an entity that RegisterEntity turned away. With a MetaTag holding
-- its own ID, RegisterEntity takes the components of a stale MetaEntity stored
-- under that ID and unregisters it; with none there, the MetaTag is simply
-- dropped and the second addToWorld registers the object as it is.
local function registerAgain(obj)
    local id = obj:getEntityNetID()
    if id < 0 then return false end
    local tag = ComponentType.MetaTag:CreateComponent()
    tag:setStoredID(id)
    GameEntityFactory.AddComponent(obj, true, tag)
    obj:addToWorld()
    if obj:hasComponent(ComponentType.MetaTag) then
        GameEntityFactory.RemoveComponentType(obj, ComponentType.MetaTag)
    end
    if not obj:isAddedToEngine() then
        obj:addToWorld()
    end
    return obj:isAddedToEngine()
end

-- Sends a repaired entity to the clients and registers it on the server.
-- sendSyncEntity reaches client copies that are registered (they came with a
-- MetaTag); RegisterEntity's own sync, or ours when it could not run, gives a
-- FluidContainer to the rest.
local function publish(obj)
    obj:sendSyncEntity(nil)
    if canAddAgain(obj) then
        obj:addToWorld()
    end
    if not obj:isAddedToEngine() and obj:getFluidContainer() then
        obj:sync()
    end
end

-- Entity objects -------------------------------------------------------------

-- Sprite name -> the entity script it belongs to, for every entity with a
-- SpriteConfig that can go to meta.
local spriteScripts = {}

local function onEntityObjectLoaded(obj)
    if not isEnabled() then return end
    local sprite = obj:getSprite()
    local script = sprite and spriteScripts[sprite:getName()]
    if not script then return end

    if not obj:hasComponents() then
        GameEntityFactory.CreateIsoObjectEntity(obj, script, true)
        if obj:hasComponents() then
            publish(obj)
            log("Rebuilt the " .. script:getName() .. " at " .. where(obj)
                .. ", which had lost its entity (contents lost)")
        end
    elseif not obj:isAddedToEngine() and entityGoesToMeta(obj) and canAddAgain(obj) then
        if registerAgain(obj) then
            obj:sendSyncEntity(nil)
            log("Registered the " .. script:getName() .. " at " .. where(obj) .. " again")
        end
    end

    if entityGoesToMeta(obj) then
        queueSave(obj:getSquare())
    end
end

-- MapObjects keeps one callback per sprite and priority (a second one with the
-- same priority replaces the first) and runs higher priorities first. Vanilla
-- uses 5 everywhere; this runs before them, so they find the object repaired.
local CALLBACK_PRIORITY = 1000

local registered = false

local function registerSpriteCallbacks()
    if registered then return end
    local infos = SpriteConfigManager.GetObjectInfoList()
    if not infos or infos:isEmpty() then return end
    registered = true
    local names = {}
    for i = 0, infos:size() - 1 do
        local spriteScript = infos:get(i):getScript()
        local script = spriteScript and spriteScript:getParent()
        if script and scriptGoesToMeta(script) then
            local tiles = spriteScript:getAllTileNames()
            for t = 0, tiles:size() - 1 do
                local name = tiles:get(t)
                if not spriteScripts[name] then
                    spriteScripts[name] = script
                    names[#names + 1] = name
                end
            end
        end
    end
    if #names > 0 then
        MapObjects.OnLoadWithSprite(names, onEntityObjectLoaded, CALLBACK_PRIORITY)
    end
end

-- Items ------------------------------------------------------------------------

-- Full type -> its item script's FluidContainer script when it catches rain,
-- else false.
local rainScripts = {}

local function rainScriptOf(item)
    local fullType = item:getFullType()
    local cached = rainScripts[fullType]
    if cached == nil then
        cached = false
        local script = item:getScriptItem()
        local fluid = script and script:getComponentScriptFor(ComponentType.FluidContainer)
        if fluid and fluid:getRainCatcher() > 0 then
            cached = fluid
        end
        rainScripts[fullType] = cached
    end
    return cached or nil
end

local function newEmptyContainer(fluidScript)
    local container = ComponentType.FluidContainer:CreateComponentFromScript(fluidScript)
    container:Empty()
    return container
end

local function repairWorldItem(worldItem)
    local item = worldItem:getItem()
    if not item then return end

    if not worldItem:hasComponent(ComponentType.FluidContainer) and rainScriptOf(item) then
        if item:hasComponent(ComponentType.FluidContainer) then
            GameEntityFactory.TransferComponent(item, worldItem, ComponentType.FluidContainer)
        else
            GameEntityFactory.AddComponent(worldItem, true, newEmptyContainer(rainScriptOf(item)))
        end
        publish(worldItem)
        log("Rebuilt the fluid container of the " .. item:getFullType() .. " on the ground at " .. where(worldItem))
    elseif worldItem:hasComponents() and not worldItem:isAddedToEngine() and entityGoesToMeta(worldItem) then
        if registerAgain(worldItem) then
            worldItem:sendSyncEntity(nil)
            log("Registered the " .. item:getFullType() .. " on the ground at " .. where(worldItem) .. " again")
        end
    end

    if entityGoesToMeta(worldItem) then
        queueSave(worldItem:getSquare())
    end
end

local function onChunkLoaded(chunk)
    if not isEnabled() then return end
    for z = chunk:getMinLevel(), chunk:getMaxLevel() do
        for x = 0, 7 do
            for y = 0, 7 do
                local square = chunk:getGridSquare(x, y, z)
                local worldItems = square and square:getWorldObjects()
                if worldItems and not worldItems:isEmpty() then
                    for i = 0, worldItems:size() - 1 do
                        repairWorldItem(worldItems:get(i))
                    end
                end
            end
        end
    end
end

-- Gives a rain-catching item that lost its FluidContainer an empty one.
-- `container` is the item's container, for the clients.
local function repairItem(item, container)
    if item:getWorldItem() or item:hasComponent(ComponentType.FluidContainer) then return false end
    local fluidScript = rainScriptOf(item)
    if not fluidScript then return false end
    GameEntityFactory.AddComponent(item, true, newEmptyContainer(fluidScript))
    if item:isEquipped() or item:getAttachedSlot() >= 0 then
        -- The client keeps its hand or hotbar copy across a replace, so it would
        -- hold an item no longer in its inventory. Fixed here, shown after a relog.
        return true
    end
    sendReplaceItemInContainer(container, item, item)
    return true
end

local function repairContainer(container, depth)
    if not container or depth > 8 then return 0 end
    local fixed = 0
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if repairItem(item, container) then
            fixed = fixed + 1
        end
        if instanceof(item, "InventoryContainer") then
            fixed = fixed + repairContainer(item:getInventory(), depth + 1)
        end
    end
    return fixed
end

-- Players are checked once, a few seconds after they join (their inventory has
-- reached their client by then); vehicles once each time they load.
local POLL_MS = 5000
local PLAYER_SETTLE_MS = 10000
local lastPoll = 0
local players = {}   -- player -> time first seen, or true once checked
local vehicles = {}  -- vehicle -> true

local function checkPlayersAndVehicles()
    local now = getTimestampMs()
    if now - lastPoll < POLL_MS then return end
    lastPoll = now

    local seenPlayers = {}
    local online = getOnlinePlayers()
    for i = 0, online:size() - 1 do
        local player = online:get(i)
        local state = players[player] or now
        if state ~= true and now - state >= PLAYER_SETTLE_MS then
            local fixed = repairContainer(player:getInventory(), 0)
            if fixed > 0 then
                log("Rebuilt the fluid container of " .. tostring(fixed) .. " item(s) in the inventory of "
                    .. tostring(player:getUsername()))
            end
            state = true
        end
        seenPlayers[player] = state
    end
    players = seenPlayers

    local seenVehicles = {}
    local loaded = ArrayList.new()
    loaded:addAll(getCell():getVehicles())
    for i = 0, loaded:size() - 1 do
        local vehicle = loaded:get(i)
        if not vehicles[vehicle] then
            local fixed = 0
            for p = 0, vehicle:getPartCount() - 1 do
                local part = vehicle:getPartByIndex(p)
                local container = part and part:getItemContainer()
                if container then
                    fixed = fixed + repairContainer(container, 0)
                end
            end
            if fixed > 0 then
                log("Rebuilt the fluid container of " .. tostring(fixed) .. " item(s) in the vehicle at "
                    .. where(vehicle))
            end
        end
        seenVehicles[vehicle] = true
    end
    vehicles = seenVehicles
end

local function onTick()
    if not isEnabled() then return end
    saveQueuedChunks()
    checkPlayersAndVehicles()
end

-- SpriteConfigManager is filled in IsoWorld.init (ScriptManager.PostTileDefinitions),
-- after server Lua loads and before any chunk does.
Events.OnLoadedTileDefinitions.Add(registerSpriteCallbacks)
Events.OnInitGlobalModData.Add(registerSpriteCallbacks)
Events.LoadChunk.Add(onChunkLoaded)
Events.OnTick.Add(onTick)
