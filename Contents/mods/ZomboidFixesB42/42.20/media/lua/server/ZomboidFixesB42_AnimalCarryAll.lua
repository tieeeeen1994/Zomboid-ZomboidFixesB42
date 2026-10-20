--[[
    Zomboid Fixes B42.20 -- server, carry every animal of a kind (admin)

    Vanilla moves animals one at a time: pick one up (ISPickupAnimal, which also
    force-drops whatever is in the hands, so only one can be carried), walk, put it
    down. Moving a flock of a few hundred hens that way is not practical, and there
    is no teleport for animals at all. So an admin can take every loose animal of
    one type and breed in a pen into their main inventory at once, and put them all
    down again wherever they stand.

    How vanilla carries an animal (42.21): an AnimalInventoryItem ("Base.Animal")
    holding the IsoAnimal; ISPickupAnimal:complete runs instanceItem + setAnimal +
    AddItem, removeFromWorld / removeFromSquare / setSquare(nil), then
    sendPickupAnimal. That packet (AnimalCommand PickupAnimal) goes to the clients
    near the *player* and each acts only when its own AnimalInstanceManager knows the
    animal's ID, so an admin whose client never loaded a far animal would never see
    the item. Vanilla's ISHutchGrabAnimal sends the item with sendAddItemToContainer
    instead (full item bytes, the whole IsoAnimal.save, to the owner only), and so
    does this. Clients near the pen drop their world copy when the server's update of
    the carried animal syncs it as no longer in the world (within about 5 s).

    The item weighs adef.baseEncumbrance * getAnimalSize() (AnimalInventoryItem,
    set at setAnimal / load): about 20 for a hen, 130 for a cow. Only "floor" takes
    animal items (ItemContainer.isItemAllowed), so they stay in the main inventory,
    and nothing drops a carried animal that is not held. Several hundred are only
    sensible with Unlimited Carry; the client says so before asking.

    Carried animals keep living on the server (IsoCell ProcessItems, every 5 real
    s: AnimalInventoryItem.update -> animal.update; hunger and thirst rise slowly, a
    hen's thirst by 0.001 an hour), hens lay eggs into the inventory on the server
    only, and a birth spawns at the pick-up spot. Carry them for a move, not a stay.

    Putting down: IsoGridSquare.AddWorldInventoryItem(item, x, y, h, true) builds a
    new IsoAnimal on the square, copies the carried one (copyFrom: genome, name, age,
    stats, sex...), reuses its online ID, addToWorld, tells the clients near the
    square (DropAnimal) and stops processing the item. Vanilla's drop does the same
    from a transaction per animal (about 300 ms each, one square at a time); here
    the server does it directly over the 3x3 squares round the admin.

    Putting down waits for the pen (42.21, DesignationZone / DesignationZoneAnimal):
    a zone counts as away as soon as one of its two corners (x, y and x + w - 1,
    y + h - 1) is not loaded (`checkStreamed`, every 2.5 s in DesignationZone.update,
    server and clients), noting `hourLastSeen`; the first check that finds both loaded
    again runs `doMeta(now - hourLastSeen)`, which replays every hour on each animal
    in the zone's list (`IsoAnimal.updateStatsAway`: age + hours / 24 days, then per
    hour `hourGrow(true)`: hunger, thirst, health loss above 0.8 of either, feathers,
    eggs, milk). Animals put down in a huge pen while its far corner was out of reach
    were in that list when the corner loaded, and had every hour the pen had been away
    replayed on them at once: they aged days and starved to death within seconds. So a
    drop waits until every zone under the drop squares is fully loaded
    (`isFullyStreamed`) and has stayed so for one check and a margin (PEN_SETTLE_MS),
    and gives up after PEN_WAIT_MS. Vanilla's one-animal drop has the same flaw, and
    animals that stay loaded in the near half of a huge pen while its far corner comes
    and goes get the replay too; only smaller joined zones avoid that.

    Both directions run a few animals per tick (BATCH), so a big flock does not make
    one long server tick or one burst of packets.

    Only loose animals: hutched ones are not in the zone's list and are left alone,
    as are animals tied to a tree, led on a rope, on a hook or dead. The pen is the
    clicked animal's zone and every zone connected to it (getAnimalsConnected, a new
    list, so removing from the zone while walking it is safe).

    Gate: Capability.AnimalCheats, as vanilla's own animal admin commands
    (ClientCommands.lua Commands.animal.*); single player trusts the client, which
    offers it only with -debug.
--]]

