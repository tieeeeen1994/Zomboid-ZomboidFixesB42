--[[
    Zomboid Fixes B42.20 -- client, carry every animal of a kind (admin)

    Adds "Pick up all <breed> <type> in this pen" to the submenu vanilla gives a
    right-clicked animal (AnimalContextMenu.doMenu), and "Put down all <breed> <type>
    here" to a carried animal's inventory menu (AnimalContextMenu.doInventoryMenu,
    whose own Drop puts down one animal per click). The server does the work: see
    server/ZomboidFixesB42_AnimalCarryAll.lua for how animals become items and back.

    doMenu builds the animal's submenu itself and returns nothing; its first option
    is the animal's name, whose subOption is that submenu, so the option count is
    noted before the call and the submenu found from the option added at that index
    (getOptionFromName would find the first of several animals sharing a name).

    Put down all is refused here while the pen under the player is not fully loaded
    on this client (both corners), and the server waits for its own copy of the pen:
    a pen that comes back replays all its missed hours on every animal in it, and
    animals just put down in a huge pen died of that (see the server file).

    The count shown is this client's view of the pen (the zones' animal lists are
    rebuilt on clients too, DesignationZone.update every 2.5 s); the server collects
    its own list and checks each animal again as it takes it.

    Gate: Capability.AnimalCheats in multiplayer (the server checks it again), -debug
    in single player, where a character's role has no capabilities.
--]]

require "ISUI/Animal/ISAnimalContextMenu"

local MODULE = ZomboidFixesB42.MODULE

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.AnimalCarryAll == true
end

local function canUse(playerObj)
    if not playerObj or playerObj:isDead() then return false end
    if not isClient() then return isDebugEnabled() end
    local role = playerObj:getRole()
    return role ~= nil and role:hasCapability(Capability.AnimalCheats)
end

local function breedOf(animal)
    local breed = animal:getBreed()
    return breed and breed:getName() or ""
end

local function isKind(animal, animalType, breed)
    return animal:getAnimalType() == animalType and breedOf(animal) == breed
end

--- The kind's name the way vanilla names a carried animal (AnimalInventoryItem).
local function kindName(animal)
    return getText("IGUI_Breed_" .. breedOf(animal)) .. " " .. getText("IGUI_AnimalType_" .. animal:getAnimalType())
end

local function isLoose(animal)
    if not animal or animal:isDead() or not animal:isExistInTheWorld() then return false end
    if animal:isOnHook() or animal:getHutch() ~= nil or animal:getVehicle() ~= nil then return false end
    local data = animal:getData()
    if data and (data:getAttachedPlayer() ~= nil or data:getAttachedTree() ~= nil) then return false end
    return true
end

