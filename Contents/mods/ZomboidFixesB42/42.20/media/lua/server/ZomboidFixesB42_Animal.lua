--[[
    Zomboid Fixes B42.20 -- server, animal cheats

    Applies an animal gender change to the authoritative animal and tells the
    clients that need to know.

    Vanilla's animal commands live in a local Commands table inside
    ClientCommands.lua, so they cannot be extended from a mod -- hence a separate
    handler here. The capability check matches the one vanilla puts on every
    Commands.animal.* handler.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

--- Resolve the animal the client is talking about.
-- Animals loose in the world, in a hutch or in a trailer are all registered with
-- the instance manager and addressed by online ID. A carried animal is not
-- registered, so it is addressed by the ID of the item holding it -- and that item
-- is looked up from the player's own inventory, so nobody can reach an animal they
-- are not carrying.
local function resolveAnimal(player, target, id)
    if target == "online" then
        return getAnimal(id)
    end

    if target == "carried" then
        local item = ZomboidFixesB42.findItemById(player:getInventory(), id)
        if item and instanceof(item, "AnimalInventoryItem") then
            return item:getAnimal()
        end
    end

    return nil
end

local function onSetAnimalGender(player, args)
    if not player then return end

    local role = player:getRole()
    if not role or not role:hasCapability(Capability.AnimalCheats) then
        print("ZomboidFixesB42.setAnimalGender The player's access level is not sufficient to perform this action")
        return
    end

    local id = tonumber(args.id)
    local target = args.target
    if not id or (target ~= "online" and target ~= "carried") then return end

    local animal = resolveAnimal(player, target, id)
    if not animal then return end

    local female = args.female == "true"
    -- Writes through to the animal's SurvivorDesc, which is what IsoAnimal.save
    -- serialises, so this survives a restart and a pick-up/put-down round trip.
    animal:setFemale(female)

    -- Gender is not part of AnimalPacket, so clients will not pick this up on
    -- their own. A registered animal is visible to everyone, so tell everyone; a
    -- carried one only exists in the owner's inventory, and broadcasting its item
    -- ID would risk other clients matching it against an unrelated animal.
    local sync = {
        target = target,
        id = tostring(id),
        female = female and "true" or "false",
    }
    if target == "online" then
        sendServerCommand(ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_ANIMAL_GENDER_SYNC, sync)
    else
        sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_ANIMAL_GENDER_SYNC, sync)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_ANIMAL_GENDER then return end
    onSetAnimalGender(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
