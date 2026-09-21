--[[
    Zomboid Fixes B42.20 -- shared, animal gender

    Vanilla's gender toggle only flips a flag on the SurvivorDesc:

        function ISAnimalUI:onChangeGender()
            self.animal:setFemale(not self.animal:isFemale());
        end

    Nothing visible follows from that, because an animal's model is chosen from its
    *type* and not from the flag. AnimalVisual.getModel comes down to

        AnimalDefinitions.getDef(animal:getAnimalType()).bodyModel

    which is FarmPig_SowBody for a sow and FarmPig_BoarBody for a boar; isFemale()
    never enters into it. The only visual the flag does reach is the skin texture,
    and only once, inside the private IsoAnimal.initTexture at spawn.

    The flag on its own also leaves the animal in a state vanilla never produces.
    Mating is checked as `male:getMate() == female:getAnimalType()`, and mate="sow"
    is written on the *boar* definition, so a sow that has merely been flagged male
    has no mate field at all and can never be picked as one.

    So the gender change has to change the type with it, and Java offers no setter:
    IsoAnimal.type is written in the constructors and nowhere else. The one retype
    vanilla performs is AnimalData.grow, which builds a fresh IsoAnimal and swaps it
    in. This file does the same thing sideways rather than forwards, and avoids the
    two places where grow itself would not serve:

      * grow advances the grow stage, which is wrong for a sideways move
      * grow's container branch takes the old animal's item away and then never
        puts the new animal anywhere, so a carried animal would simply vanish

    Everything here runs wherever the animal is authoritative -- the server in
    multiplayer, the client in single player, and both ends for an animal carried in
    an inventory item, where each side holds its own copy of it.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

--- The animal type whose model carries the requested gender.
-- Returns nil when there is nothing to swap to, which is the signal to change the
-- flag alone.
local function typeForGender(animalType, female)
    local defs = AnimalDefinitions and AnimalDefinitions.animals
    local def = defs and defs[animalType]
    if not def then return nil end

    -- Babies carry neither flag, and their model is deliberately not gendered -- a
    -- piglet looks like a piglet either way. Leaving them alone also keeps them off
    -- the fallback below, which would otherwise age one straight into an adult.
    if not (def.female or def.male) then return nil end

    -- The pair is written on the baby's grow stage:
    --   AnimalDefinitions.stages["pig"].stages["piglet"].nextStage     = "sow"
    --   AnimalDefinitions.stages["pig"].stages["piglet"].nextStageMale = "boar"
    local group = def.group
    local stages = group and AnimalDefinitions.stages and AnimalDefinitions.stages[group]
    stages = stages and stages.stages
    if stages then
        for _, stage in pairs(stages) do
            if stage.nextStage == animalType or stage.nextStageMale == animalType then
                local wanted = female and stage.nextStage or stage.nextStageMale
                if wanted and defs[wanted] then return wanted end
                break
            end
        end
    end

    -- No grow stage names this type. Fall back to the gender flags on the rest of
    -- the group, which is what the model and the mate lookup key off anyway.
    if group then
        for name, other in pairs(defs) do
            if other.group == group and ((female and other.female) or ((not female) and other.male)) then
                return name
            end
        end
    end

    return nil
end

ZomboidFixesB42.genderedAnimalType = typeForGender

--- The skin texture IsoAnimal.initTexture would have picked for this gender.
-- That method is private, so it is reproduced here. The female side is a comma
-- separated list vanilla picks from at random; the male side is a single name.
-- Returns nil when the breed cannot be read, which leaves the new animal with
-- whatever its own constructor chose.
function ZomboidFixesB42.genderSkinTexture(animalType, breedName, female)
    local defs = AnimalDefinitions and AnimalDefinitions.animals
    local def = defs and defs[animalType]
    local breed = def and def.breeds and def.breeds[breedName]
    if not breed then return nil end

    if not female then
        local male = breed.textureMale
        if male == nil or male == "" then return nil end
        return male
    end

    local options = {}
    for texture in string.gmatch(tostring(breed.texture or ""), "([^,]+)") do
        table.insert(options, texture)
    end
    if #options == 0 then return nil end
    return options[ZombRand(#options) + 1]
end

--- Build the animal that stands in for this one. Not placed anywhere -- that is the
-- caller's job, because where it goes depends on where the old one was.
local function buildReplacement(animal, newType, female, texture, x, y, z)
    local def = AnimalDefinitions.getDef(newType)
    if not def then return nil end

    local oldBreed = animal:getBreed()
    local breed = oldBreed and def:getBreedByName(oldBreed:getName())
    if not breed then return nil end

    local replacement = addAnimal(getCell(), x, y, z, newType, breed)

    -- The constructor quietly refuses to build on a water square, or where another
    -- animal already holds this one's ID, and hands back a shell with no type set.
    if not replacement or not replacement:getAnimalType() then return nil end

    -- Hands over the AnimalData object itself, so age, size, weight, milk, wool,
    -- eggs and pregnancy come across along with the name, health, hunger, thirst,
    -- stress, genome and genetic disorders. Nothing is re-rolled.
    replacement:copyFrom(animal)

    -- copyFrom brought the old gender with it.
    replacement:setFemale(female)

    -- Not in copyFrom, and the model picker reads the skinned, headless and fleece
    -- flags straight out of the mod data.
    replacement:setModData(animal:getModData())
    replacement:setShouldBeSkeleton(animal:shouldBeSkeleton())
    replacement:setIsInvincible(animal:isInvincible())

    if texture then
        replacement:getAnimalVisual():setSkinTextureName(texture)
    end

    return replacement
end

--- Change an animal's gender, and its type along with it.
-- @param animal the animal to change
-- @param female the gender wanted
-- @param item the AnimalInventoryItem holding it, when it is being carried
-- @param texture the skin texture to use. Passed across the wire so both ends of a
--                multiplayer swap land on the same one; nil picks one here.
-- @return the animal that now stands in for it. A different object when the type
--         changed, the same one when only the flag did.
function ZomboidFixesB42.setAnimalGender(animal, female, item, texture)
    if not animal then return nil end

    local oldType = animal:getAnimalType()
    local newType = typeForGender(oldType, female)

    -- Nothing to rebuild: a baby, a species with one type for both sexes, or an
    -- animal whose flag had drifted from its type and is now being put back. The
    -- texture is left alone here on purpose -- a baby's comes from textureBaby,
    -- which has no gendered counterpart to swap in.
    if not newType or newType == oldType then
        animal:setFemale(female)
        return animal
    end

    local hutch = animal:getHutch()
    local vehicle = animal:getVehicle()
    local square = animal:getSquare()
    local held = item or hutch or vehicle

    -- Nothing is holding it and it is not standing anywhere either, so there is
    -- nowhere to put the replacement. Leave the animal alone bar the flag.
    if not held and not square then
        animal:setFemale(female)
        return animal
    end

    -- Built where it will stand, so its square is valid for addToWorld. One that is
    -- held rather than standing is built off the map instead, in the same corner
    -- ISHutchUI builds its cheat animals in.
    local x, y, z = 0, 0, 0
    if not held then
        x, y, z = animal:getX(), animal:getY(), animal:getZ()
    end

    local breed = animal:getBreed()
    texture = texture or ZomboidFixesB42.genderSkinTexture(newType, breed and breed:getName(), female)

    local replacement = buildReplacement(animal, newType, female, texture, x, y, z)

    -- Could not build one. An animal whose flag does not match its model is a lot
    -- better than one taken apart halfway.
    if not replacement then
        animal:setFemale(female)
        return animal
    end

    if item then
        -- The item is the animal's only home, so there is nothing to unregister and
        -- nothing to delete: the old object simply stops being referenced.
        item:setAnimal(replacement)
    elseif hutch then
        local nestBox = animal:getNestBoxIndex()
        if nestBox >= 0 then
            hutch:tryFindAndRemoveAnimalFromNestBox(animal)
            -- Back on the roost if every nest box has filled up in the meantime.
            -- Losing the nest box costs her the clutch she was sitting on; being
            -- left in neither place would lose the bird.
            if not hutch:addAnimalInNestBox(replacement) then
                hutch:addAnimalInside(replacement)
            end
        else
            -- removeAnimal clears the hutch position but leaves the preferred one,
            -- which is what addAnimalInside reads, so she lands back in her own slot.
            hutch:removeAnimal(animal)
            hutch:addAnimalInside(replacement)
        end
        animal:delete()
        hutch:sync()
    elseif vehicle then
        -- No removeFromWorld on the replacement, the way addAnimalInTrailer does it
        -- for an animal it is taking off the ground: this one was built off the map
        -- and never added, and removeFromWorld would put it on the cell's remove
        -- list on its way past. Riding along at the vehicle's position is the rest
        -- of what addAnimalInTrailer does.
        vehicle:replaceGrownAnimalInTrailer(animal, replacement)
        replacement:setVehicle(vehicle)
        replacement:setX(vehicle:getX())
        replacement:setY(vehicle:getY())
        animal:delete()
        -- Reaches into GameServer.udpEngine, so it is server only.
        if isServer() then
            replacement:sendExtraUpdateToClients()
        end
    else
        -- The rope is held in two places: AnimalData.attachedPlayer, which came
        -- across with the data, and a list on the player, which removeFromWorld
        -- strips the old animal out of on its way through delete(). Only the second
        -- one needs putting back, and it is set directly rather than through
        -- setAttachedPlayer, which would send an attach packet and shove a rope into
        -- the player's hands for a leash that never actually came off.
        local attached = animal:getData() and animal:getData():getAttachedPlayer()

        -- delete() unregisters the old animal and tells the clients to drop it; the
        -- new one registered itself as it was built and streams out from addToWorld.
        animal:delete()
        replacement:addToWorld()

        if attached then
            attached:addAttachedAnimal(replacement)
        end
    end

    return replacement
end