--- The loose animals of the clicked one's kind in its pen, as this client sees it.
local function penMatches(animal)
    local zone = animal:getDZone()
    if not zone then return nil end
    local animalType, breed = animal:getAnimalType(), breedOf(animal)
    local connected = zone:getAnimalsConnected()
    local list = {}
    for i = 0, connected:size() - 1 do
        local other = connected:get(i)
        if isKind(other, animalType, breed) and isLoose(other) then
            list[#list + 1] = other
        end
    end
    return list
end

local function carriedMatches(playerObj, animalType, breed)
    local items = playerObj:getInventory():getItems()
    local count = 0
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local animal = instanceof(item, "AnimalInventoryItem") and item:getAnimal()
        if animal and isKind(animal, animalType, breed) then count = count + 1 end
    end
    return count
end

--- The weight they will have as items (AnimalInventoryItem.setAnimal:
-- adef.baseEncumbrance * getAnimalSize()).
local function totalWeight(list)
    local total = 0
    for _, animal in ipairs(list) do
        local def = AnimalDefinitions and AnimalDefinitions.animals and AnimalDefinitions.animals[animal:getAnimalType()]
        total = total + (def and def.baseEncumbrance or 0) * animal:getAnimalSize()
    end
    return total
end

local function onCarryAll(animal, playerObj)
    local list = penMatches(animal) or {}
    local text = getText("IGUI_ZomboidFixesB42_AnimalCarryAll_confirm", string.format("%d", #list), kindName(animal),
        string.format("%d", math.floor(totalWeight(list) + 0.5)))
    local id = animal:getOnlineID()
    local core = getCore()
    local width, height = 460, 150
    local modal = ISModalDialog:new(core:getScreenWidth() / 2 - width / 2, core:getScreenHeight() / 2 - height / 2,
        width, height, text, true, nil, function(_, button)
            if button.internal ~= "YES" then return end
            sendClientCommand(playerObj, MODULE, ZomboidFixesB42.CMD_ANIMAL_CARRY_ALL, { id = tostring(id) })
        end)
    modal:initialise()
    modal:addToUIManager()
end

--- The animal zone under the player when this client has not loaded both its corners.
local function unloadedPenHere(playerObj)
    local sq = playerObj:getCurrentSquare()
    local zone = sq and DesignationZoneAnimal.getZone(sq:getX(), sq:getY(), sq:getZ())
    if zone and not zone:isFullyStreamed() then return zone end
    return nil
end

local function penNotLoadedText(zone)
    return getText("IGUI_ZomboidFixesB42_AnimalCarryAll_penNotLoaded",
        string.format("%d,%d", zone:getX(), zone:getY()),
        string.format("%d,%d", zone:getX() + zone:getW() - 1, zone:getY() + zone:getH() - 1))
end

local function showMessage(text)
    local core = getCore()
    local width, height = 420, 130
    local modal = ISModalDialog:new(core:getScreenWidth() / 2 - width / 2, core:getScreenHeight() / 2 - height / 2,
        width, height, text, false, nil, nil)
    modal:initialise()
    modal:addToUIManager()
end

local function onDropAll(playerObj, animalType, breed)
    local zone = unloadedPenHere(playerObj)
    if zone then
        showMessage(penNotLoadedText(zone))
        return
    end
    sendClientCommand(playerObj, MODULE, ZomboidFixesB42.CMD_ANIMAL_DROP_ALL, { type = animalType, breed = breed })
end

local vanillaDoMenu = AnimalContextMenu.doMenu
AnimalContextMenu.doMenu = function(player, context, animal, test, ...)
    local before = context and context.numOptions
    local result = vanillaDoMenu(player, context, animal, test, ...)
    if test or not before or not isEnabled() then return result end
    local playerObj = getSpecificPlayer(player)
    if not canUse(playerObj) or not isLoose(animal) then return result end
    local animalOption = context.options[before]
    local subMenu = animalOption and animalOption.subOption and context:getSubMenu(animalOption.subOption)
    if not subMenu then return result end

    local list = penMatches(animal)
    local option = subMenu:addOption(getText("IGUI_ZomboidFixesB42_AnimalCarryAll", kindName(animal),
        string.format("%d", list and #list or 0)), animal, onCarryAll, playerObj)
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    if list then
        tooltip.description = getText("IGUI_ZomboidFixesB42_AnimalCarryAll_tooltip")
    else
        option.notAvailable = true
        tooltip.description = getText("IGUI_ZomboidFixesB42_AnimalCarryAll_noZone")
    end
    option.toolTip = tooltip
    return result
end

local vanillaDoInventoryMenu = AnimalContextMenu.doInventoryMenu
AnimalContextMenu.doInventoryMenu = function(player, context, animalInv, test, ...)
    local result = vanillaDoInventoryMenu(player, context, animalInv, test, ...)
    if test or not isEnabled() then return result end
    local playerObj = getSpecificPlayer(player)
    local animal = animalInv and animalInv:getAnimal()
    if not animal or not canUse(playerObj) then return result end
    if not playerObj:getInventory():contains(animalInv) then return result end
    local animalType, breed = animal:getAnimalType(), breedOf(animal)
    local count = carriedMatches(playerObj, animalType, breed)
    if count < 2 then return result end
    local option = context:addOption(getText("IGUI_ZomboidFixesB42_AnimalDropAll", kindName(animal),
        string.format("%d", count)), playerObj, onDropAll, animalType, breed)
    option.iconTexture = getTexture("media/ui/AnimalActions_Grab.png")
    return result
end

local REASONS = {
    gone = "IGUI_ZomboidFixesB42_AnimalCarryAll_gone",
    nozone = "IGUI_ZomboidFixesB42_AnimalCarryAll_noZone",
    nospace = "IGUI_ZomboidFixesB42_AnimalCarryAll_noSpace",
}

local function onServerCommand(module, command, args)
    if module ~= MODULE or command ~= ZomboidFixesB42.CMD_ANIMAL_CARRY_ALL_RESULT then return end
    if type(args) ~= "table" or tonumber(args.count) ~= 0 then return end
    if args.reason == "penNotLoaded" then
        local playerObj = getSpecificPlayer(0)
        local sq = playerObj and playerObj:getCurrentSquare()
        local zone = sq and DesignationZoneAnimal.getZone(sq:getX(), sq:getY(), sq:getZ())
        showMessage(zone and penNotLoadedText(zone) or getText("IGUI_ZomboidFixesB42_AnimalCarryAll_penNotLoadedServer"))
        return
    end
    showMessage(getText(REASONS[args.reason] or "IGUI_ZomboidFixesB42_AnimalCarryAll_none"))
end

Events.OnServerCommand.Add(onServerCommand)