if isClient() then return end

local MODULE = ZomboidFixesB42.MODULE
-- Animals picked up or put down per server tick.
local BATCH = 20
-- How long the pens under a drop must have been fully loaded before animals go down:
-- one DesignationZone.update (2.5 s, where a pen coming back replays its hours) and a
-- margin. And how long a drop waits for that before giving up.
local PEN_SETTLE_MS = 3500
local PEN_WAIT_MS = 15000

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.AnimalCarryAll == true
end

local function isAllowed(player)
    if not player or player:isDead() then return false end
    if not isServer() then return true end
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.AnimalCheats)
end

local function reply(player, args)
    if isServer() then
        sendServerCommand(player, MODULE, ZomboidFixesB42.CMD_ANIMAL_CARRY_ALL_RESULT, args)
    else
        triggerEvent("OnServerCommand", MODULE, ZomboidFixesB42.CMD_ANIMAL_CARRY_ALL_RESULT, args)
    end
end

local function breedOf(animal)
    local breed = animal:getBreed()
    return breed and breed:getName() or ""
end

local function isKind(animal, animalType, breed)
    return animal:getAnimalType() == animalType and breedOf(animal) == breed
end

--- A loose animal a pick-up may take now.
local function isLoose(animal)
    if not animal or animal:isDead() or not animal:isExistInTheWorld() then return false end
    if animal:isOnHook() or animal:getHutch() ~= nil or animal:getVehicle() ~= nil then return false end
    local data = animal:getData()
    if data and (data:getAttachedPlayer() ~= nil or data:getAttachedTree() ~= nil) then return false end
    return true
end

-- Work waiting, one entry per request: { player, kind = "pickup" | "drop", list =
-- Lua array, index, done, name }.
local queue = {}

local function pickUp(player, animal)
    local inventory = player:getInventory()
    local item = instanceItem("Base.Animal")
    if not item then return false end
    item:setAnimal(animal)
    inventory:AddItem(item)
    animal:setWild(false)
    animal:removeFromWorld()
    animal:removeFromSquare()
    animal:setSquare(nil)
    if isServer() then sendAddItemToContainer(inventory, item) end
    return true
end

