--[[
    Zomboid Fixes B42.20 -- server, broken clothing

    Applies a clothing break a client reports to the server's own copy of the item.
    See the client file for how the two copies drift apart.

    Trusting the client here is safe because it can only ever hurt the reporter:
    the item has to be in their own inventory, and the only outcome is that item
    losing its condition and, if worn, being dropped at their feet. Nothing is
    created, so nothing can be duplicated.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.SyncBrokenClothing == true
end

--- Copy the client's holes onto the item. Only ever adds holes, never removes
-- them, and removes the patch under each new one the way BloodClothingType.addHole
-- does.
local function applyHoles(item, encoded)
    if type(encoded) ~= "string" or not item:getCanHaveHoles() then return end

    local visual = item:getVisual()
    if not visual then return end

    local max = BloodBodyPartType.MAX:index()
    for field in string.gmatch(encoded, "%d+") do
        local index = tonumber(field)
        if index and index >= 0 and index < max then
            local part = BloodBodyPartType.FromIndex(index)
            if visual:getHole(part) <= 0 then
                visual:setHole(part)
                item:removePatch(part)
            end
        end
    end
end

local function onBrokenClothing(player, args)
    if not isEnabled() or not player or player:isDead() then return end

    local id = tonumber(args.id)
    if not id then return end

    -- Worn items live in the main inventory, never in a bag.
    local inventory = player:getInventory()
    local item = inventory:getItemWithID(id)
    if not item or not instanceof(item, "Clothing") or not item:isRemoveOnBroken() then return end

    applyHoles(item, args.holes)

    -- On the server this is the whole vanilla path: setBroken, and for a worn item
    -- Unwear(true), which takes it off, drops it (except from a vehicle seat) and
    -- replicates both, including to the reporting client, which has been keeping
    -- the broken item on while it waits. Skipped when the server already agrees,
    -- so a repeat report does not re-trigger anything.
    if item:getCondition() > 0 or item:isWorn() then
        item:setCondition(0)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_BROKEN_CLOTHING then return end
    onBrokenClothing(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
