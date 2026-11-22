--[[
    Zomboid Fixes B42.20 -- client, the debug Remove Item Tool on the server

    The server file (server/ZomboidFixesB42_RemoveItemTool.lua) explains the bugs:
    in multiplayer the tool's Corpses mode only removed bodies on the remover's own
    screen whenever the server refused its per-body packet (always for a player's
    corpse saved before the last restart, for moderators on any player's corpse),
    past ~300 bodies a second, and threw on an unloaded square; Items mode relied
    on index-addressed removals, which leave ghosts on a client whose square
    differs from the server's.

    Here, on a multiplayer client with the option on, the Remove button sends
    CMD_REMOVE_ITEM_TOOL with the area and the mode instead of vanilla's command or
    local corpse removal. It first notes every floor item (or corpse) this client
    shows in the area. When the server answers, it waits SETTLE_MS for the server's
    own removals to arrive, then removes locally whatever noted object is still
    there and is not in the server's kept list: ghost items the server never had,
    and copies an index-addressed removal missed. Objects that appear after the
    click are never touched. If the server refuses (no permission, area too big),
    nothing is removed anywhere. Single player keeps vanilla's tool.
--]]

if not isClient() then return end

require "DebugUIs/ISRemoveItemTool"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local SETTLE_MS = 1500
local TIMEOUT_MS = 30000
local MAX_NOTED = 5000

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.RemoveItemToolSync == true
end

local vanillaOnClick = ISRemoveItemTool.onClick

-- token -> { corpses, noted = { { square, object, id } }, sentMs, replyMs, kept }
local pending = {}
local pendingCount = 0
local nextToken = 0

local function note(x1, y1, x2, y2, z, corpses)
    local noted = {}
    for x = x1, x2 do
        for y = y1, y2 do
            local square = getSquare(x, y, z)
            if square then
                if corpses then
                    local bodies = square:getStaticMovingObjects()
                    for i = 0, bodies:size() - 1 do
                        local body = bodies:get(i)
                        if instanceof(body, "IsoDeadBody") then
                            noted[#noted + 1] = { square = square, object = body, id = body:getObjectIDAsLong() }
                        end
                    end
                else
                    local worldObjects = square:getWorldObjects()
                    for i = 0, worldObjects:size() - 1 do
                        local worldItem = worldObjects:get(i)
                        local item = worldItem:getItem()
                        noted[#noted + 1] = { square = square, object = worldItem, id = item and item:getID() }
                    end
                end
                if #noted >= MAX_NOTED then return noted end
            end
        end
    end
    return noted
end

--- Vanilla's single-item Delete removes a floor radio's IsoRadio with it.
local function removeRadioFor(square, item)
    if not instanceof(item, "Radio") then return end
    local objects = square:getObjects()
    for i = objects:size() - 1, 0, -1 do
        local object = objects:get(i)
        if instanceof(object, "IsoRadio") and object:getModData().RadioItemID == item:getID() then
            square:transmitRemoveItemFromSquare(object)
            return
        end
    end
end

local function removeLeftovers(entry)
    local keptSet = {}
    for _, id in ipairs(entry.kept or {}) do keptSet[id] = true end

    local removed = 0
    for _, n in ipairs(entry.noted) do
        local object, square = n.object, n.square
        if n.id == nil or not keptSet[n.id] then
            if entry.corpses then
                if object:getSquare() == square and square:getStaticMovingObjects():contains(object) then
                    -- remote = true: local only, no packet.
                    square:removeCorpse(object, true)
                    removed = removed + 1
                end
            elseif object:getSquare() == square and square:getWorldObjects():contains(object) then
                local item = object:getItem()
                if item then removeRadioFor(square, item) end
                -- On a client this is a local RemoveTileObject.
                square:transmitRemoveItemFromSquare(object)
                if item then item:setWorldItem(nil) end
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        triggerEvent("OnContainerUpdate")
    end
end

local onTick

local function forget(token)
    if pending[token] then
        pending[token] = nil
        pendingCount = pendingCount - 1
    end
    if pendingCount <= 0 then
        pendingCount = 0
        Events.OnTick.Remove(onTick)
    end
end

onTick = function()
    local now = getTimestampMs()
    local settled, expired = {}, {}
    for token, entry in pairs(pending) do
        if entry.replyMs then
            if now - entry.replyMs >= SETTLE_MS then settled[#settled + 1] = token end
        elseif now - entry.sentMs >= TIMEOUT_MS then
            expired[#expired + 1] = token
        end
    end
    for _, token in ipairs(expired) do forget(token) end
    for _, token in ipairs(settled) do
        local entry = pending[token]
        forget(token)
        removeLeftovers(entry)
    end
end

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_REMOVE_ITEM_TOOL_DONE then return end
    if type(args) ~= "table" then return end
    local token = tonumber(args.token)
    local entry = token and pending[token]
    if not entry then return end
    if args.refused == true then
        forget(token)
        return
    end
    local kept = entry.corpses and args.keptBodies or args.keptItems
    entry.kept = {}
    if type(kept) == "table" then
        for _, id in pairs(kept) do entry.kept[#entry.kept + 1] = tonumber(id) end
    end
    entry.replyMs = getTimestampMs()
end

local function clearHighlight(tool)
    if tool.OnRenderTick ~= nil then
        Events.OnRenderTick.Remove(tool.OnRenderTick)
        tool.OnRenderTick = nil
        tool.highlightSquares = {}
    end
end

function ISRemoveItemTool:onClick(button)
    if button.internal ~= "REMOVE" or not isClient() or not isEnabled()
            or self.startPos == nil or self.endPos == nil then
        return vanillaOnClick(self, button)
    end
    local corpses = self.itemType:isSelected(2)
    if not corpses and not self.itemType:isSelected(1) then
        return vanillaOnClick(self, button)
    end

    local x1, x2 = math.min(self.startPos.x, self.endPos.x), math.max(self.startPos.x, self.endPos.x)
    local y1, y2 = math.min(self.startPos.y, self.endPos.y), math.max(self.startPos.y, self.endPos.y)
    local z = math.floor(self.zPos)

    nextToken = nextToken + 1
    local token = nextToken
    pending[token] = {
        corpses = corpses,
        noted = note(x1, y1, x2, y2, z, corpses),
        sentMs = getTimestampMs(),
    }
    pendingCount = pendingCount + 1
    Events.OnTick.Remove(onTick)
    Events.OnTick.Add(onTick)

    sendClientCommand(self.player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_REMOVE_ITEM_TOOL,
        { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z, corpses = corpses, token = token })
    clearHighlight(self)
end

Events.OnServerCommand.Add(onServerCommand)