--- The squares round the player an animal may be put down on: the player's own
-- and the 8 round it on the same level, with a floor, no water, not walled off.
local function dropSquares(player)
    local here = player:getCurrentSquare()
    if not here then return {} end
    local cell = getCell()
    local squares = {}
    for dy = -1, 1 do
        for dx = -1, 1 do
            local sq = cell:getGridSquare(here:getX() + dx, here:getY() + dy, here:getZ())
            local floor = sq and sq:getFloor()
            if floor and not floor:hasProperty(IsoFlagType.water)
                    and (sq == here or not here:isBlockedTo(sq)) then
                squares[#squares + 1] = sq
            end
        end
    end
    return squares
end

--- The animal zones under the drop squares, each once.
local function dropZones(squares)
    local zones, seen = {}, {}
    for _, sq in ipairs(squares) do
        local zone = DesignationZoneAnimal.getZone(sq:getX(), sq:getY(), sq:getZ())
        if zone and not seen[zone] then
            seen[zone] = true
            zones[#zones + 1] = zone
        end
    end
    return zones
end

local function zonesLoaded(zones)
    for _, zone in ipairs(zones) do
        if not zone:isFullyStreamed() then return false end
    end
    return true
end

--- Whether a drop job may put animals down now: false while its pens settle,
-- nil once it has waited too long.
local function penReady(job)
    if #job.zones == 0 then return true end
    local now = getTimestampMs()
    if not zonesLoaded(job.zones) then
        job.loadedSince = nil
        if now - job.started > PEN_WAIT_MS then return nil end
        return false
    end
    job.loadedSince = job.loadedSince or now
    return now - job.loadedSince >= PEN_SETTLE_MS
end

local function putDown(player, item, square)
    local inventory = player:getInventory()
    if not inventory:contains(item) then return false end
    inventory:Remove(item)
    if isServer() then sendRemoveItemFromContainer(inventory, item) end
    square:AddWorldInventoryItem(item, 0.5, 0.5, 0, true)
    return true
end

local function startPickup(player, args)
    local id = tonumber(args.id)
    local clicked = id and getAnimal(id)
    if not clicked or not isLoose(clicked) then
        reply(player, { kind = "pickup", count = "0", reason = "gone" })
        return
    end
    local zone = clicked:getDZone()
    if not zone then
        reply(player, { kind = "pickup", count = "0", reason = "nozone" })
        return
    end
    local animalType, breed = clicked:getAnimalType(), breedOf(clicked)
    local connected = zone:getAnimalsConnected()
    local list = {}
    for i = 0, connected:size() - 1 do
        local animal = connected:get(i)
        if isKind(animal, animalType, breed) and isLoose(animal) then
            list[#list + 1] = animal
        end
    end
    print(string.format("[ZomboidFixesB42] %s picks up %d %s %s at %d,%d,%d",
        player:getUsername(), #list, breed, animalType,
        math.floor(clicked:getX()), math.floor(clicked:getY()), math.floor(clicked:getZ())))
    queue[#queue + 1] = { player = player, kind = "pickup", list = list, index = 1, done = 0 }
end

local function startDrop(player, args)
    local animalType, breed = tostring(args.type or ""), tostring(args.breed or "")
    local items = player:getInventory():getItems()
    local list = {}
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local animal = instanceof(item, "AnimalInventoryItem") and item:getAnimal()
        if animal and isKind(animal, animalType, breed) then
            list[#list + 1] = item
        end
    end
    local squares = dropSquares(player)
    if #squares == 0 then
        reply(player, { kind = "drop", count = "0", reason = "nospace" })
        return
    end
    print(string.format("[ZomboidFixesB42] %s puts down %d %s %s at %d,%d,%d",
        player:getUsername(), #list, breed, animalType,
        math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())))
    queue[#queue + 1] = { player = player, kind = "drop", list = list, index = 1, done = 0, squares = squares,
        zones = dropZones(squares), started = getTimestampMs() }
end

local function onTick()
    local job = queue[1]
    if not job then return end
    local player = job.player
    -- The admin left or died: what is done stays done, the rest is not touched.
    if not player or player:isDead() or (isServer() and not player:isExistInTheWorld()) then
        table.remove(queue, 1)
        return
    end
    if job.kind == "drop" and job.index == 1 then
        local ready = penReady(job)
        if ready == nil then
            print(string.format("[ZomboidFixesB42] %s's drop of %d animals refused: the pen is not fully loaded",
                player:getUsername(), #job.list))
            table.remove(queue, 1)
            reply(player, { kind = "drop", count = "0", reason = "penNotLoaded" })
            return
        end
        if not ready then return end
    end
    local last = math.min(#job.list, job.index + BATCH - 1)
    for i = job.index, last do
        local entry = job.list[i]
        if job.kind == "pickup" then
            -- Checked again: the animal may have gone into a hutch or been led away
            -- since the request.
            if isLoose(entry) and pickUp(player, entry) then job.done = job.done + 1 end
        else
            local square = job.squares[(i - 1) % #job.squares + 1]
            if putDown(player, entry, square) then job.done = job.done + 1 end
        end
    end
    job.index = last + 1
    if job.index > #job.list then
        table.remove(queue, 1)
        reply(player, { kind = job.kind, count = tostring(job.done) })
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end
    if command ~= ZomboidFixesB42.CMD_ANIMAL_CARRY_ALL and command ~= ZomboidFixesB42.CMD_ANIMAL_DROP_ALL then return end
    if not isEnabled() or not isAllowed(player) or type(args) ~= "table" then return end
    if command == ZomboidFixesB42.CMD_ANIMAL_CARRY_ALL then
        startPickup(player, args)
    else
        startDrop(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(onTick)
