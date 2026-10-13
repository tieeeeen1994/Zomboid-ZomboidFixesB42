--[[
    Zomboid Fixes B42.20 -- shared, animal pen resync

    What client and server both need: the block size, the message limits and the
    fingerprint that tells whether two copies of an item were eaten from
    differently. The bug and the protocol are described in
    client/ZomboidFixesB42_AnimalZoneResync.lua and the server's half in
    server/ZomboidFixesB42_AnimalZoneResync.lua.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local AnimalZoneResync = {}
ZomboidFixesB42.AnimalZoneResync = AnimalZoneResync

-- A pen is checked in square blocks of at most BLOCK x BLOCK tiles, one message each.
AnimalZoneResync.BLOCK = 10
-- More world items than this in one block and it is not checked (a message must
-- stay well under the 64 KB a string can take on the wire).
AnimalZoneResync.MAX_ENTRIES = 600

function AnimalZoneResync.isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.AnimalZoneResync == true
end

--- What an animal eating from the item changes: Food's hunger and thirst
-- (AnimalData.eatItem lowers them for a part eaten), a drainable feed bag's uses.
function AnimalZoneResync.fingerprint(item)
    if instanceof(item, "Food") then
        return string.format("f%.3f/%.3f", item:getHungChange(), item:getThirstChange())
    end
    if instanceof(item, "DrainableComboItem") then
        return string.format("d%d", item:getCurrentUses())
    end
    return ""
end

function AnimalZoneResync.key(x, y)
    return string.format("%d,%d", x, y)
end
