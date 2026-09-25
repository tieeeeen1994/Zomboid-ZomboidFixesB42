--[[
    Zomboid Fixes B42.20 -- client, animal cheats

    The gender toggle in the animal info window is purely local in vanilla, and
    only skin deep even then:

        function ISAnimalUI:onChangeGender()
            self.animal:setFemale(not self.animal:isFemale());
        end

    Two separate things are wrong with that.

    It does not travel. Compare the rename button a few lines below it, which does
    branch on isClient() and send an "animal"/"rename" command. There is no gender
    command anywhere in the vanilla vocabulary, and gender is not carried by
    AnimalPacket either -- it only travels in IsoAnimal.save/load. So in multiplayer
    the change lands on the admin's own copy of the animal and nowhere else, and is
    lost again as soon as anything resyncs that animal: putting it down, walking far
    enough away for the chunk to reload, or relogging.

    And it does not change the animal. The model, the mate lookup and everything
    else that makes a boar a boar hang off the animal's *type*, not off the gender
    flag, so a flipped sow stays a sow in every way that shows. That half is
    explained and handled in shared/ZomboidFixesB42_AnimalGender.lua; swapping the
    type replaces the IsoAnimal, which is why the window has to be reopened on the
    animal that replaced it.

    Single player has no sync problem, because there the client's animal is the
    authoritative one and IsoAnimal.save persists it, but it has the same type
    problem -- so it goes through the same swap, just without the round trip.

    The window can be opened on an animal that is loose in the world, in a hutch,
    in a trailer, or carried inside an AnimalInventoryItem. The first three are all
    registered with the animal instance manager and so can be addressed by their
    online ID (this is how vanilla's own animal commands address hutch animals). A
    carried animal is not registered, so it is addressed by the item holding it.
--]]

require "ISUI/Animal/ISAnimalUI"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.AnimalGenderChange == true
end

local vanillaOnChangeGender = ISAnimalUI.onChangeGender

--- Find the inventory item carrying this animal, if any.
local function findCarriedAnimalItem(container, animal, depth)
    depth = depth or 0
    if not container or depth > 10 then return nil end

    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if instanceof(item, "AnimalInventoryItem") and item:getAnimal() == animal then
            return item
        end
        if instanceof(item, "InventoryContainer") then
            local found = findCarriedAnimalItem(item:getInventory(), animal, depth + 1)
            if found then return found end
        end
    end
    return nil
end

-- The window that asked for the last change, so it can be reopened on whatever
-- animal comes back. Only the admin who pressed the button has one; anyone else
-- looking at the same animal keeps a window on an object the server has replaced,
-- exactly as vanilla leaves them when an animal grows up under their nose.
local pending = nil

--- Put the window back on the animal that replaced the one it was showing.
-- ISAnimalUI caches the avatar definition and the name off the animal it was built
-- with, so there is nothing to refresh in place -- it has to be built again.
-- A nil animal just closes it.
local function reopenWindow(window, animal)
    -- Already closed, by the admin or by anything else, while the reply was in
    -- flight. Putting a window back that they have just dismissed would be worse
    -- than leaving it shut.
    if not window or not window:getIsVisible() then return end

    local x, y = window:getX(), window:getY()
    local width, height = window:getWidth(), window:getHeight()
    local player = window.chr
    local playerNum = window.playerNum
    local prevFocus = window.prevFocus

    window:close()

    if not animal or not player then return end

    local ui = ISAnimalUI:new(x, y, width, height, animal, player)
    ui:initialise()
    ui:addToUIManager()
    ui.prevFocus = prevFocus
    if getJoypadData(playerNum) then
        -- close() handed focus back and may have shown the trailer window again.
        if prevFocus ~= nil and prevFocus.Type == "ISVehicleAnimalUI" then
            prevFocus:setVisible(false)
        end
        setJoypadFocus(playerNum, ui)
    end
end

function ISAnimalUI:onChangeGender()
    if not isEnabled() then return vanillaOnChangeGender(self) end

    local animal = self.animal
    if not animal then return end

    local player = self.chr or getPlayer()
    if not player then return end

    local female = not animal:isFemale()

    -- Single player: this client owns the animal, so do the whole thing here.
    if not isClient() then
        local item = findCarriedAnimalItem(player:getInventory(), animal)
        reopenWindow(self, ZomboidFixesB42.setAnimalGender(animal, female, item))
        return
    end

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
        local item = findCarriedAnimalItem(player:getInventory(), animal)
        id = item and item:getID()
    end

    -- Could not address it at all. Better to behave exactly as vanilla does than
    -- to do nothing.
    if not id then
        animal:setFemale(female)
        return
    end

    -- Deliberately not applied locally first. The server is the authority, and it
    -- echoes the change back to this client, so the window updates once the change
    -- is real rather than showing a value that might not survive.
    pending = { window = self, animal = animal }

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

    local female = args.female == "true"
    local newType = args.type

    if args.target == "online" then
        -- No type change: the animal object is still the one this client knows, so
        -- the flag can just be set on it.
        if not newType then
            local animal = getAnimal(id)
            if not animal then return end
            animal:setFemale(female)
            if pending and pending.animal == animal then
                reopenWindow(pending.window, animal)
                pending = nil
            end
            return
        end

        -- The type did change, so the server deleted this animal and registered a
        -- replacement under a new online ID. Nothing to apply here: the world sync
        -- brings the new one in by itself. All that is left is the window, which is
        -- still pointing at the animal that has just gone away, and which cannot be
        -- reopened because the replacement has not necessarily arrived yet.
        if pending and pending.animal and pending.animal:getOnlineID() == id then
            reopenWindow(pending.window, nil)
            pending = nil
        end
        return
    end

    if args.target ~= "carried" then return end

    -- Only ever sent to the player carrying the item, so the search starts and ends
    -- in their own inventory.
    local player = getPlayer()
    local item = player and ZomboidFixesB42.findItemById(player:getInventory(), id)
    if not item or not instanceof(item, "AnimalInventoryItem") then return end

    local animal = item:getAnimal()
    if not animal then return end

    local replacement
    if newType then
        -- This client holds its own copy of the animal, deserialised from the item,
        -- so it performs the same swap the server just did. The texture comes over
        -- the wire because the female side of a breed is a list vanilla picks from
        -- at random, and the two ends have to agree.
        replacement = ZomboidFixesB42.setAnimalGender(animal, female, item, args.texture)
    else
        animal:setFemale(female)
        replacement = animal
    end

    if pending and pending.animal == animal then
        reopenWindow(pending.window, replacement)
        pending = nil
    end
end

Events.OnServerCommand.Add(onServerCommand)
