--[[
    Zomboid Fixes B42.20 -- client, hovering a big pile on the floor no longer drops the frame rate

    Hovering (or selecting) a stack in the loot window highlights every item of it that lies on the floor:
    ISInventoryPane:updateWorldObjectHighlight clears the highlights and sets them again every frame, and
    findItemForWorldObjectHighlight walks the whole stack (item:getWorldItem(), setHighlighted) each time. The world
    renderer then draws highlighted objects on their own (42.22 FBORenderObjectHighlight.render): for each one,
    renderObject walks the square's objects from that object's index to the end, testing each with
    isRenderedEveryFrame and two set lookups and drawing the ones after it again, so they stay on top. For n highlighted
    items on one square that is about n^2 / 2 tests a frame: hovering a pile of a few thousand items held the game near
    20 fps (pzopt profile, 2026-11-28, FBORenderObjectHighlight.isRenderedEveryFrame the largest single cost).

    A stack bigger than PER_SQUARE now highlights, on each square, only its PER_SQUARE items with the highest object
    index. Those are drawn last, so they are the ones on top of the pile and the ones seen: the tint looks the same,
    and each of them walks only the few objects above it. The choice is worked out once per stack row (the loot window
    builds new rows when its list changes) instead of walking the stack every frame. Single items and small stacks go
    to vanilla's function unchanged.
--]]

local PER_SQUARE = 8
local CACHE_MAX = 64

local cache, cached = {}, 0

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.FloorHighlightLimit == true
end

--- The world items to highlight for a stack: per square, the PER_SQUARE highest object indexes.
local function pick(items)
    local bySquare, order, seen = {}, {}, {}
    for _, item in ipairs(items) do
        if not instanceof(item, "InventoryItem") then break end -- where vanilla's walk stops
        local worldItem = item:getWorldItem()
        if worldItem and not seen[worldItem] and worldItem:getChunk() ~= nil then
            seen[worldItem] = true
            local square = worldItem:getSquare()
            if square then
                local top = bySquare[square]
                if not top then
                    top = {}
                    bySquare[square] = top
                    order[#order + 1] = square
                end
                local index = worldItem:getObjectIndex()
                if #top < PER_SQUARE or index > top[#top].index then
                    -- keep top sorted, highest first
                    local at = #top + 1
                    while at > 1 and top[at - 1].index < index do at = at - 1 end
                    table.insert(top, at, { worldItem = worldItem, index = index })
                    if #top > PER_SQUARE then top[#top] = nil end
                end
            end
        end
    end
    local picked = {}
    for _, square in ipairs(order) do
        for _, entry in ipairs(bySquare[square]) do
            picked[#picked + 1] = entry.worldItem
        end
    end
    return picked
end

local vanillaFind = ISInventoryPane.findItemForWorldObjectHighlight

function ISInventoryPane:findItemForWorldObjectHighlight(test)
    if not (isEnabled() and type(test) == "table" and type(test.items) == "table" and #test.items > PER_SQUARE) then
        return vanillaFind(self, test)
    end
    local picked = cache[test]
    if not picked then
        if cached >= CACHE_MAX then cache, cached = {}, 0 end
        picked = pick(test.items)
        cache[test] = picked
        cached = cached + 1
    end
    for _, worldItem in ipairs(picked) do
        if worldItem:getChunk() ~= nil and worldItem:getItem() ~= nil then
            if not self.highlightItems[worldItem] then
                worldItem:setHighlighted(self.player, true, false)
            end
            self.highlightItems[worldItem] = worldItem
        end
    end
end
