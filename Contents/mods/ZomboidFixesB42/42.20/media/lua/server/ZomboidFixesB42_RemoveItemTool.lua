--[[
    Zomboid Fixes B42.20 -- server, the debug Remove Item Tool on the server

    The Remove Item Tool (debug menu, and Tools > Remove item tool for admins and
    moderators; DebugUIs/ISRemoveItemTool.lua) picks an area and removes its floor
    items or its corpses. In multiplayer (42.22.2, traced 2026-11-22):

    - Items: the client sends object.removeWorldItemsInArea, and vanilla's server
      handler (ClientCommands.lua ~166, UseDebugContextMenu) removes every world item
      in the area with transmitRemoveItemFromSquare. That part works, but each client
      is told by RemoveItemFromSquare, addressed by object INDEX on the square, so a
      client whose object list differs from the server's (ghost floor items, a
      wrong-index pickup earlier) keeps items or loses the wrong object.
    - Corpses: there is no server side at all. The client calls
      square:removeCorpse(body, false) on its own copy (~97), which removes the body
      locally and sends one RemoveCorpseFromMap packet per body. The server's
      RemoveCorpseFromMapPacket.hasRemovePermission allows a zombie corpse for
      ManipulateZombie, an animal for AnimalCheats and a player's corpse for
      ConnectWithDebug, where "player's corpse" is IsoDeadBody.isPlayer() = the
      private `player` field, set only in the constructor at the moment of death
      and never saved. So the corpse of a player who died before the last restart
      or chunk reload is none of the three and is refused for everyone, moderators
      are refused player corpses, and a body whose object ID the server cannot
      resolve is refused too. A refusal is only a server log warning: the body is
      already gone from the remover's screen and comes back on relog. Past about
      300 bodies a second the client drops the rest of the packets
      (MaxPacketsPerSecond), and an unloaded square in the area (getSquare nil)
      throws halfway through the loop.

    Fixed here with CMD_REMOVE_ITEM_TOOL { x1, y1, x2, y2, z, corpses, token }
    (client/ZomboidFixesB42_RemoveItemTool.lua sends it instead):
    - Items as vanilla (UseDebugContextMenu, transmitRemoveItemFromSquare, plus
      DesignationZoneAnimal.removeItemFromGround like vanilla's single-item Delete).
    - Corpses on the server with square:removeCorpse(body, false), which relays
      RemoveCorpseFromMap by the body's object ID and frees the ID (vanilla's
      ISBuryCorpse does the same). Same permissions as vanilla's packet, except that
      every corpse that is neither a zombie nor an animal counts as a player's
      corpse (ConnectWithDebug), saved or not.
    - The reply CMD_REMOVE_ITEM_TOOL_DONE { token, keptItems, keptBodies } lists
      what is still there (refused corpses, a world item the square would not give
      up), so the remover's client can drop its leftover copies of everything else.
    Areas wider or deeper than MAX_SIDE tiles are refused. Every removal is logged.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local MAX_SIDE = 300
local MAX_KEPT = 2000

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.RemoveItemToolSync == true
end

local function hasCapability(role, capability)
    return role ~= nil and role:hasCapability(capability)
end

--- What vanilla's RemoveCorpseFromMap packet asks for, with a saved player's
--- corpse (neither zombie nor animal) treated as a player's corpse.
local function corpseCapability(body)
    if body:isZombie() then return Capability.ManipulateZombie end
    if body:isAnimal() then return Capability.AnimalCheats end
    return Capability.ConnectWithDebug
end

local function addKept(list, id)
    if id ~= nil and #list < MAX_KEPT then list[#list + 1] = id end
end

local function removeItemsOn(square, result)
    local worldObjects = square:getWorldObjects()
    for i = worldObjects:size() - 1, 0, -1 do
        local worldItem = worldObjects:get(i)
        local item = worldItem:getItem()
        pcall(DesignationZoneAnimal.removeItemFromGround, worldItem)
        if square:transmitRemoveItemFromSquare(worldItem) >= 0 then
            result.removed = result.removed + 1
            if item then result.types[item:getFullType()] = true end
        else
            addKept(result.keptItems, item and item:getID())
        end
    end
end

local function removeCorpsesOn(square, role, result)
    local bodies = square:getStaticMovingObjects()
    for i = bodies:size() - 1, 0, -1 do
        local body = bodies:get(i)
        if instanceof(body, "IsoDeadBody") then
            if hasCapability(role, corpseCapability(body)) then
                square:removeCorpse(body, false)
                result.removed = result.removed + 1
            else
                result.refused = result.refused + 1
                addKept(result.keptBodies, body:getObjectIDAsLong())
            end
        end
    end
end

local function reply(player, args)
    sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_REMOVE_ITEM_TOOL_DONE, args)
end

local function onRemoveArea(player, args)
    local token = tonumber(args.token)
    local name = tostring(player:getUsername())
    local role = player:getRole()
    if not hasCapability(role, Capability.UseDebugContextMenu) then
        print("[ZomboidFixesB42] removeItemTool refused for " .. name .. ": needs the Use Debug Context Menu permission")
        reply(player, { token = token, refused = true })
        return
    end

    local x1, y1, x2, y2, z = tonumber(args.x1), tonumber(args.y1), tonumber(args.x2), tonumber(args.y2), tonumber(args.z)
    if not x1 or not y1 or not x2 or not y2 or not z then return end
    x1, x2 = math.floor(math.min(x1, x2)), math.floor(math.max(x1, x2))
    y1, y2 = math.floor(math.min(y1, y2)), math.floor(math.max(y1, y2))
    z = math.floor(z)
    if x2 - x1 >= MAX_SIDE or y2 - y1 >= MAX_SIDE then
        print("[ZomboidFixesB42] removeItemTool refused for " .. name .. ": area larger than "
            .. string.format("%d", MAX_SIDE) .. " tiles a side")
        reply(player, { token = token, refused = true })
        return
    end

    local corpses = args.corpses == true
    local result = { removed = 0, refused = 0, types = {}, keptItems = {}, keptBodies = {} }
    local cell = getCell()
    for x = x1, x2 do
        for y = y1, y2 do
            local square = cell:getGridSquare(x, y, z)
            if square then
                if corpses then
                    removeCorpsesOn(square, role, result)
                else
                    removeItemsOn(square, result)
                end
            end
        end
    end

    reply(player, { token = token, keptItems = result.keptItems, keptBodies = result.keptBodies })

    if result.removed == 0 and result.refused == 0 then return end
    local area = string.format("%d,%d to %d,%d z %d", x1, y1, x2, y2, z)
    if corpses then
        print("[ZomboidFixesB42] " .. name .. " removed " .. string.format("%d", result.removed)
            .. " corpse(s) at " .. area .. " with the Remove Item Tool"
            .. (result.refused > 0 and (" (" .. string.format("%d", result.refused) .. " refused: no permission for that kind of corpse)") or ""))
    else
        local names = {}
        for fullType in pairs(result.types) do names[#names + 1] = fullType end
        print("[ZomboidFixesB42] " .. name .. " removed " .. string.format("%d", result.removed)
            .. " floor item(s) at " .. area .. " with the Remove Item Tool: " .. table.concat(names, ", "))
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_REMOVE_ITEM_TOOL then return end
    if not player or type(args) ~= "table" or not isEnabled() then return end
    onRemoveArea(player, args)
end

Events.OnClientCommand.Add(onClientCommand)
