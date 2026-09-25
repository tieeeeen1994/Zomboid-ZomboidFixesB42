--[[
    Zomboid Fixes B42.20 -- client, admin hotbar

    Admin tools are spread over the admin panel, Admin Powers (tick boxes behind a
    Save button), the right-click Tools and Debug menus, the scoreboard's player
    menu, Climate Control and a long list of chat commands. This puts any of them on
    one floating bar of icon slots, shown and hidden from a button on the left
    sidebar, under the vanilla Admin button.

    A slot is an action plus its settings: a target player, a location, an item, a
    vehicle, a climate preset, counts and so on. The catalog of actions is in
    ZomboidFixesB42_AdminHotbarActions.lua; this file is the machinery.

      - A configured slot runs straight away. A toggle (god mode, rain, a climate
        preset, a boolean server option...) flips, and its colour always shows the
        state read back from the game, never a guess: green while on, amber while
        the server has not confirmed a click yet, amber "?" when this client cannot
        know (another player's flags it has never seen).
      - A slot whose action has a vanilla window can be set to open that window
        instead, which is what a fresh slot does until it is configured.
      - A setting left on "Ask when used" is asked for at click time: a menu of
        online players, a square picked on the map with vanilla's ISSelectCursor
        (the Horde Manager's picker), a searchable list, or a prompt.

    Everything goes through vanilla commands and packets (or this mod's own Body
    Stats and Chopper commands), which check the sender's capability on the server,
    so there is no new server code here. The bar only shows for roles with
    hasAdminTool(), the rule vanilla uses for the sidebar Admin button, and each
    action is greyed out when the role lacks what it needs.

    The sidebar button is added to ISEquippedItem, which stacks its buttons in
    initialise() and moves the war button under the Admin button every frame in
    prerender(), so the button goes in after initialise and is placed after
    prerender. It reuses the Admin button's own image, tinted, with the map symbol
    Lightning over it, so the mod ships no image files: every icon is a texture the
    game already has (see ZomboidFixesB42_AdminHotbarIcons.lua).

    Slots are saved per client and per server, in Zomboid/Lua, because usernames
    and coordinates mean nothing on another server. Keys are PZAPI.ModOptions key
    binds (Options > Mods), unbound by default.
--]]

if not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISComboBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISTickBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISModalDialog"
require "ISUI/ISTextBox"
require "ISUI/ISContextMenu"
require "ISUI/ISWorldObjectContextMenu"
require "ISUI/ISColorPicker"
require "ISUI/ISEquippedItem"
require "PZAPI/ModOptions"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local Hotbar = ZomboidFixesB42.AdminHotbar or {}
ZomboidFixesB42.AdminHotbar = Hotbar

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6

-- How long a toggle stays amber waiting for the server before it shows the real
-- state again, and how often slot states are read.
local PENDING_MS = 3000
local STATE_MS = 200
-- How often the online player list is asked for while the bar is visible, and the
-- climate admin values while a climate slot exists.
local SCOREBOARD_MS = 30000
local CLIMATE_MS = 10000

local SLOT_KEYS = 10
local SIZES = { 32, 40, 48 }

local AMBER = { r = 0.95, g = 0.62, b = 0.12 }

local function txt(key, ...)
    return getText("IGUI_ZomboidFixesB42_AdminHotbar_" .. key, ...)
end
Hotbar.txt = txt

-- Gates ------------------------------------------------------------------------

function Hotbar.isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.AdminHotbar == true
end

function Hotbar.hasCapability(player, name)
    local role = player and player:getRole()
    local capability = name and Capability[name]
    return role ~= nil and capability ~= nil and role:hasCapability(capability)
end

--- The bar is for roles that get the sidebar Admin button.
function Hotbar.canUse(player)
    if not Hotbar.isEnabled() or not player then return false end
    local role = player:getRole()
    return role ~= nil and role:hasAdminTool()
end

--- AdminContextMenu's own gate for the right-click Tools menu.
function Hotbar.canUseTools()
    return isAdmin() or getAccessLevel() == "moderator"
end

-- Commands and feedback ---------------------------------------------------------

function Hotbar.quote(text)
    return "\"" .. (string.gsub(tostring(text), "\"", "\\\"")) .. "\""
end

function Hotbar.command(text)
    SendCommandToServer(text)
end

function Hotbar.say(player, text, bad)
    if not player or not text then return end
    if bad then
        HaloTextHelper.addBadText(player, text)
    else
        HaloTextHelper.addText(player, text)
    end
end

function Hotbar.int(value)
    return string.format("%d", math.floor((tonumber(value) or 0) + 0.5))
end

-- Registry ---------------------------------------------------------------------

Hotbar.categories = Hotbar.categories or {}
Hotbar.actions = Hotbar.actions or {}
Hotbar.actionOrder = Hotbar.actionOrder or {}

function Hotbar.addCategory(id, title)
    for _, category in ipairs(Hotbar.categories) do
        if category.id == id then
            category.title = title
            return
        end
    end
    table.insert(Hotbar.categories, { id = id, title = title })
end

--- Register an action. Fields:
--   id, category, title (string or function(slot)), tooltip,
--   icon (icon ref, or function(settings) returning one),
--   params (list of { key, type, title, default, min, max, options, search,
--           optional, noAsk, hint }),
--   available(admin) -> ok, reason
--   run(ctx), openUI(ctx) (optional), confirm (default for "ask before running"),
--   toggle = { isOn(ctx) -> true/false/nil, set(ctx, on), applies(ctx) (optional) }
function Hotbar.registerAction(action)
    if not Hotbar.actions[action.id] then
        table.insert(Hotbar.actionOrder, action.id)
    end
    action.params = action.params or {}
    action.paramByKey = {}
    for _, spec in ipairs(action.params) do
        action.paramByKey[spec.key] = spec
    end
    Hotbar.actions[action.id] = action
    return action
end

function Hotbar.getAction(id)
    return id and Hotbar.actions[id] or nil
end

function Hotbar.titleOf(action, slot)
    if not action then return "?" end
    if type(action.title) == "function" then
        return action.title(slot)
    end
    return action.title or action.id
end

function Hotbar.slotTitle(slot)
    if slot.label and slot.label ~= "" then return slot.label end
    return Hotbar.titleOf(Hotbar.getAction(slot.action), slot)
end

function Hotbar.hasPlayerParam(action)
    for _, spec in ipairs(action.params) do
        if spec.type == "player" then return spec.key end
    end
    return nil
end

-- State ------------------------------------------------------------------------

local DEFAULT_SLOTS = {
    "power:GodMod", "power:Invisible", "power:NoClip", "power:FastMove", "power:TimedActionInstant",
    "teleport.ui", "window:ITEMLIST", "window:MINISCOREBOARD", "window:CHECKSTATS", "window:ADMINPANEL",
}

local function newSlot(actionId)
    local action = Hotbar.getAction(actionId)
    return {
        action = actionId,
        settings = {},
        window = action ~= nil and action.openUI ~= nil,
    }
end

local function defaultState()
    local state = {
        x = nil,
        y = nil,
        vertical = false,
        visible = true,
        size = 2,
        labels = false,
        on = { r = 0.2, g = 0.72, b = 0.28 },
        slots = {},
    }
    for _, id in ipairs(DEFAULT_SLOTS) do
        if Hotbar.getAction(id) then
            table.insert(state.slots, newSlot(id))
        end
    end
    return state
end

Hotbar.state = Hotbar.state or nil

-- Saving -----------------------------------------------------------------------
--
-- One line per record: a kind, then key=value pairs split by ";". Values carry a
-- type ("s:", "n:", "b:") and are percent-escaped; nested tables are flattened
-- into dotted keys, with "#" marking a number key.

local ESCAPES = { ["%"] = "%25", [";"] = "%3B", ["="] = "%3D", ["\n"] = "%0A", ["\r"] = "%0D" }
local UNESCAPES = { ["25"] = "%", ["3B"] = ";", ["3D"] = "=", ["0A"] = "\n", ["0D"] = "\r" }

local function escape(text)
    return (string.gsub(text, "[%%;=\r\n]", function(c) return ESCAPES[c] end))
end

local function unescape(text)
    return (string.gsub(text, "%%(%x%x)", function(hex) return UNESCAPES[string.upper(hex)] or "" end))
end

local function encodeValue(value)
    local kind = type(value)
    if kind == "number" then return "n:" .. tostring(value) end
    if kind == "boolean" then return value and "b:1" or "b:0" end
    if kind == "string" then return "s:" .. escape(value) end
    return nil
end

local function decodeValue(text)
    local kind, rest = string.sub(text, 1, 2), string.sub(text, 3)
    if kind == "n:" then return tonumber(rest) end
    if kind == "b:" then return rest == "1" end
    if kind == "s:" then return unescape(rest) end
    return nil
end

local function keyPart(key)
    if type(key) == "number" then return "#" .. tostring(key) end
    return (string.gsub(tostring(key), "[^%w_]", "_"))
end

local function flatten(value, prefix, out)
    for key, item in pairs(value) do
        local name = prefix .. keyPart(key)
        if type(item) == "table" then
            flatten(item, name .. ".", out)
        else
            local encoded = encodeValue(item)
            if encoded then table.insert(out, name .. "=" .. encoded) end
        end
    end
end

local function unflattenInto(target, dotted, value)
    local parts = {}
    for part in string.gmatch(dotted, "([^%.]+)") do
        if string.sub(part, 1, 1) == "#" then
            table.insert(parts, tonumber(string.sub(part, 2)) or part)
        else
            table.insert(parts, part)
        end
    end
    local node = target
    for i = 1, #parts - 1 do
        local part = parts[i]
        if type(node[part]) ~= "table" then node[part] = {} end
        node = node[part]
    end
    if #parts > 0 then node[parts[#parts]] = value end
end

local function fileName()
    local server = tostring(getServerIP() or "") .. "_" .. tostring(getServerPort() or "")
    return "ZomboidFixesB42_AdminHotbar_" .. string.gsub(server, "[^%w]", "_") .. ".ini"
end

function Hotbar.save()
    local state = Hotbar.state
    if not state then return end
    local writer = getFileWriter(fileName(), true, false)
    if not writer then return end

    local bar = {}
    flatten({
        x = state.x, y = state.y, vertical = state.vertical, visible = state.visible,
        size = state.size, labels = state.labels, on = state.on,
    }, "", bar)
    writer:write("bar;" .. table.concat(bar, ";") .. "\r\n")

    for _, slot in ipairs(state.slots) do
        local fields = {}
        flatten({
            action = slot.action, label = slot.label, icon = slot.icon, tint = slot.tint,
            confirm = slot.confirm, window = slot.window,
        }, "", fields)
        flatten(slot.settings or {}, "s.", fields)
        writer:write("slot;" .. table.concat(fields, ";") .. "\r\n")
    end
    writer:close()
end

function Hotbar.load()
    local reader = getFileReader(fileName(), false)
    if not reader then
        Hotbar.state = defaultState()
        return
    end

    local state = defaultState()
    state.slots = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        local record = {}
        local kind = nil
        for token in string.gmatch(line, "([^;]+)") do
            if not kind then
                kind = token
            else
                local eq = string.find(token, "=", 1, true)
                if eq then
                    local value = decodeValue(string.sub(token, eq + 1))
                    if value ~= nil then
                        unflattenInto(record, string.sub(token, 1, eq - 1), value)
                    end
                end
            end
        end
        if kind == "bar" then
            state.x = tonumber(record.x)
            state.y = tonumber(record.y)
            state.vertical = record.vertical == true
            state.visible = record.visible ~= false
            state.size = math.max(1, math.min(#SIZES, tonumber(record.size) or 2))
            state.labels = record.labels == true
            if type(record.on) == "table" and record.on.r then state.on = record.on end
        elseif kind == "slot" and Hotbar.getAction(record.action) then
            table.insert(state.slots, {
                action = record.action,
                label = record.label,
                icon = record.icon,
                tint = type(record.tint) == "table" and record.tint or nil,
                confirm = record.confirm,
                window = record.window == true,
                settings = type(record.s) == "table" and record.s or {},
            })
        end
    end
    reader:close()
    Hotbar.state = state
end

-- Online players ---------------------------------------------------------------
--
-- The scoreboard answer lists everyone online, unlike getOnlinePlayers(), which only
-- holds the players this client has loaded.

Hotbar.onlinePlayers = Hotbar.onlinePlayers or {}
local lastScoreboardRequest = 0

function Hotbar.requestPlayers()
    lastScoreboardRequest = getTimestampMs()
    scoreboardUpdate()
end

local function onScoreboardUpdate(usernames, displayNames)
    local list = {}
    for i = 0, usernames:size() - 1 do
        local username = usernames:get(i)
        local display = displayNames and displayNames:get(i) or username
        table.insert(list, { username = username, display = display })
    end
    Hotbar.onlinePlayers = list
end

Events.OnScoreboardUpdate.Add(onScoreboardUpdate)

--- Everyone the bar can offer: the last scoreboard answer, plus anyone loaded.
function Hotbar.playerChoices()
    local seen, list = {}, {}
    for _, entry in ipairs(Hotbar.onlinePlayers) do
        if not seen[entry.username] then
            seen[entry.username] = true
            table.insert(list, entry)
        end
    end
    local loaded = getOnlinePlayers()
    if loaded then
        for i = 0, loaded:size() - 1 do
            local player = loaded:get(i)
            local username = player and player:getUsername()
            if username and not seen[username] then
                seen[username] = true
                table.insert(list, { username = username, display = player:getDisplayName() or username })
            end
        end
    end
    table.sort(list, function(a, b) return string.lower(a.display) < string.lower(b.display) end)
    return list
end

-- Pickers ----------------------------------------------------------------------

--- A menu of online players at the mouse. onPick(username).
function Hotbar.pickPlayer(admin, onPick)
    local context = ISContextMenu.get(admin:getPlayerNum(), getMouseX(), getMouseY())
    context:addOption(txt("Myself", admin:getUsername()), admin:getUsername(), onPick)
    for _, entry in ipairs(Hotbar.playerChoices()) do
        if entry.username ~= admin:getUsername() then
            local name = entry.display
            if entry.display ~= entry.username then
                name = entry.display .. " (" .. entry.username .. ")"
            end
            context:addOption(name, entry.username, onPick)
        end
    end
    if getTimestampMs() - lastScoreboardRequest > 5000 then
        Hotbar.requestPlayers()
    end
end

--- Pick a square on the map, the way the Horde Manager does. onPick(square).
-- ISSelectCursor calls ui:onSquareSelected(square) and only counts as valid while
-- ui.cursor is set.
function Hotbar.pickSquare(admin, onPick)
    local picker = {}
    function picker.onSquareSelected(self, square)
        self.cursor = nil
        if square then onPick(square) end
    end
    picker.cursor = ISSelectCursor:new(admin, picker, nil)
    getCell():setDrag(picker.cursor, admin:getPlayerNum())
    Hotbar.say(admin, txt("PickSquareHint"))
end

function Hotbar.prompt(title, default, numbersOnly, onDone)
    local core = getCore()
    local modal = ISTextBox:new(core:getScreenWidth() / 2 - 140, core:getScreenHeight() / 2 - 90, 280, 180,
        title, default and tostring(default) or "", nil, function(_, button)
            if button.internal == "OK" then
                onDone(button.parent.entry:getText())
            end
        end)
    modal:initialise()
    modal:addToUIManager()
    if numbersOnly then modal:setOnlyNumbers(true) end
    return modal
end

function Hotbar.confirm(text, onYes)
    local core = getCore()
    local width, height = 380, 160
    local modal = ISModalDialog:new(core:getScreenWidth() / 2 - width / 2, core:getScreenHeight() / 2 - height / 2,
        width, height, text, true, nil, function(_, button)
            if button.internal == "YES" then onYes() end
        end)
    modal:initialise()
    modal:addToUIManager()
end

-- Searchable list ----------------------------------------------------------------

local ListPicker = ISPanel:derive("ZomboidFixesB42_AdminHotbarList")

function ListPicker:new(title, choices, onPick)
    local width, height = 460, 520
    local core = getCore()
    local o = ISPanel:new(core:getScreenWidth() / 2 - width / 2, core:getScreenHeight() / 2 - height / 2, width, height)
    setmetatable(o, self)
    self.__index = self
    o.title = title
    o.choices = choices
    o.onPick = onPick
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.9 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.moveWithMouse = true
    return o
end

function ListPicker:createChildren()
    ISPanel.createChildren(self)
    local x = UI_BORDER_SPACING + 1
    local y = UI_BORDER_SPACING * 2 + FONT_HGT_MEDIUM

    self.search = ISTextEntryBox:new("", x, y, self.width - x * 2, BUTTON_HGT)
    self.search:initialise()
    self.search:instantiate()
    self.search:setClearButton(true)
    self.search.target = self
    self.search.onTextChangeFunction = ListPicker.populate
    self:addChild(self.search)
    self.search:setPlaceholderText(txt("Search"))

    y = y + BUTTON_HGT + UI_BORDER_SPACING
    local listHeight = self.height - y - BUTTON_HGT - UI_BORDER_SPACING * 2
    self.list = ISScrollingListBox:new(x, y, self.width - x * 2, listHeight)
    self.list:initialise()
    self.list:instantiate()
    self.list.font = UIFont.Small
    self.list.itemheight = math.max(BUTTON_HGT, 26)
    self.list.drawBorder = true
    self.list.doDrawItem = ListPicker.drawRow
    self.list:setOnMouseDoubleClick(self, ListPicker.choose)
    self:addChild(self.list)

    local buttonWidth = 100
    local by = self.height - BUTTON_HGT - UI_BORDER_SPACING
    self.ok = ISButton:new(self.width / 2 - buttonWidth - 5, by, buttonWidth, BUTTON_HGT, getText("UI_Ok"), self, ListPicker.onOk)
    self.ok:initialise()
    self.ok:instantiate()
    self.ok:enableAcceptColor()
    self:addChild(self.ok)

    self.cancel = ISButton:new(self.width / 2 + 5, by, buttonWidth, BUTTON_HGT, getText("UI_Cancel"), self, ListPicker.close)
    self.cancel:initialise()
    self.cancel:instantiate()
    self.cancel:enableCancelColor()
    self:addChild(self.cancel)

    self:populate()
end

function ListPicker:populate()
    local filter = string.lower(self.search:getInternalText() or "")
    self.list:clear()
    for _, choice in ipairs(self.choices) do
        if filter == "" or string.find(string.lower(choice.text), filter, 1, true) then
            self.list:addItem(choice.text, choice)
        end
    end
end

function ListPicker:drawRow(y, item, alt)
    local height = self.itemheight
    -- Only rows that can be seen are drawn; the list can hold thousands of items.
    local top = -self:getYScroll()
    if y + height < top or y > top + self.height then
        return y + height
    end
    if self.selected == item.index then
        self:drawRect(0, y, self:getWidth(), height, 0.3, 0.7, 0.35, 0.15)
    end
    self:drawRectBorder(0, y, self:getWidth(), height, 0.25, 0.4, 0.4, 0.4)
    local choice = item.item
    local x = 6
    local iconSize = height - 4
    if choice.scriptItem then
        self:drawScriptItemIcon(choice.scriptItem, x, y + 2, 1, iconSize, iconSize)
        x = x + iconSize + 6
    elseif choice.texture then
        self:drawTextureScaledAspect(choice.texture, x, y + 2, iconSize, iconSize, 1, 1, 1, 1)
        x = x + iconSize + 6
    end
    self:drawText(item.text, x, y + (height - FONT_HGT_SMALL) / 2, 0.9, 0.9, 0.9, 1, UIFont.Small)
    return y + height
end

function ListPicker:choose(choice)
    if not choice then return end
    self:close()
    self.onPick(choice.data)
end

function ListPicker:onOk()
    local item = self.list.items[self.list.selected]
    if item then self:choose(item.item) end
end

function ListPicker:prerender()
    ISPanel.prerender(self)
    self:drawText(self.title, UI_BORDER_SPACING + 1, UI_BORDER_SPACING, 1, 1, 1, 1, UIFont.Medium)
end

function ListPicker:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

--- A searchable list. choices: { text, data, texture?, scriptItem? }. onPick(data).
function Hotbar.pickFromList(title, choices, onPick)
    local picker = ListPicker:new(title, choices, onPick)
    picker:initialise()
    picker:addToUIManager()
    picker:bringToTop()
    return picker
end

-- Resolving settings ---------------------------------------------------------------
--
-- player:   "@me", "@ask" or a username
-- location: "@me", "@pick", "@player" (the slot's player) or "x,y,z"
-- vehicle:  "@near" (the one I'm in, else the nearest) or "@pick"

local function settingOf(slot, spec)
    local value = slot.settings and slot.settings[spec.key]
    if value == nil then value = spec.default end
    return value
end

function Hotbar.parseCoords(text)
    if type(text) ~= "string" then return nil end
    local x, y, z = string.match(text, "^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*,?%s*(-?[%d%.]*)%s*$")
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return nil end
    return { x = math.floor(x), y = math.floor(y), z = math.floor(tonumber(z) or 0) }
end

function Hotbar.coordsText(x, y, z)
    return Hotbar.int(x) .. "," .. Hotbar.int(y) .. "," .. Hotbar.int(z or 0)
end

local function positionOf(object)
    return { x = math.floor(object:getX()), y = math.floor(object:getY()), z = math.floor(object:getZ()) }
end

local function squareToLocation(square)
    return { x = square:getX(), y = square:getY(), z = square:getZ() }
end

--- A setting's value without asking anything. nil when it would have to be asked.
local function peekValue(slot, spec, admin, values)
    local raw = settingOf(slot, spec)
    if spec.type == "player" then
        if raw == "@me" then return admin:getUsername() end
        if raw == nil or raw == "@ask" or raw == "" then return nil end
        return raw
    elseif spec.type == "location" then
        if raw == "@me" then return positionOf(admin) end
        if raw == "@player" then
            local name = values[Hotbar.hasPlayerParam(Hotbar.getAction(slot.action)) or ""]
            local player = name and getPlayerFromUsername(name)
            return player and positionOf(player) or nil
        end
        return Hotbar.parseCoords(raw)
    elseif spec.type == "vehicle" then
        if raw == "@pick" then return nil end
        return admin:getVehicle() or admin:getNearVehicle()
    elseif spec.type == "number" then
        return tonumber(raw)
    elseif spec.type == "bool" then
        return raw == true
    end
    if raw == "" then return nil end
    return raw
end

function Hotbar.peek(slot, admin)
    local action = Hotbar.getAction(slot.action)
    local values = {}
    for _, spec in ipairs(action.params) do
        values[spec.key] = peekValue(slot, spec, admin, values)
    end
    return { admin = admin, slot = slot, action = action, values = values }
end

--- Does clicking this slot ask for something?
function Hotbar.asksWhenUsed(slot)
    local action = Hotbar.getAction(slot.action)
    if not action or slot.window then return false end
    for _, spec in ipairs(action.params) do
        local raw = settingOf(slot, spec)
        if spec.type == "player" and (raw == nil or raw == "@ask") and not spec.optional then return true end
        if spec.type == "location" and (raw == nil or raw == "@pick") then return true end
        if spec.type == "vehicle" and raw == "@pick" then return true end
        if (spec.type == "choice" or spec.type == "text" or spec.type == "number")
                and (raw == nil or raw == "") and not spec.optional then
            return true
        end
    end
    return false
end

--- The choices of a choice param, as { text, data, ... }.
function Hotbar.choicesOf(spec)
    if type(spec.options) == "function" then return spec.options() end
    return spec.options or {}
end

function Hotbar.choiceText(spec, value)
    if value == nil then return nil end
    -- Long lists (items, vehicles) name a value directly instead of being searched.
    if spec.textOf then
        return spec.textOf(value) or tostring(value)
    end
    for _, choice in ipairs(Hotbar.choicesOf(spec)) do
        if choice.data == value then return choice.text end
    end
    return tostring(value)
end

local function resolveOne(slot, action, spec, admin, values, done)
    local raw = settingOf(slot, spec)
    local value = peekValue(slot, spec, admin, values)

    if spec.type == "player" then
        if value or spec.optional then return done(value) end
        return Hotbar.pickPlayer(admin, done)
    elseif spec.type == "location" then
        if value then return done(value) end
        if raw == "@player" then
            Hotbar.say(admin, txt("PlayerNotLoaded"), true)
            return
        end
        return Hotbar.pickSquare(admin, function(square) done(squareToLocation(square)) end)
    elseif spec.type == "vehicle" then
        if value then return done(value) end
        if raw ~= "@pick" then
            Hotbar.say(admin, txt("NoVehicleNear"), true)
            return
        end
        return Hotbar.pickSquare(admin, function(square)
            local vehicle = square:getVehicleContainer()
            if not vehicle then
                Hotbar.say(admin, txt("NoVehicleThere"), true)
                return
            end
            done(vehicle)
        end)
    elseif spec.type == "number" then
        if value or spec.optional then return done(value) end
        local title = spec.hint and (spec.title .. " (" .. spec.hint .. ")") or spec.title
        return Hotbar.prompt(title, "", true, function(text)
            local number = tonumber(text)
            if number then done(number) end
        end)
    elseif spec.type == "text" then
        if value or spec.optional then return done(value) end
        return Hotbar.prompt(spec.title, "", false, function(text)
            if text and text ~= "" then done(text) end
        end)
    elseif spec.type == "choice" then
        if value ~= nil or spec.optional then return done(value) end
        return Hotbar.pickFromList(spec.title, Hotbar.choicesOf(spec), done)
    end
    return done(value)
end

--- Resolve every setting, asking where needed, then call done(ctx).
local function resolve(slot, admin, done)
    local action = Hotbar.getAction(slot.action)
    local values = {}
    local index = 0
    local function step()
        index = index + 1
        local spec = action.params[index]
        if not spec then
            return done({ admin = admin, slot = slot, action = action, values = values })
        end
        resolveOne(slot, action, spec, admin, values, function(value)
            values[spec.key] = value
            step()
        end)
    end
    step()
end

-- Availability and state --------------------------------------------------------------

function Hotbar.availability(action, admin)
    if not action then return false, txt("Unknown") end
    if admin:isDead() then return false, txt("Dead") end
    if action.available then
        return action.available(admin)
    end
    return true
end

local function isToggle(action, ctx)
    if not action.toggle then return false end
    if action.toggle.applies then return action.toggle.applies(ctx) == true end
    return true
end

--- What a slot shows. Computed every STATE_MS and cached on the slot.
local function computeState(slot, admin, now)
    local action = Hotbar.getAction(slot.action)
    local state = { available = false }
    if not action then
        state.reason = txt("Unknown")
        return state
    end
    local ok, reason = Hotbar.availability(action, admin)
    state.available = ok
    state.reason = reason
    state.asks = Hotbar.asksWhenUsed(slot)

    if not slot.window and action.toggle then
        local ctx = Hotbar.peek(slot, admin)
        if isToggle(action, ctx) then
            state.toggle = true
            local okOn, on = pcall(action.toggle.isOn, ctx)
            if okOn then state.on = on end
        end
    end

    local pending = slot.pending
    if pending then
        if now > pending.untilMs or (pending.want ~= nil and state.on == pending.want) then
            slot.pending = nil
        else
            state.pending = true
        end
    end
    return state
end

function Hotbar.slotState(slot, admin, now)
    now = now or getTimestampMs()
    if not slot.cache or now - (slot.cacheMs or 0) >= STATE_MS then
        slot.cache = computeState(slot, admin, now)
        slot.cacheMs = now
    end
    return slot.cache
end

function Hotbar.invalidate(slot)
    if slot then slot.cacheMs = 0 end
end

--- Whether any toggle on the bar is on, for the sidebar dot.
function Hotbar.anyToggleOn(admin)
    if not Hotbar.state then return false end
    local now = getTimestampMs()
    for _, slot in ipairs(Hotbar.state.slots) do
        local state = Hotbar.slotState(slot, admin, now)
        if state.toggle and state.on == true then return true end
    end
    return false
end

-- Using a slot ---------------------------------------------------------------------

local function runResolved(ctx)
    local action = ctx.action
    local slot = ctx.slot
    if isToggle(action, ctx) then
        local current = action.toggle.isOn(ctx)
        local want = nil
        if current ~= nil then want = not current end
        action.toggle.set(ctx, want)
        slot.pending = { want = want, untilMs = getTimestampMs() + PENDING_MS }
        Hotbar.invalidate(slot)
        return
    end
    if action.run then action.run(ctx) end
end

function Hotbar.activate(slot, admin)
    admin = admin or getPlayer()
    if not admin or not Hotbar.canUse(admin) then return end
    local action = Hotbar.getAction(slot.action)
    local ok, reason = Hotbar.availability(action, admin)
    if not ok then
        Hotbar.say(admin, reason, true)
        return
    end

    if slot.window and action.openUI then
        action.openUI(Hotbar.peek(slot, admin))
        return
    end

    resolve(slot, admin, function(ctx)
        local wantsConfirm = slot.confirm
        if wantsConfirm == nil then wantsConfirm = action.confirm == true end
        if wantsConfirm then
            Hotbar.confirm(txt("ConfirmRun", Hotbar.slotTitle(slot)), function() runResolved(ctx) end)
        else
            runResolved(ctx)
        end
    end)
end

-- Slots on the bar ---------------------------------------------------------------------

function Hotbar.addSlot(slot, index)
    local state = Hotbar.state
    if not state then return end
    if index and index >= 1 and index <= #state.slots + 1 then
        table.insert(state.slots, index, slot)
    else
        table.insert(state.slots, slot)
    end
    state.visible = true
    Hotbar.save()
    Hotbar.refreshBar()
end

function Hotbar.removeSlot(slot)
    local state = Hotbar.state
    for i, other in ipairs(state.slots) do
        if other == slot then
            table.remove(state.slots, i)
            break
        end
    end
    Hotbar.save()
    Hotbar.refreshBar()
end

function Hotbar.moveSlot(slot, delta)
    local slots = Hotbar.state.slots
    for i, other in ipairs(slots) do
        if other == slot then
            local j = i + delta
            if j >= 1 and j <= #slots then
                slots[i], slots[j] = slots[j], slots[i]
                Hotbar.save()
                Hotbar.refreshBar()
            end
            return
        end
    end
end

--- The icon a slot shows: its own, else its action's (which may follow the settings).
function Hotbar.iconRef(slot)
    if slot.icon and slot.icon ~= "" then return slot.icon end
    local action = Hotbar.getAction(slot.action)
    if action then
        if type(action.icon) == "function" then
            local okIcon, ref = pcall(action.icon, slot.settings or {})
            if okIcon and ref then return ref end
        elseif action.icon then
            return action.icon
        end
    end
    return "sym:Question"
end

function Hotbar.iconTexture(slot)
    local Icons = Hotbar.Icons
    if not Icons then return nil end
    return Icons.texture(Hotbar.iconRef(slot)) or Icons.texture("sym:Question")
end

-- Slot button ---------------------------------------------------------------------------

local SlotButton = ISButton:derive("ZomboidFixesB42_AdminHotbarSlot")

function SlotButton:new(x, y, width, height, bar, slot, index)
    local o = ISButton.new(self, x, y, width, height, "", bar, nil)
    o.bar = bar
    o.slot = slot
    o.index = index
    o.displayBackground = false
    return o
end

local function circle()
    return getTexture("media/ui/circle.png")
end

local function truncate(text, width, font)
    local tm = getTextManager()
    if tm:MeasureStringX(font, text) <= width then return text end
    local cut = text
    while #cut > 1 and tm:MeasureStringX(font, cut .. "..") > width do
        cut = string.sub(cut, 1, #cut - 1)
    end
    return cut .. ".."
end

function SlotButton:prerender()
    local admin = getPlayer()
    local w, h = self.width, self.height
    if not self.slot then
        -- The "+" button.
        self:drawRect(0, 0, w, h, 0.6, 0.05, 0.05, 0.05)
        self:drawRectBorder(0, 0, w, h, 0.6, 0.4, 0.4, 0.4)
        if self:isMouseOver() then self:drawRect(0, 0, w, h, 0.12, 1, 1, 1) end
        self:updateTooltip()
        return
    end

    local state = admin and Hotbar.slotState(self.slot, admin) or { available = false }
    local on = Hotbar.state.on
    local bg = { r = 0.07, g = 0.07, b = 0.07, a = 0.85 }
    local border = { r = 0.42, g = 0.42, b = 0.42, a = 1 }
    if not state.available then
        bg = { r = 0.04, g = 0.04, b = 0.04, a = 0.8 }
        border = { r = 0.22, g = 0.22, b = 0.22, a = 1 }
    elseif state.pending then
        local pulse = 0.3 + 0.2 * math.sin(getTimestampMs() / 150)
        bg = { r = AMBER.r, g = AMBER.g, b = AMBER.b, a = pulse }
        border = { r = AMBER.r, g = AMBER.g, b = AMBER.b, a = 1 }
    elseif state.toggle and state.on == true then
        bg = { r = on.r, g = on.g, b = on.b, a = 0.55 }
        border = { r = math.min(1, on.r + 0.25), g = math.min(1, on.g + 0.25), b = math.min(1, on.b + 0.25), a = 1 }
    elseif state.toggle and state.on == nil then
        border = { r = AMBER.r, g = AMBER.g, b = AMBER.b, a = 1 }
    end

    self:drawRect(0, 0, w, h, bg.a, bg.r, bg.g, bg.b)
    self:drawRectBorder(0, 0, w, h, border.a, border.r, border.g, border.b)
    if state.toggle and state.on == true and state.available and not state.pending then
        self:drawRectBorder(1, 1, w - 2, h - 2, border.a * 0.6, border.r, border.g, border.b)
    end
    if self:isMouseOver() then
        if state.available then
            self:drawRect(0, 0, w, h, 0.12, 1, 1, 1)
        end
        -- Only built while hovered: it names every setting.
        self.tooltip = self.bar:tooltipFor(self.slot, state)
    end
    self:updateTooltip()
end

function SlotButton:render()
    local cell = self.bar.cell
    local pad = math.max(3, math.floor(cell / 10))
    local iconSize = cell - pad * 2

    if not self.slot then
        self:drawTextCentre("+", self.width / 2, (cell - FONT_HGT_MEDIUM) / 2, 0.85, 0.85, 0.85, 1, UIFont.Medium)
        return
    end

    local admin = getPlayer()
    local state = admin and Hotbar.slotState(self.slot, admin) or { available = false }
    local alpha = state.available and 1 or 0.35
    local texture = Hotbar.iconTexture(self.slot)
    if texture then
        local tint = self.slot.tint or { r = 1, g = 1, b = 1 }
        self:drawTextureScaledAspect(texture, pad, pad, iconSize, iconSize, alpha, tint.r, tint.g, tint.b)
    end

    local dot = math.max(8, math.floor(cell / 4))
    local dx = self.width - dot - 2
    local tex = circle()
    if state.available and tex then
        if state.pending then
            self:drawTextureScaled(tex, dx, 2, dot, dot, 1, AMBER.r, AMBER.g, AMBER.b)
        elseif state.toggle and state.on == true then
            local on = Hotbar.state.on
            self:drawTextureScaled(tex, dx, 2, dot, dot, 1, on.r, on.g, on.b)
            local check = Hotbar.Icons and Hotbar.Icons.texture("sym:Checkmark")
            if check then
                self:drawTextureScaledAspect(check, dx + 1, 3, dot - 2, dot - 2, 1, 1, 1, 1)
            end
        elseif state.toggle and state.on == false then
            self:drawTextureScaled(tex, dx, 2, dot, dot, 0.9, 0.55, 0.55, 0.55)
            self:drawTextureScaled(tex, dx + 2, 4, dot - 4, dot - 4, 1, 0.07, 0.07, 0.07)
        elseif state.toggle then
            self:drawTextureScaled(tex, dx, 2, dot, dot, 1, AMBER.r, AMBER.g, AMBER.b)
            self:drawTextCentre("?", dx + dot / 2, 2 + (dot - FONT_HGT_SMALL) / 2, 0.05, 0.05, 0.05, 1, UIFont.Small)
        end
    end

    if state.asks and state.available then
        self:drawText("?", 3, cell - FONT_HGT_SMALL - 1, 0.6, 0.85, 1, alpha, UIFont.Small)
    end
    if self.keyText then
        self:drawText(self.keyText, 3, 1, 1, 1, 1, 0.8 * alpha, UIFont.Small)
    end
    if Hotbar.state.labels then
        local label = truncate(Hotbar.slotTitle(self.slot), self.width - 4, UIFont.Small)
        self:drawTextCentre(label, self.width / 2, cell, 0.95, 0.95, 0.95, alpha, UIFont.Small)
    end
end

function SlotButton:onRightMouseUp(x, y)
    self.bar:showMenu(self.slot, self.index)
    return true
end

-- The bar -------------------------------------------------------------------------------

local Bar = ISPanel:derive("ZomboidFixesB42_AdminHotbarBar")

local GRIP = 10

function Bar:new(x, y)
    local o = ISPanel:new(x, y, 100, 50)
    setmetatable(o, self)
    self.__index = self
    o.moveWithMouse = true
    o.background = false
    o.buttons = {}
    o.cell = SIZES[2]
    o.lastPlayers = 0
    o.lastClimate = 0
    return o
end

function Bar:rebuild()
    for _, button in ipairs(self.buttons) do
        self:removeChild(button)
    end
    self.buttons = {}

    local state = Hotbar.state
    local fontExtra = math.max(0, (getCore():getOptionFontSizeReal() or 1) - 1) * 4
    self.cell = (SIZES[state.size] or SIZES[2]) + fontExtra
    local labelHeight = state.labels and (FONT_HGT_SMALL + 2) or 0
    local slotWidth = state.labels and math.max(self.cell, self.cell + 24) or self.cell
    local slotHeight = self.cell + labelHeight
    local gap = 3

    local count = #state.slots + 1
    local pos = GRIP
    for i = 1, count do
        local slot = state.slots[i]
        local x, y
        if state.vertical then
            x, y = 3, pos
        else
            x, y = pos, 3
        end
        local button = SlotButton:new(x, y, slotWidth, slotHeight, self, slot, slot and i or nil)
        button:initialise()
        button:instantiate()
        if not slot then
            button.tooltip = txt("AddShortcutTooltip")
        end
        button.onclick = Bar.onSlotClick
        button.target = self
        self:addChild(button)
        table.insert(self.buttons, button)
        pos = pos + (state.vertical and slotHeight or slotWidth) + gap
    end

    if state.vertical then
        self:setWidth(slotWidth + 6)
        self:setHeight(pos - gap + 3)
    else
        self:setWidth(pos - gap + 3)
        self:setHeight(slotHeight + 6)
    end
    self:updateKeyTexts()
    self:clampToScreen()
end

function Bar:updateKeyTexts()
    for _, button in ipairs(self.buttons) do
        button.keyText = nil
        if button.index and button.index <= SLOT_KEYS then
            local key = Hotbar.slotKey(button.index)
            if key and key ~= 0 then
                button.keyText = getKeyName(key)
            end
        end
    end
end

function Bar:clampToScreen()
    local core = getCore()
    local x = math.max(0, math.min(self:getX(), core:getScreenWidth() - self.width))
    local y = math.max(0, math.min(self:getY(), core:getScreenHeight() - self.height))
    if x ~= self:getX() then self:setX(x) end
    if y ~= self:getY() then self:setY(y) end
end

function Bar:onSlotClick(button)
    if not button.slot then
        return self:showAddMenu(nil)
    end
    Hotbar.activate(button.slot)
end

function Bar:prerender()
    self:drawRect(0, 0, self.width, self.height, 0.55, 0, 0, 0)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.35, 0.35, 0.35)
    -- The grip: a column (or row) of dots that shows where to drag.
    local tex = circle()
    if tex then
        for i = 0, 2 do
            if Hotbar.state.vertical then
                local x = self.width / 2 - 7 + i * 5
                self:drawTextureScaled(tex, x, 3, 3, 3, 0.8, 0.7, 0.7, 0.7)
            else
                local y = self.height / 2 - 7 + i * 5
                self:drawTextureScaled(tex, 3, y, 3, 3, 0.8, 0.7, 0.7, 0.7)
            end
        end
    end
end

function Bar:tooltipFor(slot, state)
    local action = Hotbar.getAction(slot.action)
    local lines = { Hotbar.slotTitle(slot) }
    if action and action.tooltip then table.insert(lines, action.tooltip) end
    if action then
        if slot.window and action.openUI then
            table.insert(lines, txt("OpensWindow"))
        else
            for _, spec in ipairs(action.params) do
                local summary = Hotbar.describeSetting(slot, spec)
                if summary then table.insert(lines, spec.title .. ": " .. summary) end
            end
        end
    end
    if state.toggle then
        if state.pending then
            table.insert(lines, txt("StateWaiting"))
        elseif state.on == true then
            table.insert(lines, txt("StateOn"))
        elseif state.on == false then
            table.insert(lines, txt("StateOff"))
        else
            table.insert(lines, txt("StateUnknown"))
        end
    end
    if not state.available and state.reason then
        table.insert(lines, txt("Unavailable", state.reason))
    end
    return table.concat(lines, "\n")
end

function Hotbar.describeSetting(slot, spec)
    local raw = settingOf(slot, spec)
    -- An optional setting left empty is not worth a line.
    local askText = not spec.optional and txt("SettingAsk") or nil
    if spec.type == "player" then
        if raw == "@me" then return txt("SettingMe") end
        if raw == nil or raw == "@ask" then return askText end
        return raw
    elseif spec.type == "location" then
        if raw == "@me" then return txt("SettingMyPosition") end
        if raw == "@player" then return txt("SettingPlayerPosition") end
        if raw == nil or raw == "@pick" then return txt("SettingPick") end
        return raw
    elseif spec.type == "vehicle" then
        if raw == "@pick" then return txt("SettingPick") end
        return txt("SettingNearVehicle")
    elseif spec.type == "bool" then
        if raw == true then return getText("UI_Yes") end
        return nil
    elseif spec.type == "choice" then
        if raw == nil then return askText end
        return Hotbar.choiceText(spec, raw)
    elseif spec.type == "preset" then
        if raw == nil then return txt("SettingNone") end
        return spec.summary and spec.summary(raw) or txt("SettingPreset")
    end
    if raw == nil or raw == "" then return askText end
    return tostring(raw)
end

-- Menus ----------------------------------------------------------------------------------

local function sortedActions(categoryId)
    local list = {}
    for _, id in ipairs(Hotbar.actionOrder) do
        local action = Hotbar.actions[id]
        if action.category == categoryId and not action.hidden then
            table.insert(list, action)
        end
    end
    return list
end

--- "Add shortcut" as a submenu of parent (or a new menu at the mouse).
function Bar:fillAddMenu(context, insertAt)
    local admin = getPlayer()
    for _, category in ipairs(Hotbar.categories) do
        local actions = sortedActions(category.id)
        if #actions > 0 then
            local option = context:addOption(category.title, nil, nil)
            local sub = ISContextMenu:getNew(context)
            context:addSubMenu(option, sub)
            for _, action in ipairs(actions) do
                local item = sub:addOption(Hotbar.titleOf(action, nil), self, Bar.onAddAction, action.id, insertAt)
                local ok, reason = Hotbar.availability(action, admin)
                if not ok then
                    item.notAvailable = true
                    local tooltip = ISWorldObjectContextMenu.addToolTip()
                    tooltip.description = reason or ""
                    item.toolTip = tooltip
                elseif action.tooltip then
                    local tooltip = ISWorldObjectContextMenu.addToolTip()
                    tooltip.description = action.tooltip
                    item.toolTip = tooltip
                end
            end
        end
    end
end

function Bar:showAddMenu(insertAt)
    local admin = getPlayer()
    local context = ISContextMenu.get(admin:getPlayerNum(), getMouseX(), getMouseY())
    self:fillAddMenu(context, insertAt)
end

function Bar:onAddAction(actionId, insertAt)
    local action = Hotbar.getAction(actionId)
    if not action then return end
    local slot = newSlot(actionId)
    if #action.params == 0 and not action.openUI then
        Hotbar.addSlot(slot, insertAt)
        return
    end
    Hotbar.openSettings(slot, function(saved) Hotbar.addSlot(saved, insertAt) end)
end

function Bar:showMenu(slot, index)
    local admin = getPlayer()
    local context = ISContextMenu.get(admin:getPlayerNum(), getMouseX(), getMouseY())
    local state = Hotbar.state

    if slot then
        context:addOption(txt("Edit"), slot, function(s)
            Hotbar.openSettings(s, function(saved)
                -- Field by field: a setting that was cleared is nil in saved.
                s.settings = saved.settings
                s.window = saved.window
                s.label = saved.label
                s.icon = saved.icon
                s.tint = saved.tint
                s.confirm = saved.confirm
                s.pending = nil
                Hotbar.invalidate(s)
                Hotbar.save()
                Hotbar.refreshBar()
            end)
        end)
        context:addOption(txt("ChangeIcon"), slot, function(s)
            if Hotbar.Icons then
                Hotbar.Icons.openPicker(s.icon, s.tint, function(ref, tint)
                    s.icon = ref
                    s.tint = tint
                    Hotbar.save()
                end)
            end
        end)
        context:addOption(txt("Rename"), slot, function(s)
            Hotbar.prompt(txt("Rename"), Hotbar.slotTitle(s), false, function(text)
                s.label = (text ~= "" and text ~= Hotbar.titleOf(Hotbar.getAction(s.action), s)) and text or nil
                Hotbar.save()
            end)
        end)
        local before = state.vertical and txt("MoveUp") or txt("MoveLeft")
        local after = state.vertical and txt("MoveDown") or txt("MoveRight")
        if index and index > 1 then
            context:addOption(before, slot, function(s) Hotbar.moveSlot(s, -1) end)
        end
        if index and index < #state.slots then
            context:addOption(after, slot, function(s) Hotbar.moveSlot(s, 1) end)
        end
        context:addOption(txt("Remove"), slot, function(s) Hotbar.removeSlot(s) end)
    end

    local addOption = context:addOption(txt("AddShortcut"), nil, nil)
    local addMenu = ISContextMenu:getNew(context)
    context:addSubMenu(addOption, addMenu)
    self:fillAddMenu(addMenu, index and index + 1 or nil)

    local barOption = context:addOption(txt("BarOptions"), nil, nil)
    local barMenu = ISContextMenu:getNew(context)
    context:addSubMenu(barOption, barMenu)
    barMenu:addOption(state.vertical and txt("Horizontal") or txt("Vertical"), self, function()
        state.vertical = not state.vertical
        Hotbar.save()
        Hotbar.refreshBar()
    end)
    local labels = barMenu:addOption(txt("ShowLabels"), self, function()
        state.labels = not state.labels
        Hotbar.save()
        Hotbar.refreshBar()
    end)
    barMenu:setOptionChecked(labels, state.labels)
    local sizeOption = barMenu:addOption(txt("Size"), nil, nil)
    local sizeMenu = ISContextMenu:getNew(barMenu)
    barMenu:addSubMenu(sizeOption, sizeMenu)
    for i, key in ipairs({ "SizeSmall", "SizeMedium", "SizeLarge" }) do
        local option = sizeMenu:addOption(txt(key), i, function(size)
            state.size = size
            Hotbar.save()
            Hotbar.refreshBar()
        end)
        sizeMenu:setOptionChecked(option, state.size == i)
    end
    barMenu:addOption(txt("OnColour"), self, Bar.pickOnColour)
    barMenu:addOption(txt("Reset"), self, function()
        Hotbar.confirm(txt("ResetConfirm"), function()
            local x, y = state.x, state.y
            Hotbar.state = defaultState()
            Hotbar.state.x, Hotbar.state.y = x, y
            Hotbar.save()
            Hotbar.refreshBar()
        end)
    end)
    context:addOption(txt("Hide"), self, function() Hotbar.setVisible(false) end)
end

function Bar:pickOnColour()
    local on = Hotbar.state.on
    local picker = ISColorPicker:new(getMouseX() - 100, getMouseY() - 20)
    picker:initialise()
    picker.pickedTarget = self
    picker.resetFocusTo = self
    picker:setInitialColor(ColorInfo.new(on.r, on.g, on.b, 1))
    picker:setPickedFunc(function(_, color)
        Hotbar.state.on = { r = color.r, g = color.g, b = color.b }
        Hotbar.save()
    end)
    picker:addToUIManager()
    picker:bringToTop()
end

function Bar:onRightMouseUp(x, y)
    self:showMenu(nil, nil)
    return true
end

function Bar:onMouseUp(x, y)
    ISPanel.onMouseUp(self, x, y)
    self:rememberPosition()
end

function Bar:onMouseUpOutside(x, y)
    ISPanel.onMouseUpOutside(self, x, y)
    self:rememberPosition()
end

function Bar:rememberPosition()
    self:clampToScreen()
    local state = Hotbar.state
    if state.x ~= self:getX() or state.y ~= self:getY() then
        state.x, state.y = self:getX(), self:getY()
        Hotbar.save()
    end
end

function Bar:update()
    ISPanel.update(self)
    local admin = getPlayer()
    if not admin or not Hotbar.canUse(admin) then
        self:setVisible(false)
        return
    end

    local now = getTimestampMs()
    if now - self.lastPlayers >= SCOREBOARD_MS then
        self.lastPlayers = now
        Hotbar.requestPlayers()
    end
    if now - self.lastClimate >= CLIMATE_MS then
        self.lastClimate = now
        for _, slot in ipairs(Hotbar.state.slots) do
            local action = Hotbar.getAction(slot.action)
            if action and action.climate then
                -- The toggle compares against these; ask for the server's copy so a
                -- change made by another admin is not overwritten from a stale one.
                getClimateManager():transmitRequestAdminVars()
                break
            end
        end
    end
end

function Hotbar.getBar()
    if Hotbar.bar then return Hotbar.bar end
    local state = Hotbar.state
    local core = getCore()
    local bar = Bar:new(state.x or 0, state.y or 60)
    bar:initialise()
    bar:addToUIManager()
    Hotbar.bar = bar
    bar:rebuild()
    if not state.x then
        bar:setX(core:getScreenWidth() / 2 - bar.width / 2)
        state.x = bar:getX()
    end
    return bar
end

function Hotbar.refreshBar()
    if not Hotbar.state then return end
    local admin = getPlayer()
    local bar = Hotbar.getBar()
    bar:rebuild()
    bar:setVisible(Hotbar.state.visible and admin ~= nil and Hotbar.canUse(admin))
end

function Hotbar.setVisible(visible)
    if not Hotbar.state then return end
    Hotbar.state.visible = visible
    Hotbar.save()
    local bar = Hotbar.getBar()
    local admin = getPlayer()
    bar:setVisible(visible and admin ~= nil and Hotbar.canUse(admin))
    if visible then
        bar:bringToTop()
        Hotbar.requestPlayers()
    end
end

function Hotbar.isVisible()
    return Hotbar.bar ~= nil and Hotbar.bar:getIsVisible()
end

function Hotbar.toggle()
    Hotbar.setVisible(not Hotbar.isVisible())
end

-- Settings dialog ---------------------------------------------------------------------------

local Settings = ISPanel:derive("ZomboidFixesB42_AdminHotbarSettings")

local LABEL_WIDTH = 150
local CONTROL_WIDTH = 330

local function wrapLines(text, width, font)
    local tm = getTextManager()
    local lines, line = {}, ""
    for word in string.gmatch(text, "%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if line ~= "" and tm:MeasureStringX(font, try) > width then
            table.insert(lines, line)
            line = word
        else
            line = try
        end
    end
    if line ~= "" then table.insert(lines, line) end
    return lines
end

function Settings:new(slot, onSave)
    local width = LABEL_WIDTH + CONTROL_WIDTH + UI_BORDER_SPACING * 3
    local core = getCore()
    local o = ISPanel:new(core:getScreenWidth() / 2 - width / 2, 120, width, 200)
    setmetatable(o, self)
    self.__index = self
    o.slot = slot
    o.action = Hotbar.getAction(slot.action)
    o.onSave = onSave
    o.settings = {}
    for k, v in pairs(slot.settings or {}) do o.settings[k] = v end
    o.icon = slot.icon
    o.tint = slot.tint
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.9 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.moveWithMouse = true
    o.rows = {}
    return o
end

function Settings:addLabel(text, y)
    local label = ISLabel:new(UI_BORDER_SPACING + 1, y, BUTTON_HGT, text, 1, 1, 1, 1, UIFont.Small, true)
    label:initialise()
    self:addChild(label)
    return label
end

function Settings:addButton(x, y, width, title, onClick)
    local button = ISButton:new(x, y, width, BUTTON_HGT, title, self, onClick)
    button:initialise()
    button:instantiate()
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
    self:addChild(button)
    return button
end

function Settings:addEntry(x, y, width, text, numbers)
    local entry = ISTextEntryBox:new(text or "", x, y, width, BUTTON_HGT)
    entry:initialise()
    entry:instantiate()
    self:addChild(entry)
    if numbers then entry:setOnlyNumbers(true) end
    return entry
end

function Settings:addCombo(x, y, width, options, selectedData)
    local combo = ISComboBox:new(x, y, width, BUTTON_HGT, self, nil)
    combo:initialise()
    self:addChild(combo)
    for _, option in ipairs(options) do
        combo:addOptionWithData(option.text, option.data)
    end
    combo.selected = 1
    for i, option in ipairs(options) do
        if option.data == selectedData then combo.selected = i end
    end
    return combo
end

function Settings:addTick(x, y, width, text, selected)
    local tick = ISTickBox:new(x, y, width, BUTTON_HGT, "", self, nil)
    tick:initialise()
    tick:instantiate()
    tick.choicesColor = { r = 1, g = 1, b = 1, a = 1 }
    self:addChild(tick)
    tick:addOption(text)
    tick.selected[1] = selected == true
    return tick
end

function Settings:createChildren()
    ISPanel.createChildren(self)
    local action = self.action
    local cx = UI_BORDER_SPACING * 2 + LABEL_WIDTH
    local y = UI_BORDER_SPACING * 2 + FONT_HGT_MEDIUM + 4

    if action.tooltip then
        for _, line in ipairs(wrapLines(action.tooltip, self.width - UI_BORDER_SPACING * 2 - 2, UIFont.Small)) do
            local label = ISLabel:new(UI_BORDER_SPACING + 1, y, FONT_HGT_SMALL, line, 0.8, 0.8, 0.8, 1, UIFont.Small, true)
            label:initialise()
            self:addChild(label)
            y = y + FONT_HGT_SMALL + 2
        end
        y = y + UI_BORDER_SPACING
    end

    if action.openUI then
        self.windowTick = self:addTick(UI_BORDER_SPACING + 1, y, self.width - UI_BORDER_SPACING * 2, txt("OpenWindowInstead"), self.slot.window)
        y = y + BUTTON_HGT + UI_BORDER_SPACING
    end

    for _, spec in ipairs(action.params) do
        y = self:addParamRow(spec, cx, y)
    end

    self:addLabel(txt("Label"), y)
    self.labelEntry = self:addEntry(cx, y, CONTROL_WIDTH, self.slot.label or "")
    self.labelEntry:setPlaceholderText(Hotbar.titleOf(action, self.slot))
    y = y + BUTTON_HGT + UI_BORDER_SPACING

    self:addLabel(txt("Icon"), y)
    local iconSize = BUTTON_HGT * 2
    self.iconButton = self:addButton(cx, y, iconSize, "", Settings.onIcon)
    self.iconButton.render = Settings.renderIconButton
    self.iconButton.settingsWindow = self
    self:addButton(cx + iconSize + UI_BORDER_SPACING, y, 110, txt("IconDefault"), Settings.onIconDefault)
    y = y + iconSize + UI_BORDER_SPACING

    local confirm = self.slot.confirm
    if confirm == nil then confirm = action.confirm == true end
    self.confirmTick = self:addTick(cx, y, CONTROL_WIDTH, txt("AskBeforeRunning"), confirm)
    y = y + BUTTON_HGT + UI_BORDER_SPACING * 2

    local buttonWidth = 110
    self.saveButton = self:addButton(self.width / 2 - buttonWidth - 5, y, buttonWidth, getText("IGUI_RadioSave"), Settings.onSaveClicked)
    self.saveButton:enableAcceptColor()
    self.cancelButton = self:addButton(self.width / 2 + 5, y, buttonWidth, getText("UI_Cancel"), Settings.close)
    self.cancelButton:enableCancelColor()
    y = y + BUTTON_HGT + UI_BORDER_SPACING

    self:setHeight(y)
    local core = getCore()
    self:setY(math.max(20, core:getScreenHeight() / 2 - y / 2))
end

function Settings:renderIconButton()
    ISButton.render(self)
    local window = self.settingsWindow
    local ref = window.icon
    if not ref or ref == "" then
        ref = Hotbar.iconRef({ action = window.slot.action, settings = window:collectSettings() })
    end
    local texture = Hotbar.Icons and Hotbar.Icons.texture(ref)
    if texture then
        local tint = window.tint or { r = 1, g = 1, b = 1 }
        self:drawTextureScaledAspect(texture, 3, 3, self.width - 6, self.height - 6, 1, tint.r, tint.g, tint.b)
    end
end

function Settings:onIcon()
    if not Hotbar.Icons then return end
    Hotbar.Icons.openPicker(self.icon, self.tint, function(ref, tint)
        self.icon = ref
        self.tint = tint
    end)
end

function Settings:onIconDefault()
    self.icon = nil
    self.tint = nil
end

function Settings:addParamRow(spec, cx, y)
    local row = { spec = spec }
    self.rows[spec.key] = row
    self:addLabel(spec.title, y)
    local raw = self.settings[spec.key]
    if raw == nil then raw = spec.default end

    if spec.type == "player" then
        local mode = (raw == "@me" or raw == "@ask" or raw == nil) and (raw or "@ask") or "name"
        local options = {
            { text = txt("SettingMe"), data = "@me" },
            { text = txt("SettingAsk"), data = "@ask" },
            { text = txt("SettingNamed"), data = "name" },
        }
        if spec.optional then
            options[2] = { text = txt("SettingNobody"), data = "@ask" }
        end
        row.combo = self:addCombo(cx, y, 150, options, mode)
        row.entry = self:addEntry(cx + 160, y, CONTROL_WIDTH - 160 - 40, mode == "name" and raw or "")
        row.pick = self:addButton(cx + CONTROL_WIDTH - 32, y, 32, "...", function()
            Hotbar.pickPlayer(getPlayer(), function(username)
                row.entry:setText(username)
                row.combo:selectData("name")
            end)
        end)
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "location" then
        local mode = raw
        if mode ~= "@me" and mode ~= "@pick" and mode ~= "@player" then
            mode = Hotbar.parseCoords(raw) and "fixed" or "@pick"
        end
        local options = {
            { text = txt("SettingMyPosition"), data = "@me" },
            { text = txt("SettingPick"), data = "@pick" },
        }
        if Hotbar.hasPlayerParam(self.action) then
            table.insert(options, { text = txt("SettingPlayerPosition"), data = "@player" })
        end
        table.insert(options, { text = txt("SettingFixed"), data = "fixed" })
        row.combo = self:addCombo(cx, y, CONTROL_WIDTH, options, mode)
        y = y + BUTTON_HGT + 4
        row.entry = self:addEntry(cx, y, 140, mode == "fixed" and raw or "")
        row.entry:setPlaceholderText("x,y,z")
        self:addButton(cx + 150, y, 80, txt("Here"), function()
            local me = getPlayer()
            row.entry:setText(Hotbar.coordsText(me:getX(), me:getY(), me:getZ()))
            row.combo:selectData("fixed")
        end)
        self:addButton(cx + 240, y, 90, txt("PickNow"), function()
            Hotbar.pickSquare(getPlayer(), function(square)
                row.entry:setText(Hotbar.coordsText(square:getX(), square:getY(), square:getZ()))
                row.combo:selectData("fixed")
            end)
        end)
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "vehicle" then
        row.combo = self:addCombo(cx, y, CONTROL_WIDTH, {
            { text = txt("SettingNearVehicle"), data = "@near" },
            { text = txt("SettingPick"), data = "@pick" },
        }, raw == "@pick" and "@pick" or "@near")
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "number" then
        row.entry = self:addEntry(cx, y, 120, raw ~= nil and tostring(raw) or "", true)
        if spec.min or spec.max then
            row.entry:setPlaceholderText(tostring(spec.min or "") .. " - " .. tostring(spec.max or ""))
        end
        if spec.hint then
            local hint = ISLabel:new(cx + 130, y, BUTTON_HGT, spec.hint, 0.7, 0.7, 0.7, 1, UIFont.Small, true)
            hint:initialise()
            self:addChild(hint)
        end
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "text" then
        row.entry = self:addEntry(cx, y, CONTROL_WIDTH, raw or "")
        if spec.hint then row.entry:setPlaceholderText(spec.hint) end
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "bool" then
        row.tick = self:addTick(cx, y, CONTROL_WIDTH, spec.tickText or getText("IGUI_DebugMenu_Enabled"), raw == true)
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "choice" then
        local choices = Hotbar.choicesOf(spec)
        if spec.search or #choices > 30 then
            row.value = raw
            row.button = self:addButton(cx, y, CONTROL_WIDTH - 90, "", function()
                Hotbar.pickFromList(spec.title, Hotbar.choicesOf(spec), function(data)
                    row.value = data
                    row.button:setTitle(Hotbar.choiceText(spec, data))
                end)
            end)
            row.button:setTitle(raw ~= nil and Hotbar.choiceText(spec, raw) or (spec.optional and txt("SettingNone") or txt("SettingAsk")))
            self:addButton(cx + CONTROL_WIDTH - 80, y, 80, spec.optional and txt("Clear") or txt("SettingAskShort"), function()
                row.value = nil
                row.button:setTitle(spec.optional and txt("SettingNone") or txt("SettingAsk"))
            end)
        else
            local options = {}
            if not spec.noAsk then
                table.insert(options, { text = spec.optional and txt("SettingNone") or txt("SettingAsk"), data = nil })
            end
            for _, choice in ipairs(choices) do table.insert(options, choice) end
            row.combo = self:addCombo(cx, y, CONTROL_WIDTH, options, raw)
        end
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "preset" then
        row.value = raw
        local summary = raw ~= nil and (spec.summary and spec.summary(raw) or txt("SettingPreset")) or txt("PresetNone")
        row.label = ISLabel:new(cx, y, BUTTON_HGT, summary, 0.85, 0.85, 0.85, 1, UIFont.Small, true)
        row.label:initialise()
        self:addChild(row.label)
        self:addButton(cx + CONTROL_WIDTH - 80, y, 80, txt("Clear"), function()
            row.value = nil
            row.label:setName(txt("PresetNone"))
        end)
        return y + BUTTON_HGT + UI_BORDER_SPACING
    end
    return y + BUTTON_HGT + UI_BORDER_SPACING
end

--- The settings as the controls show them now.
function Settings:collectSettings()
    local settings = {}
    for key, row in pairs(self.rows) do
        local spec = row.spec
        local value = nil
        if spec.type == "player" then
            local mode = row.combo:getOptionData(row.combo.selected)
            if mode == "name" then
                local name = string.trim(row.entry:getText() or "")
                value = name ~= "" and name or "@ask"
            else
                value = mode
            end
        elseif spec.type == "location" then
            local mode = row.combo:getOptionData(row.combo.selected)
            if mode == "fixed" then
                local coords = Hotbar.parseCoords(row.entry:getText())
                value = coords and Hotbar.coordsText(coords.x, coords.y, coords.z) or "@pick"
            else
                value = mode
            end
        elseif spec.type == "vehicle" then
            value = row.combo:getOptionData(row.combo.selected)
        elseif spec.type == "number" then
            value = tonumber(row.entry:getText())
            if value then
                if spec.min then value = math.max(spec.min, value) end
                if spec.max then value = math.min(spec.max, value) end
                if spec.integer then value = math.floor(value + 0.5) end
            end
        elseif spec.type == "text" then
            local text = row.entry:getText()
            value = (text and text ~= "") and text or nil
        elseif spec.type == "bool" then
            value = row.tick.selected[1] == true
        elseif spec.type == "choice" then
            if row.combo then
                value = row.combo:getOptionData(row.combo.selected)
            else
                value = row.value
            end
        elseif spec.type == "preset" then
            value = row.value
        end
        settings[key] = value
    end
    return settings
end

function Settings:onSaveClicked()
    local slot = {
        action = self.slot.action,
        settings = self:collectSettings(),
        window = self.windowTick ~= nil and self.windowTick.selected[1] == true,
        icon = self.icon,
        tint = self.tint,
    }
    local label = string.trim(self.labelEntry:getText() or "")
    slot.label = label ~= "" and label or nil
    local confirm = self.confirmTick.selected[1] == true
    if confirm ~= (self.action.confirm == true) then
        slot.confirm = confirm
    end
    self:close()
    self.onSave(slot)
end

function Settings:prerender()
    ISPanel.prerender(self)
    self:drawText(txt("SettingsTitle", Hotbar.titleOf(self.action, self.slot)), UI_BORDER_SPACING + 1, UI_BORDER_SPACING, 1, 1, 1, 1, UIFont.Medium)
end

function Settings:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

--- Open the settings dialog for a slot (new or existing). onSave(slot) gets a new table.
function Hotbar.openSettings(slot, onSave)
    local action = Hotbar.getAction(slot.action)
    if not action then return end
    local window = Settings:new(slot, onSave)
    window:initialise()
    window:addToUIManager()
    window:bringToTop()
    return window
end

--- For the capture buttons: open the dialog prefilled, and add the slot on save.
function Hotbar.capture(actionId, settings, extra)
    local admin = getPlayer()
    if not admin or not Hotbar.canUse(admin) or not Hotbar.state then return end
    local slot = { action = actionId, settings = settings or {}, window = false }
    if extra then
        for k, v in pairs(extra) do slot[k] = v end
    end
    Hotbar.openSettings(slot, function(saved) Hotbar.addSlot(saved) end)
end

-- Sidebar button ----------------------------------------------------------------------------

local SIDEBAR_TINT = { r = 1, g = 0.82, b = 0.3, a = 1 }

local function renderSidebarButton(self)
    ISButton.render(self)
    local Icons = Hotbar.Icons
    local bolt = Icons and Icons.texture("sym:Lightning")
    if bolt then
        local size = math.floor(self.width * 0.42)
        self:drawTextureScaledAspect(bolt, self.width - size - 2, self.height - size - 2, size, size, 1, 1, 0.9, 0.3)
    end
    local admin = getPlayer()
    if admin and not Hotbar.isVisible() and Hotbar.anyToggleOn(admin) then
        local tex = circle()
        local on = Hotbar.state.on
        local dot = math.max(8, math.floor(self.width / 6))
        if tex then
            self:drawTextureScaled(tex, self.width - dot - 2, 2, dot, dot, 1, on.r, on.g, on.b)
        end
    end
end

local vanillaInitialise = ISEquippedItem.initialise

function ISEquippedItem:initialise()
    vanillaInitialise(self)
    if not self.adminBtn then return end

    local button = ISButton:new(0, self.adminBtn:getBottom() + UI_BORDER_SPACING + 5,
        self.adminBtn:getWidth(), self.adminBtn:getHeight(), "", self, ISEquippedItem.onOptionMouseDown)
    button:setImage(self.adminIconOff)
    button.internal = "ZOMBOIDFIXES_HOTBAR"
    button:initialise()
    button:instantiate()
    button:setDisplayBackground(false)
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.1 }
    button.textureColor = { r = SIDEBAR_TINT.r, g = SIDEBAR_TINT.g, b = SIDEBAR_TINT.b, a = SIDEBAR_TINT.a }
    button:ignoreWidthChange()
    button:ignoreHeightChange()
    button.render = renderSidebarButton
    self:addChild(button)
    self:addMouseOverToolTipItem(button, txt("SidebarTooltip"))
    self.zomboidFixesHotbarBtn = button
    self:shrinkWrap()
end

local vanillaPrerender = ISEquippedItem.prerender

function ISEquippedItem:prerender()
    vanillaPrerender(self)
    local button = self.zomboidFixesHotbarBtn
    if not button then return end

    local visible = self.adminBtn and self.adminBtn:isVisible() and Hotbar.canUse(self.chr) or false
    button:setVisible(visible)
    if not visible then return end

    button:setY(self.adminBtn:getBottom() + UI_BORDER_SPACING + 5)
    button:setImage(Hotbar.isVisible() and self.adminIconOn or self.adminIconOff)
    local bottom = button:getBottom()
    if self.warManagerBtn and self.warManagerBtn:isVisible() then
        self.warManagerBtn:setY(bottom + UI_BORDER_SPACING)
        bottom = self.warManagerBtn:getBottom()
    end
    if self.height < bottom then
        self:setHeight(bottom)
    end
end

local vanillaOnOptionMouseDown = ISEquippedItem.onOptionMouseDown

function ISEquippedItem:onOptionMouseDown(button, x, y)
    if button.internal == "ZOMBOIDFIXES_HOTBAR" then
        if Hotbar.state then Hotbar.toggle() end
        return
    end
    return vanillaOnOptionMouseDown(self, button, x, y)
end

-- Keys ----------------------------------------------------------------------------------------

local modOptions = nil

if PZAPI and PZAPI.ModOptions then
    modOptions = PZAPI.ModOptions:create("ZomboidFixesB42", getText("IGUI_ZomboidFixesB42_ModOptions"))
    modOptions:addKeyBind("adminHotbarToggle", txt("KeyToggle"), 0, txt("KeyToggleTooltip"))
    for i = 1, SLOT_KEYS do
        modOptions:addKeyBind("adminHotbarSlot" .. i, txt("KeySlot", Hotbar.int(i)), 0)
    end
end

local function keyOf(id)
    local option = modOptions and modOptions:getOption(id)
    return option and option:getValue() or 0
end

function Hotbar.slotKey(index)
    return keyOf("adminHotbarSlot" .. index)
end

local function onKeyPressed(key)
    if not key or key == 0 or not Hotbar.state then return end
    local admin = getPlayer()
    if not admin or not Hotbar.canUse(admin) then return end

    if key == keyOf("adminHotbarToggle") then
        Hotbar.toggle()
        return
    end
    for i = 1, SLOT_KEYS do
        if key == keyOf("adminHotbarSlot" .. i) then
            local slot = Hotbar.state.slots[i]
            if slot then Hotbar.activate(slot, admin) end
            return
        end
    end
end

Events.OnKeyPressed.Add(onKeyPressed)

-- Start ------------------------------------------------------------------------------------------

local function onGameStart()
    -- Mod key binds are otherwise only read back from ModOptions.ini when the options
    -- screen is built.
    if PZAPI and PZAPI.ModOptions and modOptions then
        PZAPI.ModOptions:load()
    end
    Hotbar.load()
    Hotbar.refreshBar()
end

Events.OnGameStart.Add(onGameStart)
