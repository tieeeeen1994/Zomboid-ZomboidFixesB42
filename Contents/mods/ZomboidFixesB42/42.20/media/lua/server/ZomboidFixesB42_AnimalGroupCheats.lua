--[[
    Zomboid Fixes B42.20 -- server, animal cheats on a whole pen (admin)

    Runs an admin's group cheat on the server's animals and answers with how many it
    changed and their online IDs (the client outlines them for a moment). The
    cheats and how the animals are found are in
    shared/ZomboidFixesB42_AnimalGroupCheats.lua.

    One command per click, whatever the number of animals: the changes reach every
    client with the animals' regular AnimalPacket (see the shared file), so nothing
    is sent per animal. A cheat touches only fields of the animals it finds, so a
    pen of a few hundred is one short pass.

    Single player: sendClientCommand reaches this handler, and the answer goes back
    through triggerEvent (sendServerCommand does nothing outside a server).
--]]

if isClient() then return end

local Cheats = ZomboidFixesB42.AnimalGroupCheats
local MODULE = ZomboidFixesB42.MODULE

-- Online IDs sent back for the outline; more than that only costs packet size.
local MAX_IDS = 300

local function isAllowed(player)
    if not player or player:isDead() then return false end
    if not isServer() then return true end
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.AnimalCheats)
end

local function reply(player, args)
    if isServer() then
        sendServerCommand(player, MODULE, ZomboidFixesB42.CMD_ANIMAL_GROUP_CHEAT_RESULT, args)
    else
        triggerEvent("OnServerCommand", MODULE, ZomboidFixesB42.CMD_ANIMAL_GROUP_CHEAT_RESULT, args)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= ZomboidFixesB42.CMD_ANIMAL_GROUP_CHEAT then return end
    if type(args) ~= "table" then return end
    if not Cheats.isEnabled() then return reply(player, { reason = "off" }) end
    if not isAllowed(player) then
        print("[ZomboidFixesB42] Animal group cheat refused: " .. tostring(player and player:getUsername()) .. " lacks AnimalCheats")
        return
    end

    local result = Cheats.run(player, args)
    local answer = { cheat = result.cheat, reason = result.reason, count = result.count or 0 }
    if result.ids then
        answer.ids = {}
        for i = 1, math.min(#result.ids, MAX_IDS) do
            answer.ids[i] = result.ids[i]
        end
    end
    -- Single player hands the table over as it is, so the client can outline the
    -- animals themselves (online IDs are a server's).
    if not isServer() then answer.animals = result.animals end

    if result.count and result.count > 0 then
        print(string.format("[ZomboidFixesB42] %s: animal cheat %s = %s on %d animals (%s at %d,%d,%d%s)",
            tostring(player:getUsername()), result.cheat, tostring(result.value), result.count,
            tostring(args.scope), math.floor(tonumber(args.x) or 0), math.floor(tonumber(args.y) or 0),
            math.floor(tonumber(args.z) or 0),
            (args.kind and args.kind ~= Cheats.ANY_KIND) and (", " .. tostring(args.kind) .. " only") or ""))
    end
    reply(player, answer)
end

Events.OnClientCommand.Add(onClientCommand)
