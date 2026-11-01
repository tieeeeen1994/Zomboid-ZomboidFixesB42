--[[
    Zomboid Fixes B42.20 -- client, animal cheats on a whole pen (admin)

    The admin hotbar's group animal cheats (registered in
    ZomboidFixesB42_AdminHotbarActions.lua, run by the server in
    server/ZomboidFixesB42_AnimalGroupCheats.lua, explained in the shared file) send
    one command per click; this sends it and takes the answer.

    The answer lists the animals that changed, and they get an outline for a moment
    (IsoGameCharacter.setOutlineHighlight / setOutlineHighlightCol, per player), so
    the admin sees which ones the scope and type caught. Hutched animals are out of
    the world and are not drawn. The new values themselves show up on their own with
    the animals' next AnimalPacket (within about a second). Nothing matched, a pen or
    hutch missing, or a square the server has not loaded is said over the admin's
    head, as the hotbar says its other refusals.
--]]

require "ZomboidFixesB42_AdminHotbar"

local Cheats = ZomboidFixesB42.AnimalGroupCheats
local Hotbar = ZomboidFixesB42.AdminHotbar
local MODULE = ZomboidFixesB42.MODULE

-- How long the changed animals stay outlined, and in what colour.
local OUTLINE_MS = 2500
local OUTLINE = { r = 0.35, g = 0.95, b = 0.45 }

--- Send a group cheat. args: { cheat, value, x, y, z, scope, kind } (see Cheats.run).
function Cheats.send(admin, args)
    sendClientCommand(admin, MODULE, ZomboidFixesB42.CMD_ANIMAL_GROUP_CHEAT, args)
end

-- Outlined animals: { playerNum, animals, untilMs }, or nil.
local outlined = nil

local function setOutline(animal, playerNum, on)
    pcall(function()
        animal:setOutlineHighlight(playerNum, on)
        if on then animal:setOutlineHighlightCol(playerNum, OUTLINE.r, OUTLINE.g, OUTLINE.b, 1) end
    end)
end

local function clearOutline()
    if not outlined then return end
    for _, animal in ipairs(outlined.animals) do setOutline(animal, outlined.playerNum, false) end
    outlined = nil
end

local function onTick()
    if not outlined then return end
    if getTimestampMs() >= outlined.untilMs then return clearOutline() end
    -- Again each frame: anything else outlining an animal (the animal's own hover
    -- outline) would otherwise end it early.
    for _, animal in ipairs(outlined.animals) do setOutline(animal, outlined.playerNum, true) end
end

local function outline(player, args)
    clearOutline()
    local animals = {}
    if type(args.animals) == "table" then
        for _, animal in ipairs(args.animals) do
            if animal:isExistInTheWorld() then table.insert(animals, animal) end
        end
    elseif type(args.ids) == "table" then
        for _, id in ipairs(args.ids) do
            local animal = getAnimal(id)
            if animal and animal:isExistInTheWorld() then table.insert(animals, animal) end
        end
    end
    if #animals == 0 then return end
    outlined = { playerNum = player:getPlayerNum(), animals = animals, untilMs = getTimestampMs() + OUTLINE_MS }
    onTick()
end

local REASONS = {
    off = "AnimalCheatsOff",
    notLoaded = "LocationNotLoaded",
    noPen = "NoAnimalPenThere",
    noHutch = "NoHutchThere",
    noneMatched = "NoAnimalsMatched",
    badArgs = "AnimalCheatsBadArgs",
}

local function onServerCommand(module, command, args)
    if module ~= MODULE or command ~= ZomboidFixesB42.CMD_ANIMAL_GROUP_CHEAT_RESULT then return end
    if type(args) ~= "table" then return end
    local player = getPlayer()
    if not player then return end
    if args.reason then
        local key = REASONS[args.reason]
        if key then Hotbar.say(player, Hotbar.txt(key), true) end
        return
    end
    outline(player, args)
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onTick)
