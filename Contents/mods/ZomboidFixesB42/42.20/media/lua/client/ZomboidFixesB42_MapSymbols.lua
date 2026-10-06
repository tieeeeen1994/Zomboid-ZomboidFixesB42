--[[
    Zomboid Fixes B42.20 -- client, symbols drawn on a paper map are kept in multiplayer

    A map item (MapItem) keeps its own symbols, saved with the item
    (MapItem.save / load write WorldMapSymbols after the map ID). The map window
    (client/ISUI/Maps/ISMap.lua) edits the client's copy of the item through
    mapAPI:getSymbolsAPIv2(), and nothing ever sends that to the server:
    SyncItemFieldsPacket has no symbols, and WorldMapClient only shares the symbols
    of the player's own world map (MapItem.getSingleton()). The server keeps and
    saves its copy blank, so the symbols vanish on relog, when the chunk holding the
    map reloads, and for anyone the map is given to (forum 96433).

    The server cannot rebuild symbols from Lua (MapItem.getSymbols is hidden from
    Lua and the symbols API belongs to a map UI), but item modData is carried by
    syncItemFields and saved with the item. So when the map window closes, the
    user-drawn symbols (not the map's default annotations) are written into the
    map's modData as plain values and synced; when a map whose own symbols are
    empty is opened -- every copy that came from the server -- they are drawn back
    from it, for its owner and anyone they give the map to. The editor's own copy
    keeps its symbols for the session, so nothing is drawn twice.

    Skipped for illiterate characters, whose symbol texts read back as "???".
    Single player saves the item itself and is left alone.
--]]

if not isClient() then return end

require "ISUI/Maps/ISMap"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local KEY = "zfixMapSymbols"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MapSymbolsSave == true
end

local function symbolsAPIOf(mapUI)
    local mapAPI = mapUI and mapUI.mapAPI
    return mapAPI and mapAPI:getSymbolsAPIv2()
end

--- The user-drawn symbols as plain tables, in order.
local function collect(api)
    local list = {}
    for i = 0, api:getSymbolCount() - 1 do
        local s = api:getSymbolByIndex(i)
        if s and s:isUserDefined() then
            local e = {
                x = s:getWorldX(), y = s:getWorldY(),
                r = s:getRed(), g = s:getGreen(), b = s:getBlue(), a = s:getAlpha(),
                ax = s:getAnchorX(), ay = s:getAnchorY(),
                scale = s:getScale(), rot = s:getRotation(),
                persp = s:isMatchPerspective(), zoom = s:isApplyZoom(),
                minZoom = s:getMinZoom(), maxZoom = s:getMaxZoom(),
            }
            if s:isTexture() then
                e.kind = "symbol"
                e.id = s:getSymbolID()
            elseif s:isText() then
                local key = s:getUntranslatedText()
                if key then
                    e.kind = "key"
                    e.text = key
                else
                    e.kind = "text"
                    e.text = s:getTranslatedText()
                end
                e.layer = s:getLayerID()
            end
            if e.kind and (e.id or e.text) then
                table.insert(list, e)
            end
        end
    end
    return list
end

local function signature(list)
    local parts = {}
    for i, e in ipairs(list) do
        parts[i] = table.concat({ tostring(e.kind), tostring(e.id or e.text), tostring(e.x), tostring(e.y),
            tostring(e.r), tostring(e.g), tostring(e.b), tostring(e.a), tostring(e.scale), tostring(e.rot) }, "|")
    end
    return table.concat(parts, "\n")
end

local function userSymbolCount(api)
    local count = 0
    for i = 0, api:getSymbolCount() - 1 do
        local s = api:getSymbolByIndex(i)
        if s and s:isUserDefined() then count = count + 1 end
    end
    return count
end

local function restore(api, list)
    for _, e in ipairs(list) do
        local s
        if e.kind == "symbol" and e.id then
            s = api:addTexture(e.id, e.x, e.y)
        elseif e.kind == "key" and e.text then
            s = api:addUntranslatedText(e.text, e.layer or api:getDefaultTextLayerID(), e.x, e.y)
        elseif e.kind == "text" and e.text then
            s = api:addTranslatedText(e.text, e.layer or api:getDefaultTextLayerID(), e.x, e.y)
        end
        if s then
            -- So the next close saves them again (default annotations are not).
            s:setUserDefined(true)
            s:setRGBA(e.r or 1, e.g or 1, e.b or 1, e.a or 1)
            s:setAnchor(e.ax or 0.5, e.ay or 0.5)
            if e.scale then s:setScale(e.scale) end
            if e.rot then s:setRotation(e.rot) end
            if e.persp ~= nil then s:setMatchPerspective(e.persp) end
            if e.zoom ~= nil then s:setApplyZoom(e.zoom) end
            if e.minZoom then s:setMinZoom(e.minZoom) end
            if e.maxZoom then s:setMaxZoom(e.maxZoom) end
        end
    end
end

local vanillaInstantiate = ISMap.instantiate

function ISMap:instantiate(...)
    local result = vanillaInstantiate(self, ...)
    if isEnabled() and self.mapObj then
        local saved = self.mapObj:getModData()[KEY]
        local api = symbolsAPIOf(self)
        if type(saved) == "table" and api and userSymbolCount(api) == 0 then
            local ok, err = pcall(restore, api, saved)
            if not ok then print("[ZomboidFixesB42] map symbols: could not restore: " .. tostring(err)) end
        end
    end
    return result
end

local function save(mapUI)
    local map, character = mapUI and mapUI.mapObj, mapUI and mapUI.character
    if not map or not character or character:hasTrait(CharacterTrait.ILLITERATE) then return end
    local api = symbolsAPIOf(mapUI)
    if not api then return end
    local list = collect(api)
    local modData = map:getModData()
    local old = modData[KEY]
    local oldSig = type(old) == "table" and signature(old) or ""
    if signature(list) == oldSig then return end
    if #list == 0 then
        modData[KEY] = nil
    else
        modData[KEY] = list
    end
    syncItemFields(character, map)
end

local vanillaWrapperClose = ISMapWrapper.close

function ISMapWrapper:close(...)
    if isEnabled() and not self.zfixSaved then
        self.zfixSaved = true
        local ok, err = pcall(save, self.mapUI)
        if not ok then print("[ZomboidFixesB42] map symbols: could not save: " .. tostring(err)) end
    end
    return vanillaWrapperClose(self, ...)
end
