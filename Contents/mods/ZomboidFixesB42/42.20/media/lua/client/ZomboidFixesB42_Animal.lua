--[[
    Zomboid Fixes B42.20 -- client, animal cheats

    The gender toggle in the animal info window is purely local in vanilla:

        function ISAnimalUI:onChangeGender()
            self.animal:setFemale(not self.animal:isFemale());
        end

    Compare the rename button a few lines below it, which does branch on isClient()
    and send an "animal"/"rename" command. There is no gender command anywhere in
    the vanilla vocabulary, and gender is not carried by AnimalPacket either -- it
    only travels in IsoAnimal.save/load. So in multiplayer the change lands on the
    admin's own copy of the animal and nowhere else, and is lost again as soon as
    anything resyncs that animal: putting it down, walking far enough away for the
    chunk to reload, or relogging.

    Single player has no such problem, because there the client's animal is the
    authoritative one and IsoAnimal.save persists it.

    The window can be opened on an animal that is loose in the world, in a hutch,
    in a trailer, or carried inside an AnimalInventoryItem. The first three are all
    registered with the animal instance manager and so can be addressed by their
    online ID (this is how vanilla's own animal commands address hutch animals). A
    carried animal is not registered, so it is addressed by the item holding it.
--]]

require "ISUI/Animal/ISAnimalUI"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local vanillaOnChangeGender = ISAnimalUI.onChangeGender

--- Find the ID of the inventory item carrying this animal, if any.
local function findCarriedAnimalItemId(player, animal, container, depth)
    container = container or (player and player:getInventory())
    depth = depth or 0
    if not container or depth > 10 then return nil end

    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if instanceof(item, "AnimalInventoryItem") and item:getAnimal() == animal then
            return item:getID()
        end
        if instanceof(item, "InventoryContainer") then
            local found = findCarriedAnimalItemId(player, animal, item:getInventory(), depth + 1)
            if found then return found end
        end
    end
    return nil
end

function ISAnimalUI:onChangeGender()
    -- Single player: vanilla is already correct.
    if not isClient() then
        return vanillaOnChangeGender(self)
    end

    local animal = self.animal
    if not animal then return end

    local player = self.chr or getPlayer()
    if not player then return end

    local female = not animal:isFemale()
    local target, id

    -- Prefer the online ID, and confirm it really resolves back to this animal
    -- rather than trusting isExistInTheWorld() -- a hutched or trailered animal
    -- reports false there but is still registered and addressable.
    local onlineId = animal:getOnlineID()
    if onlineId and onlineId ~= 0 and getAnimal(onlineId) == animal then
        target = "online"
        id = onlineId
    else
        target = "carried"
        id = findCarriedAnimalItemId(player, animal)
    end

    -- Could not address it at all. Better to behave exactly as vanilla does than
    -- to do nothing.
    if not id then
        return vanillaOnChangeGender(self)
    end

    -- Deliberately not applied locally first. The server is the authority, and it
    -- echoes the change back to this client, so the window updates once the change
    -- is real rather than showing a value that might not survive.
    sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_ANIMAL_GENDER, {
        target = target,
        id = tostring(id),
        female = female and "true" or "false",
    })
end

--- Apply a gender change the server has confirmed.
local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_ANIMAL_GENDER_SYNC then return end
    if type(args) ~= "table" then return end

    local id = tonumber(args.id)
    if not id then return end

    local animal
    if args.target == "online" then
        animal = getAnimal(id)
    elseif args.target == "carried" then
        -- Only ever sent to the player carrying the item.
        local player = getPlayer()
        local item = player and ZomboidFixesB42.findItemById(player:getInventory(), id)
        if item and instanceof(item, "AnimalInventoryItem") then
            animal = item:getAnimal()
        end
    end

    if not animal then return end
    animal:setFemale(args.female == "true")
end

Events.OnServerCommand.Add(onServerCommand)
