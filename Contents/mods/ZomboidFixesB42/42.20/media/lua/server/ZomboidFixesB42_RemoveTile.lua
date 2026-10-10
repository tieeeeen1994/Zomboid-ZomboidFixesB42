--[[
    Zomboid Fixes B42.20 -- server, the admin hotbar's "Remove a tile"

    Removes the object, overlay sprite or attached sprite the hotbar's remover
    picked (what and how: shared/ZomboidFixesB42_RemoveTile.lua). Who may: on a
    server, a role with Capability.UseBrushToolManager, the Brush Tool's own (its
    "Destroy tile" needs UseDebugContextMenu instead); single player reaches this
    through sendClientCommand with a role that has no capabilities, so there the
    hotbar's own gate (-debug) is the check. The square must be within MAX_DISTANCE
    tiles of the server's copy of the player. Every removal on a server goes to the
    admin log. Behind the hotbar's option, AdminHotbar.
--]]

if isClient() then return end

require "ZomboidFixesB42_RemoveTile"

local RemoveTile = ZomboidFixesB42.RemoveTile

-- The hotbar's picker reaches anything on screen; the server's copy of the player
-- trails the client's.
local MAX_DISTANCE = 60

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.AdminHotbar == true
end

local function isAllowed(player)
    if player:isDead() then return false end
    if not isServer() then return true end
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.UseBrushToolManager)
end

local function remove(args)
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    local square = x and y and z and getCell():getGridSquare(x, y, z)
    local object = RemoveTile.findObject(square, args.objectIndex, args.parent)
    if not object then return nil end
    if args.kind == "object" then
        square:transmitRemoveItemFromSquare(object)
        return square, args.parent
    end
    if args.kind == "overlay" then
        local overlay = object:getOverlaySprite()
        if not overlay or overlay:getName() ~= args.sprite then return nil end
        object:setOverlaySprite(nil, true)
        return square, args.sprite
    end
    if args.kind == "attached" then
        local index = RemoveTile.findAttached(object, args.attachedIndex, args.sprite)
        if not index then return nil end
        object:RemoveAttachedAnim(index)
        object:transmitUpdatedSpriteToClients()
        return square, args.sprite
    end
    return nil
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_REMOVE_TILE then return end
    if not player or type(args) ~= "table" or not isEnabled() then return end
    if not isAllowed(player) then
        print("ZomboidFixesB42.removeTile The player's access level is not sufficient to perform this action")
        return
    end
    local x, y = tonumber(args.x), tonumber(args.y)
    if not x or not y or math.abs(x - player:getX()) > MAX_DISTANCE or math.abs(y - player:getY()) > MAX_DISTANCE then
        return
    end
    local square, removed = remove(args)
    if square and isServer() then
        writeLog("admin", string.format("%s removed %s %s at %d,%d,%d", tostring(player:getUsername()),
            tostring(args.kind), tostring(removed), square:getX(), square:getY(), square:getZ()))
    end
end

Events.OnClientCommand.Add(onClientCommand)
