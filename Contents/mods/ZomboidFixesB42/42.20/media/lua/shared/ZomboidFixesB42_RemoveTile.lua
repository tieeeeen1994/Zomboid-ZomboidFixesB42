--[[
    Zomboid Fixes B42.20 -- shared, the admin hotbar's "Remove a tile"

    What a square holds that the remover can take, in the order the cursor cycles
    through it with the Rotate key: the square's objects from the top of the list
    (drawn last, so usually the one under the mouse) down to the floor, each one
    followed by its overlay sprite and its attached sprites (IsoObject
    getOverlaySprite / getAttachedAnimSprite: grime, signs, window frames, the
    "[OVERLAY]" and "[ATTACHED]" lines of vanilla's Brush Tool "Copy tile" menu).
    Items lying on the floor (IsoWorldInventoryObject) are left to the Remove Item
    Tool.

    How each goes (server, or single player):
      - an object: square:transmitRemoveItemFromSquare(object). On a server that is
        GameServer.RemoveItemFromMap for the object and, for a multi-tile object, for
        every part of it, each sent to the clients near it; in single player
        RemoveTileObject. Vanilla's Brush Tool "Destroy tile" instead sends
        sledgeDestroy from the client (SledgehammerDestroyPacket: needs
        UseDebugContextMenu, refused while the server option
        AllowDestructionBySledgehammer is off, and addresses the object only by its
        index on the square, which can differ between a client and the server);
      - an attached sprite: object:RemoveAttachedAnim(i), then
        transmitUpdatedSpriteToClients (UpdateItemSprite carries the whole attached
        list);
      - the overlay: object:setOverlaySprite(nil, true) (UpdateOverlaySprite).
    The client names its pick by square, object index, kind and sprite names; the
    server takes the object at that index only when its sprite matches, else the
    first one on the square with that sprite, so a list that differs between the
    two never removes the wrong thing.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local RemoveTile = {}
ZomboidFixesB42.RemoveTile = RemoveTile

local function spriteName(sprite)
    return sprite and sprite:getName() or nil
end

function RemoveTile.objectSprite(object)
    return spriteName(object:getSprite())
end

--- Every removable thing on the square, top first: { object, objectIndex, kind
-- ("object" / "overlay" / "attached"), attachedIndex, sprite (its name), parent
-- (the object's own sprite name) }.
function RemoveTile.entries(square)
    local list = {}
    if not square then return list end
    local objects = square:getObjects()
    for i = objects:size() - 1, 0, -1 do
        local object = objects:get(i)
        local parent = object and RemoveTile.objectSprite(object)
        if parent and not instanceof(object, "IsoWorldInventoryObject") then
            table.insert(list, { object = object, objectIndex = i, kind = "object", sprite = parent, parent = parent })
            local overlay = spriteName(object:getOverlaySprite())
            if overlay and overlay ~= "" then
                table.insert(list, { object = object, objectIndex = i, kind = "overlay", sprite = overlay, parent = parent })
            end
            local attached = object:getAttachedAnimSprite()
            if attached then
                for a = attached:size() - 1, 0, -1 do
                    local instance = attached:get(a)
                    local name = instance and spriteName(instance:getParentSprite())
                    if name then
                        table.insert(list, {
                            object = object, objectIndex = i, kind = "attached", attachedIndex = a,
                            sprite = name, parent = parent,
                        })
                    end
                end
            end
        end
    end
    return list
end

--- The object the client meant: the one at its index if the sprite matches, else
-- the first on the square with that sprite.
function RemoveTile.findObject(square, objectIndex, parent)
    if not square or type(parent) ~= "string" then return nil end
    local objects = square:getObjects()
    local index = tonumber(objectIndex) or -1
    if index >= 0 and index < objects:size() then
        local object = objects:get(index)
        if object and RemoveTile.objectSprite(object) == parent then return object end
    end
    for i = objects:size() - 1, 0, -1 do
        local object = objects:get(i)
        if object and not instanceof(object, "IsoWorldInventoryObject") and RemoveTile.objectSprite(object) == parent then
            return object
        end
    end
    return nil
end

--- Index of the attached sprite named `sprite` on `object`, preferring `hint`.
function RemoveTile.findAttached(object, hint, sprite)
    local attached = object and object:getAttachedAnimSprite()
    if not attached or type(sprite) ~= "string" then return nil end
    local index = tonumber(hint) or -1
    if index >= 0 and index < attached:size() then
        local instance = attached:get(index)
        if instance and spriteName(instance:getParentSprite()) == sprite then return index end
    end
    for a = attached:size() - 1, 0, -1 do
        local instance = attached:get(a)
        if instance and spriteName(instance:getParentSprite()) == sprite then return a end
    end
    return nil
end
