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
        (the Horde Manager's picker), a searchable list, or a prompt. A square or
        vehicle can also be set to "keep picking": the picker stays on the map and
        every click runs the slot again there, until right-click or Esc. A
        right-click that ends a picker does not also open the context menu.
      - A slot can have steps: more actions, each with its own settings and delay,
        run after its own on the same click (see "Using a slot"). The slot's
        "On click" sets how its toggles turn: each flips from its own state, or
        the first step flips and the steps following it take its new state (or
        the opposite), or the first step stays and the following steps are
        only synced to its current state.
      - A slot can repeat: run again every N milliseconds (100 at least), a set
        number of times or until clicked again, or only while its mouse button or
        key is held (see "Repeating a slot").
      - A second click on a slot that opened a window closes it.

    Everything goes through vanilla commands and packets (or this mod's own Body
    Stats and Chopper commands), which check the sender's capability on the server,
    so there is no new server code here. The bar only shows for roles with
    hasAdminTool(), the rule vanilla uses for the sidebar Admin button, and each
    action is greyed out when the role lacks what it needs.

    Single player follows vanilla's rule for its admin tools there: they only exist
    with the -debug launch option (isDebugEnabled()). A single player character's
    role is Roles.getDefaultForNewUser(), which holds no admin capability at all, so
    vanilla gates its single player tools on debug mode instead of the role, and so
    does the bar: with -debug every action is offered, and each runs through the
    single player branch vanilla's own window has for it (direct calls; chat
    commands and most network packets do nothing without a server). Actions that
    only make sense on a server (kick, ban, server messages and options, the network
    admin windows) are greyed out. getAccessLevel() and getPlayerFromUsername() read
    the client connection, which single player does not have, so neither is called
    there.

    The sidebar button is added to ISEquippedItem, which stacks its buttons in
    initialise() and moves the war button under the Admin button every frame in
    prerender(), so the button goes in after initialise and is placed after
    prerender. Its icon is drawn, not shipped: the game's white disc texture tinted
    green (bar shown) or red (hidden), with three slots in a row. The mod ships no
    image files: every slot icon is a texture the game already has (see
    ZomboidFixesB42_AdminHotbarIcons.lua). Single player has
    no Admin button (vanilla only creates it on a client), so there the button goes
    under the lowest sidebar button instead.

    Slots are saved per client and per server, in Zomboid/Lua, because usernames
    and coordinates mean nothing on another server; single player has one file of
    its own. Keys are vanilla key bindings (Options > Key Bindings, "Admin Hotbar"),
    unbound by default (see Keys).
--]]

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
require "OptionScreens/MainOptions"

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
-- A step's wait after the part before it, unless the step sets its own (see "Using
-- a slot"), and the longest wait a step may set.
local STEP_DELAY_MS = 300
local STEP_DELAY_MAX_MS = 600000
-- A repeating slot's interval unless set, and its bounds (see "Repeating a slot").
local REPEAT_MS = 1000
local REPEAT_MIN_MS = 100
local REPEAT_MAX_MS = 600000

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

function Hotbar.isMultiplayer()
    return isClient()
end

--- On a server, the role's capability. In single player (only reached with -debug)
-- every capability, as vanilla's single player tools assume.
function Hotbar.hasCapability(player, name)
    if not isClient() then return player ~= nil end
    local role = player and player:getRole()
    local capability = name and Capability[name]
    return role ~= nil and capability ~= nil and role:hasCapability(capability)
end

--- The bar is for roles that get the sidebar Admin button; in single player, for
-- debug mode, where vanilla offers its admin tools.
function Hotbar.canUse(player)
    if not Hotbar.isEnabled() or not player then return false end
    if not isClient() then return isDebugEnabled() == true end
    local role = player:getRole()
    return role ~= nil and role:hasAdminTool()
end

--- AdminContextMenu's own gate for the right-click Tools menu. getAccessLevel()
-- reads the client connection, so single player never calls it.
function Hotbar.canUseTools()
    if not isClient() then return true end
    return isAdmin() or getAccessLevel() == "moderator"
end

-- Players ----------------------------------------------------------------------------

--- A player's name as the bar uses it. In single player it is the character's
-- forename and surname (IsoPlayer.updateUsername).
function Hotbar.nameOf(player)
    if not player then return nil end
    return player:getUsername() or player:getDisplayName() or ""
end

--- The player object for a name, if this client has it. getPlayerFromUsername
-- only knows a server's players, so single player searches its local players.
function Hotbar.findPlayer(name)
    if not name then return nil end
    if isClient() then return getPlayerFromUsername(name) end
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and Hotbar.nameOf(player) == name then return player end
    end
    return nil
end

-- Commands and feedback ---------------------------------------------------------

function Hotbar.quote(text)
    return "\"" .. (string.gsub(tostring(text), "\"", "\\\"")) .. "\""
end

--- Chat commands only exist on a server. Every action that uses one has a single
-- player branch or is greyed out there, so this is only a safety net.
function Hotbar.command(text)
    if not isClient() then
        Hotbar.say(getPlayer(), Hotbar.txt("MultiplayerOnly"), true)
        return
    end
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
--   toggle = { isOn(ctx) -> true/false/nil, set(ctx, on), applies(ctx) (optional) },
--   opensWindow (run opens a window, which a second click closes; always true for
--   the windows category and for openUI)
function Hotbar.registerAction(action)
    if not Hotbar.actions[action.id] then
        table.insert(Hotbar.actionOrder, action.id)
    end
    if action.category == "windows" then action.opensWindow = true end
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

--- A slot's parts in the order they run: the slot itself, then its steps. A step has
-- the same shape as a slot (action, settings, window), so everything that reads a
-- slot's action and settings reads a step the same way.
function Hotbar.partsOf(slot)
    local parts = { slot }
    for _, step in ipairs(slot.steps or {}) do
        table.insert(parts, step)
    end
    return parts
end

--- How a toggle step follows the first part (step.follow) while the slot syncs: nil
-- flips it from its own state (independent), FOLLOW_SAME turns it to the first
-- part's state, FOLLOW_OPPOSITE to the other one.
local FOLLOW_SAME = "same"
local FOLLOW_OPPOSITE = "opposite"

function Hotbar.followOf(step)
    if step.follow == FOLLOW_SAME or step.follow == FOLLOW_OPPOSITE then return step.follow end
    return nil
end

--- A slot's "On click" (slot.syncMode, see "Using a slot"): nil flips every part from
-- its own state, SYNC_UPDATE flips the first part and turns the following steps to its
-- new state, SYNC_ONLY leaves the first part and turns them to its current state.
-- Flip each is saved as SYNC_FLIP, and syncModeOf gives nil for it.
local SYNC_FLIP = "flip"
local SYNC_UPDATE = "update"
local SYNC_ONLY = "only"

function Hotbar.syncModeOf(slot)
    if slot.syncMode == SYNC_UPDATE or slot.syncMode == SYNC_ONLY then return slot.syncMode end
    return nil
end

--- A step's wait in milliseconds after the part before it; 0 runs it in the same frame.
function Hotbar.stepDelay(step)
    local delay = tonumber(step.delay) or STEP_DELAY_MS
    return math.max(0, math.min(STEP_DELAY_MAX_MS, math.floor(delay)))
end

--- A slot's "Repeat" (slot.repeatMode, see "Repeating a slot"): nil runs it once per
-- click, REPEAT_CLICK runs it again and again until it is clicked again, REPEAT_HOLD
-- while its mouse button or key is held.
local REPEAT_CLICK = "click"
local REPEAT_HOLD = "hold"

function Hotbar.repeatModeOf(slot)
    if slot.repeatMode == REPEAT_CLICK or slot.repeatMode == REPEAT_HOLD then return slot.repeatMode end
    return nil
end

--- A repeating slot's interval in milliseconds, at least REPEAT_MIN_MS.
function Hotbar.repeatInterval(slot)
    local interval = tonumber(slot.repeatMs) or REPEAT_MS
    return math.max(REPEAT_MIN_MS, math.min(REPEAT_MAX_MS, math.floor(interval)))
end

--- How many times a repeating slot runs per click or hold; 0 = until stopped.
function Hotbar.repeatTimes(slot)
    return math.max(0, math.floor(tonumber(slot.repeatTimes) or 0))
end

--- "Ask before running" when the slot does not say: if any part's action asks.
function Hotbar.defaultConfirm(slot)
    for _, part in ipairs(Hotbar.partsOf(slot)) do
        local action = Hotbar.getAction(part.action)
        if action and action.confirm == true then return true end
    end
    return false
end

-- State ------------------------------------------------------------------------

local DEFAULT_SLOTS = {
    "power:GodMod", "power:Invisible", "power:NoClip", "power:FastMove", "power:TimedActionInstant",
    "teleport.ui", "window:ITEMLIST", "window:MINISCOREBOARD", "window:CHECKSTATS", "window:ADMINPANEL",
}

-- Single player has no scoreboard or admin panel (its buttons all need a role).
local DEFAULT_SLOTS_SP = {
    "power:GodMod", "power:Invisible", "power:NoClip", "power:FastMove", "power:TimedActionInstant",
    "teleport.ui", "window:ITEMLIST", "window:CLIMATE", "window:CHECKSTATS", "window:ADMINPOWER",
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
    for _, id in ipairs(isClient() and DEFAULT_SLOTS or DEFAULT_SLOTS_SP) do
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
    if not isClient() then
        return "ZomboidFixesB42_AdminHotbar_SinglePlayer.ini"
    end
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
            confirm = slot.confirm, window = slot.window, syncMode = slot.syncMode,
            repeatMode = Hotbar.repeatModeOf(slot), repeatMs = slot.repeatMs, repeatTimes = slot.repeatTimes,
        }, "", fields)
        flatten(slot.settings or {}, "s.", fields)
        -- steps.#1.action, steps.#1.settings.<key>, steps.#1.window...
        if slot.steps and #slot.steps > 0 then
            flatten({ steps = slot.steps }, "", fields)
        end
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
            local steps = nil
            if type(record.steps) == "table" then
                -- Numbered from 1; a step whose action no longer exists is dropped.
                local count = 0
                for index in pairs(record.steps) do
                    if type(index) == "number" and index > count then count = index end
                end
                for index = 1, count do
                    local step = record.steps[index]
                    if type(step) == "table" and Hotbar.getAction(step.action) then
                        steps = steps or {}
                        table.insert(steps, {
                            action = step.action,
                            settings = type(step.settings) == "table" and step.settings or {},
                            window = step.window == true,
                            delay = tonumber(step.delay),
                            follow = Hotbar.followOf(step),
                        })
                    end
                end
            end
            -- "flip" is kept (nil would read as a slot saved before "On click").
            local syncMode = Hotbar.syncModeOf(record)
            if record.syncMode == SYNC_FLIP then
                syncMode = SYNC_FLIP
            elseif syncMode == nil then
                -- Saved before "On click": following steps followed on every click.
                for _, step in ipairs(steps or {}) do
                    if step.follow then syncMode = SYNC_UPDATE end
                end
            end
            table.insert(state.slots, {
                action = record.action,
                label = record.label,
                icon = record.icon,
                tint = type(record.tint) == "table" and record.tint or nil,
                confirm = record.confirm,
                window = record.window == true,
                syncMode = syncMode,
                repeatMode = Hotbar.repeatModeOf(record),
                repeatMs = tonumber(record.repeatMs),
                repeatTimes = tonumber(record.repeatTimes),
                settings = type(record.s) == "table" and record.s or {},
                steps = steps,
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

--- Everyone the bar can offer: the last scoreboard answer, plus anyone loaded. In
-- single player, the local (split screen) players.
function Hotbar.playerChoices()
    local seen, list = {}, {}
    if not isClient() then
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            local name = Hotbar.nameOf(player)
            if name and not seen[name] then
                seen[name] = true
                table.insert(list, { username = name, display = name })
            end
        end
        return list
    end
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
    local me = Hotbar.nameOf(admin)
    context:addOption(txt("Myself", me), me, onPick)
    for _, entry in ipairs(Hotbar.playerChoices()) do
        if entry.username ~= me then
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

--[[
    Square pickers. The cursor on the map is the cell's "drag" (IsoCell.setDrag, the
    name the game uses for any build or pick cursor, nothing to do with dragging the
    mouse). Vanilla's ISSelectCursor:create removes it before it reports the square,
    so a picker picks once; a picker that keeps picking replaces create and leaves the
    cursor up, and every further click picks again. Java calls the cursor's deactivate
    whenever it is removed or replaced (IsoCell.setDrag), which is where a picker ends:
    Esc (MainScreen.lua ToggleEscapeMenu removes the cursor), another cursor, death.

    Nothing in vanilla ends a pick cursor on right-click. It only seemed to because
    the right-click opens the world context menu (ISObjectClickHandler.doRClick ->
    ISContextManager.createWorldMenu -> ISWorldObjectContextMenu.createMenu), which
    removes the cursor on its way, so the menu opened as well. The bar's pickers end
    on the right button going down (OnRightMouseDown, only fired when no UI element
    took the click) and swallow the context menu that the same click would open on
    release (OnRightMouseUp, then OnObjectRightMouseButtonUp -> doRClick, in the same
    Java call, UIManager.updateMouseButtons).
--]]

--- The bar's picker currently on the map, if any.
local activePicker = nil
-- A right-click that ended a picker: "down" until the button is released, "up" for the
-- rest of that frame, so the context menu the release opens is not shown.
local eatRightClick = nil

--- Put a cursor on the map as the bar's own: right-click or Esc ends it (without the
-- context menu), and so does a second click on held.slot. held (optional) is the
-- table to track it in; onEnd() runs when the cursor goes, however it goes.
function Hotbar.holdCursor(admin, cursor, held, onEnd)
    held = held or {}
    held.cursor = cursor
    held.playerNum = admin:getPlayerNum()
    local previous = cursor.deactivate
    function cursor.deactivate(self)
        held.cursor = nil
        if activePicker == held then activePicker = nil end
        if previous then previous(self) end
        if onEnd then onEnd() end
    end
    getCell():setDrag(cursor, held.playerNum)
    activePicker = held
    return held
end

--- Pick a square on the map, the way the Horde Manager does. onPick(square) for the
-- square clicked. With keep, the picker stays up after each click and every further
-- click picks again, until right-click, Esc or another cursor ends it. onEnd() runs
-- when the picker goes, however it goes. Returns the picker.
-- ISSelectCursor calls ui:onSquareSelected(square) and only counts as valid while
-- ui.cursor is set.
function Hotbar.pickSquare(admin, onPick, keep, onEnd)
    local picker = { keep = keep == true }
    function picker.onSquareSelected(self, square)
        if not self.keep then self.cursor = nil end
        if square then onPick(square) end
    end
    local cursor = ISSelectCursor:new(admin, picker, nil)
    -- ISSelectCursor is a building cursor: ISBuildingObject:tryBuild walks the player to
    -- the square before "building" unless skipWalk2 is set (or the build cheat is on).
    cursor.skipWalk2 = true
    function cursor.create(self, x, y, z)
        if not picker.keep then getCell():setDrag(nil, self.player) end
        picker:onSquareSelected(getCell():getGridSquare(x, y, z))
    end
    Hotbar.holdCursor(admin, cursor, picker, onEnd)
    Hotbar.say(admin, txt(picker.keep and "PickSquaresHint" or "PickSquareHint"))
    return picker
end

--- Is this slot's cursor on the map right now?
function Hotbar.isHoldingFor(slot)
    return activePicker ~= nil and activePicker.slot == slot and activePicker.cursor ~= nil
end

--- End the bar's picker, if one is up.
function Hotbar.endPicking()
    local picker = activePicker
    if picker and picker.cursor and getCell():getDrag(picker.playerNum) == picker.cursor then
        getCell():setDrag(nil, picker.playerNum)
    end
end

local function onPickerRightMouseDown()
    eatRightClick = nil
    local picker = activePicker
    if not picker or not picker.cursor or getCell():getDrag(picker.playerNum) ~= picker.cursor then return end
    getCell():setDrag(nil, picker.playerNum)
    eatRightClick = "down"
end

local function onPickerRightMouseUp()
    if eatRightClick then eatRightClick = "up" end
end

local function onPickerTick()
    if eatRightClick == "up" then eatRightClick = nil end
end

--- ISObjectClickHandler lives in media/lua/server, which loads after client files.
local function installRightClickGuard()
    if not ISObjectClickHandler or not ISObjectClickHandler.doRClick or ISObjectClickHandler.zfixPickerGuard then return end
    local original = ISObjectClickHandler.doRClick
    ISObjectClickHandler.doRClick = function(object, x, y)
        if eatRightClick then
            eatRightClick = nil
            return
        end
        return original(object, x, y)
    end
    ISObjectClickHandler.zfixPickerGuard = true
end

Events.OnRightMouseDown.Add(onPickerRightMouseDown)
Events.OnRightMouseUp.Add(onPickerRightMouseUp)
Events.OnTick.Add(onPickerTick)
Events.OnGameStart.Add(installRightClickGuard)

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
-- location: "@me", "@pick", "@pickmany", "@player" (the slot's player) or "x,y,z"
-- vehicle:  "@near" (the one I'm in, else the nearest), "@pick" or "@pickmany"
-- tile:     a tile sprite name ("<tileset>_<n>"), or empty to choose one when used
--
-- "@pickmany" picks like "@pick", but the picker stays up and every click runs the
-- slot again (see Hotbar.activate).

local PICK_MANY = "@pickmany"

local function isPick(raw)
    return raw == "@pick" or raw == PICK_MANY
end

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
        if raw == "@me" then return Hotbar.nameOf(admin) end
        if raw == nil or raw == "@ask" or raw == "" then return nil end
        return raw
    elseif spec.type == "location" then
        if raw == "@me" then return positionOf(admin) end
        if raw == "@player" then
            local name = values[Hotbar.hasPlayerParam(Hotbar.getAction(slot.action)) or ""]
            local player = Hotbar.findPlayer(name)
            return player and positionOf(player) or nil
        end
        return Hotbar.parseCoords(raw)
    elseif spec.type == "vehicle" then
        if isPick(raw) then return nil end
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

--- Does clicking this slot ask for something (in any of its parts)?
function Hotbar.asksWhenUsed(slot)
    for _, part in ipairs(Hotbar.partsOf(slot)) do
        if Hotbar.partAsks(part) then return true end
    end
    return false
end

function Hotbar.partAsks(slot)
    local action = Hotbar.getAction(slot.action)
    if not action or slot.window then return false end
    for _, spec in ipairs(action.params) do
        local raw = settingOf(slot, spec)
        if spec.type == "player" and (raw == nil or raw == "@ask") and not spec.optional
                and (isClient() or getNumActivePlayers() > 1) then
            return true
        end
        if spec.type == "location" and (raw == nil or isPick(raw)) then return true end
        if spec.type == "vehicle" and isPick(raw) then return true end
        if (spec.type == "choice" or spec.type == "text" or spec.type == "number" or spec.type == "tile")
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

--- shared holds the player, square and vehicle already asked for during this click,
-- so a slot with steps asks for each of them once and every step uses the answer.
-- A slot that keeps picking also passes shared.memo (the answers to every other
-- question, per part, so later clicks ask nothing) and, for the pass that asks them
-- before the picker shows, shared.deferSquares (squares and vehicles left empty).
local function resolveOne(slot, action, spec, admin, values, done, shared)
    local raw = settingOf(slot, spec)
    local value = peekValue(slot, spec, admin, values)
    local memo = shared.memo and shared.memo[slot]
    if memo and memo[spec.key] ~= nil then return done(memo[spec.key]) end
    if shared.memo and (spec.type == "number" or spec.type == "text" or spec.type == "choice" or spec.type == "tile") then
        local answer = done
        done = function(v)
            shared.memo[slot] = shared.memo[slot] or {}
            shared.memo[slot][spec.key] = v
            answer(v)
        end
    end

    if spec.type == "player" then
        if value or spec.optional then return done(value) end
        if shared.player then return done(shared.player) end
        -- Nobody else to choose from (single player without split screen): no menu.
        if not isClient() and getNumActivePlayers() < 2 then return done(Hotbar.nameOf(admin)) end
        return Hotbar.pickPlayer(admin, function(name)
            shared.player = name
            done(name)
        end)
    elseif spec.type == "location" then
        if value then return done(value) end
        if raw == "@player" then
            Hotbar.say(admin, txt("PlayerNotLoaded"), true)
            return
        end
        if shared.location then return done(shared.location) end
        if shared.deferSquares then return done(nil) end
        return Hotbar.pickSquare(admin, function(square)
            shared.location = squareToLocation(square)
            done(shared.location)
        end)
    elseif spec.type == "vehicle" then
        if value then return done(value) end
        if not isPick(raw) then
            Hotbar.say(admin, txt("NoVehicleNear"), true)
            return
        end
        if shared.vehicle then return done(shared.vehicle) end
        if shared.deferSquares then return done(nil) end
        return Hotbar.pickSquare(admin, function(square)
            local vehicle = square:getVehicleContainer()
            if not vehicle then
                Hotbar.say(admin, txt("NoVehicleThere"), true)
                return
            end
            shared.vehicle = vehicle
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
    elseif spec.type == "tile" then
        if value or spec.optional or not Hotbar.Icons then return done(value) end
        return Hotbar.Icons.openTilePicker(nil, function(tile)
            if tile then done(tile) end
        end)
    end
    return done(value)
end

--- Resolve every setting of one slot or step, asking where needed, then call done(ctx).
local function resolve(slot, admin, done, shared)
    local action = Hotbar.getAction(slot.action)
    local values = {}
    local index = 0
    shared = shared or {}
    local function step()
        index = index + 1
        local spec = action.params[index]
        if not spec then
            return done({ admin = admin, slot = slot, action = action, values = values })
        end
        resolveOne(slot, action, spec, admin, values, function(value)
            values[spec.key] = value
            step()
        end, shared)
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

--- A slot can be used when every part can; the reason names the step that cannot.
function Hotbar.slotAvailability(slot, admin)
    for index, part in ipairs(Hotbar.partsOf(slot)) do
        local action = Hotbar.getAction(part.action)
        local ok, reason = Hotbar.availability(action, admin)
        if not ok then
            if index > 1 then
                reason = txt("StepUnavailable", string.format("%d", index), Hotbar.titleOf(action, part), reason or "")
            end
            return false, reason
        end
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
    local ok, reason = Hotbar.slotAvailability(slot, admin)
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

    -- Its cursor on the map (painting, or picking squares one after another): shown on.
    if Hotbar.isHoldingFor(slot) then
        state.toggle = true
        state.on = true
    end

    local pending = slot.pending
    if pending then
        if now > pending.untilMs or (pending.want ~= nil and state.on == pending.want) then
            slot.pending = nil
        else
            state.pending = true
        end
    end

    -- Repeating: shown on (not amber, though each run of a toggle leaves it pending).
    if Hotbar.isRepeating(slot) then
        state.toggle = true
        state.on = true
        state.pending = nil
        state.repeating = true
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

-- Windows a slot opened ---------------------------------------------------------------

--[[
    Clicking a slot whose action opened a window closes that window again. Which
    window an action opens is not known up front: vanilla's own handlers create it,
    and UIManager.AddUI only queues the element until the next UIManager.update, so it
    is not in UIManager.getUI() straight after the call. So the top-level UIs are
    listed before running, and the ones that become visible until WINDOW_WATCH_MS
    after the last part ran are remembered on the slot. Only actions marked opensWindow are
    watched: other UIs come and go by themselves, and some are not windows at all.
    Every forage, stash and world item icon is an ISBaseIcon (an ISPanel) added to
    the UIManager, and they appear as the player walks or teleports. Those icons,
    tooltips, context menus and Java-only elements are never taken for the window.

    Closing uses the window's own closeModal or close, what vanilla calls when it
    reopens a window (ISAdminPanelUI calls instance:close() / closeModal()). The base
    close of ISPanel, ISPanelJoypad and ISCollapsableWindow only hides, so a window
    still in the UIManager afterwards is hidden and removed, unless its class keeps
    it as the instance vanilla shows again.
--]]
local WINDOW_WATCH_MS = 1500
local IGNORED_UI = { ISToolTip = true, ISToolTipInv = true, ISContextMenu = true, ISBaseIcon = true }
local watchedSlots = {}

--- A UI table that could be the window: not one of the ignored classes, or derived
-- from one (derive sets each class's Type and chains them by metatable).
local function isWindowTable(window)
    local class = window
    while class do
        if IGNORED_UI[class.Type] then return false end
        class = getmetatable(class)
    end
    return true
end

local function isOpen(ui)
    return UIManager.getUI():contains(ui) and ui:isVisible() == true
end

local function openWindowsOf(slot)
    local open = {}
    for _, ui in ipairs(slot.openWindows or {}) do
        if isOpen(ui) then table.insert(open, ui) end
    end
    slot.openWindows = #open > 0 and open or nil
    return open
end

local function closeWindow(ui)
    local window = ui:getTable()
    if window.closeModal then
        window:closeModal()
    elseif window.close then
        window:close()
    end
    if UIManager.getUI():contains(ui) then
        if ui:isVisible() then ui:setVisible(false) end
        local class = getmetatable(window)
        if not (class and class.instance == window) then window:removeFromUIManager() end
    end
end

--- Close what this slot opened last time, if any of it is still open.
local function closeSlotWindows(slot)
    local open = openWindowsOf(slot)
    if #open == 0 then return false end
    for _, ui in ipairs(open) do closeWindow(ui) end
    slot.openWindows = nil
    return true
end

--- Start noting the windows that appear from now on, for WINDOW_WATCH_MS.
local function startWatch(slot)
    local before = {}
    local uis = UIManager.getUI()
    for i = 0, uis:size() - 1 do
        -- Only visible ones: a singleton window hidden by its close is shown again as is.
        local ui = uis:get(i)
        if ui:isVisible() == true then before[ui] = true end
    end
    watchedSlots[slot] = { before = before, untilMs = getTimestampMs() + WINDOW_WATCH_MS }
    slot.openWindows = nil
end

--- Keep watching for WINDOW_WATCH_MS after a later step runs.
local function extendWatch(slot)
    local watch = watchedSlots[slot]
    if watch then watch.untilMs = getTimestampMs() + WINDOW_WATCH_MS end
end

local function onWatchTick()
    local now = getTimestampMs()
    local uis = nil
    local done = {}
    for slot, watch in pairs(watchedSlots) do
        uis = uis or UIManager.getUI()
        for i = 0, uis:size() - 1 do
            local ui = uis:get(i)
            if not watch.before[ui] and ui:isVisible() == true then
                watch.before[ui] = true
                local window = ui:getTable()
                if window and isWindowTable(window) then
                    slot.openWindows = slot.openWindows or {}
                    table.insert(slot.openWindows, ui)
                end
            end
        end
        if now > watch.untilMs then table.insert(done, slot) end
    end
    for _, slot in ipairs(done) do watchedSlots[slot] = nil end
end

Events.OnTick.Add(onWatchTick)

-- Using a slot ---------------------------------------------------------------------

--[[
    A slot runs its own action, then each of its steps. Everything is worked out
    before the first part runs: the settings of every part are resolved in order, and
    a player, square or vehicle left on "Ask when used" is asked for once and shared
    by every part that asks for one (pick a square, then spawn a horde and make noise
    on it). "My position" is therefore where the admin stood when clicking, even after
    a teleport step. Then "Ask before running" is asked once for the whole slot, and
    each step runs its own delay after the part before it (STEP_DELAY_MS unless set):
    chat commands and client commands are separate packets, and a gap keeps them
    reaching the server in order. A delay of 0 runs the step straight after the part
    before it, in the same frame.

    How toggles turn is the slot's "On click" (slot.syncMode), with god mode as the
    first part and invisible as a step following it:
      - nil (flip each): every toggle flips from its own state. God mode off and
        invisible on become god mode on and invisible off.
      - SYNC_UPDATE: the first part flips and each following step turns to the state
        the first part asked for (or the opposite, step.follow), whatever it was
        before; a step already there is left alone. God mode off and invisible on
        become both on; both off become both on. That state is the one asked for at
        click time, not read back later, since the server confirms it after the step
        may already have run.
      - SYNC_ONLY: the first part does not run; each following step turns to the
        first part's current state. God mode off and invisible on become both off.
        Only the following steps run: independent toggle steps and steps that are no
        toggles are left out.
    A step set as independent (no step.follow) flips from its own state in every mode
    but SYNC_ONLY. When the first part is not a toggle, opens its window, or cannot
    tell its state (another player's flags this client has never seen, which
    set(ctx, nil) flips on the server), there is nothing to follow: SYNC_UPDATE steps
    flip from their own state and SYNC_ONLY runs nothing.
--]]
local scheduled = {}

local function after(ms, fn)
    table.insert(scheduled, { atMs = getTimestampMs() + ms, fn = fn })
end

local function onScheduleTick()
    if #scheduled == 0 then return end
    local now = getTimestampMs()
    local due = {}
    for i = #scheduled, 1, -1 do
        if scheduled[i].atMs <= now then
            table.insert(due, 1, scheduled[i])
            table.remove(scheduled, i)
        end
    end
    for _, item in ipairs(due) do item.fn() end
end

Events.OnTick.Add(onScheduleTick)

--- The state a following toggle step turns to, given lead (the state the first part
-- asked for); nil when it flips from its own state.
local function followedState(part, lead)
    local follow = Hotbar.followOf(part)
    if lead == nil or follow == nil then return nil end
    if follow == FOLLOW_SAME then return lead end
    return not lead
end

--- Run one resolved part and return the state a toggle asked for (nil when not a
-- toggle or unknown). Only the slot's own toggle shows as pending on the slot.
local function runResolved(ctx, owner, lead)
    local action = ctx.action
    if ctx.openWindow then
        action.openUI(ctx)
        return nil
    end
    if isToggle(action, ctx) then
        local current = action.toggle.isOn(ctx)
        local want = followedState(ctx.slot, lead)
        if want ~= nil then
            if current == want then return want end
        elseif current ~= nil then
            want = not current
        end
        action.toggle.set(ctx, want)
        if ctx.slot == owner then
            owner.pending = { want = want, untilMs = getTimestampMs() + PENDING_MS }
            Hotbar.invalidate(owner)
        end
        return want
    end
    if action.run then action.run(ctx) end
    return nil
end

--- Does running this part open a window a second click should close?
local function partOpensWindow(part)
    local action = Hotbar.getAction(part.action)
    if not action then return false end
    return (part.window and action.openUI ~= nil) or action.opensWindow == true
end

--- A toggle part that is not opening its window.
local function isTogglePart(ctx)
    return not ctx.openWindow and isToggle(ctx.action, ctx)
end

--- A following toggle part (a step that follows the first part, not opening its window).
local function isFollower(ctx)
    return isTogglePart(ctx) and Hotbar.followOf(ctx.slot) ~= nil
end

--- Run a slot's resolved parts; false when nothing could run. again: a repeat after
-- the first run, whose windows are not watched again.
local function runParts(slot, contexts, again)
    local parts = Hotbar.partsOf(slot)
    local mode = Hotbar.syncModeOf(slot)
    -- Sync only: the first part's current state, which the following steps turn to
    -- while the first part itself does not run.
    local syncLead = nil
    local first = contexts[1]
    if mode == SYNC_ONLY and first and isTogglePart(first) then
        local ok, current = pcall(first.action.toggle.isOn, first)
        if not ok or current == nil then
            Hotbar.say(first.admin, txt("SyncUnknown", Hotbar.titleOf(first.action, slot)), true)
            return false
        end
        syncLead = current
    end
    local watch = false
    if syncLead == nil and not again then
        for _, part in ipairs(parts) do
            if partOpensWindow(part) then watch = true end
        end
        if watch then startWatch(slot) end
    end
    local index = 0
    -- The state the first part asked for, which following steps turn to.
    local lead = syncLead
    local function runNext()
        -- Every step with no delay runs in this same call, so in the same frame.
        repeat
            index = index + 1
            local ctx = contexts[index]
            if not ctx then return end
            if watch then extendWatch(slot) end
            ctx.owner = slot
            if syncLead == nil then
                local want = runResolved(ctx, slot, lead)
                -- Only Update and sync hands the first part's new state on.
                if index == 1 and mode == SYNC_UPDATE then lead = want end
            elseif index > 1 and isFollower(ctx) then
                runResolved(ctx, slot, lead)
            end
        until not contexts[index + 1] or Hotbar.stepDelay(parts[index + 1]) > 0
        if contexts[index + 1] then
            after(Hotbar.stepDelay(parts[index + 1]), runNext)
        end
    end
    runNext()
    return true
end

--- Resolve every part in order (asking where needed), then done(contexts).
local function resolveParts(slot, admin, shared, done)
    local parts = Hotbar.partsOf(slot)
    local contexts = {}
    local function resolveAt(index)
        local part = parts[index]
        if not part then return done(contexts) end
        local action = Hotbar.getAction(part.action)
        if part.window and action.openUI then
            -- "Open the window instead": nothing to ask, the window takes it from here.
            local ctx = Hotbar.peek(part, admin)
            ctx.openWindow = true
            contexts[index] = ctx
            return resolveAt(index + 1)
        end
        resolve(part, admin, function(ctx)
            contexts[index] = ctx
            resolveAt(index + 1)
        end, shared)
    end
    resolveAt(1)
end

--- fn() now, or after "Ask before running" when the slot asks.
local function confirmThen(slot, fn)
    local wantsConfirm = slot.confirm
    if wantsConfirm == nil then wantsConfirm = Hotbar.defaultConfirm(slot) end
    if wantsConfirm then
        Hotbar.confirm(txt("ConfirmRun", Hotbar.slotTitle(slot)), fn)
    else
        fn()
    end
end

--- Does a part pick a square or vehicle and keep picking ("@pickmany")? Then so
-- does the whole slot.
function Hotbar.keepsPicking(slot)
    for _, part in ipairs(Hotbar.partsOf(slot)) do
        local action = Hotbar.getAction(part.action)
        if action and not (part.window and action.openUI) then
            for _, spec in ipairs(action.params) do
                if (spec.type == "location" or spec.type == "vehicle") and settingOf(part, spec) == PICK_MANY then
                    return true
                end
            end
        end
    end
    return false
end

--- Does a part pick a vehicle on the map?
local function picksVehicle(slot)
    for _, part in ipairs(Hotbar.partsOf(slot)) do
        local action = Hotbar.getAction(part.action)
        if action and not (part.window and action.openUI) then
            for _, spec in ipairs(action.params) do
                if spec.type == "vehicle" and isPick(settingOf(part, spec)) then return true end
            end
        end
    end
    return false
end

--[[
    A slot that keeps picking asks everything else first (players, numbers, lists,
    then "Ask before running"), once, with the squares left out. Then the picker stays
    on the map and each click runs the whole slot at the clicked square (and the
    vehicle on it, for a vehicle pick), with those answers, asking nothing more. Every
    square and vehicle the slot's parts pick is that click's. Right-click, Esc, or a
    second click on the slot ends it.
--]]
local function startPicking(slot, admin)
    local memo = {}
    local first = { memo = memo, deferSquares = true }
    resolveParts(slot, admin, first, function()
        confirmThen(slot, function()
            local picker = Hotbar.pickSquare(admin, function(square)
                if not Hotbar.canUse(admin) then return Hotbar.endPicking() end
                local ok, reason = Hotbar.slotAvailability(slot, admin)
                if not ok then
                    Hotbar.say(admin, reason, true)
                    return
                end
                local vehicle = nil
                if picksVehicle(slot) then
                    vehicle = square:getVehicleContainer()
                    if not vehicle then
                        Hotbar.say(admin, txt("NoVehicleThere"), true)
                        return
                    end
                end
                local shared = { memo = memo, player = first.player, location = squareToLocation(square), vehicle = vehicle }
                resolveParts(slot, admin, shared, function(contexts) runParts(slot, contexts) end)
            end, true)
            picker.slot = slot
        end)
    end)
end

--[[
    Repeating a slot (slot.repeatMode): one click (REPEAT_CLICK) or a press
    (REPEAT_HOLD) runs the whole slot, steps included, then again every
    repeatInterval milliseconds, until the slot is clicked again (or, held, its mouse
    button or key is let go), repeatTimes runs are done, or the slot can no longer
    be used. What is asked when used, and "Ask before running", is asked once, before
    the first run, and every later run uses the answers; everything else is read
    again for each run, so "My position" or "The vehicle I'm in" follow the admin. A
    run whose settings cannot be read any more (the player left, no vehicle near) ends
    the repeat, after the one message about it.

    Runs are checked once a frame (OnTick), so each lands on the first frame after
    its time, at most one a frame; after a stall longer than the interval the missed
    runs are dropped rather than caught up. The interval is at least REPEAT_MIN_MS:
    every run that sends something is its own packet, and a client drops its packets
    of one type beyond the server's MaxPacketsPerSecond (300 by default) in a second
    (PacketsCache.isLimitExceeded), silently.

    Held: the press starts it (OnKeyStartPressed for a key, the button's onMouseDown
    for the mouse), and the key's release (OnKeyPressed fires on release) or the
    mouse button's does nothing more. A slot that has to ask something or confirm
    first cannot know it is still held after the answer, so it repeats until clicked
    again instead. Dragging a held slot to move it ends the repeat as the drag
    begins. A slot that keeps picking squares already runs on every click on the map,
    and does that instead of repeating.
--]]
local repeating = {}
local repeatingCount = 0

function Hotbar.isRepeating(slot)
    return repeating[slot] ~= nil
end

--- Stop a slot's repeat, if it runs. quietly: no message.
function Hotbar.stopRepeat(slot, quietly)
    local rep = repeating[slot]
    if not rep then return end
    repeating[slot] = nil
    repeatingCount = repeatingCount - 1
    Hotbar.invalidate(slot)
    if not quietly and not rep.held then
        Hotbar.say(rep.admin, txt("RepeatStopped", string.format("%d", rep.runs)))
    end
end

--- Run a repeating slot once more with the answers of its first run; false when a
-- setting could not be read (resolveOne has said why) or nothing could run.
local function runRepeat(slot, rep)
    local shared = { memo = rep.memo, player = rep.shared.player, location = rep.shared.location, vehicle = rep.shared.vehicle }
    local contexts = nil
    -- Every answer is known, so this resolves in the same call or not at all.
    resolveParts(slot, rep.admin, shared, function(resolved) contexts = resolved end)
    if not contexts then return false end
    return runParts(slot, contexts, true)
end

--- held: a function telling whether the press that started it is still held, for a
-- held repeat; nil repeats until clicked again.
local function startRepeat(slot, admin, held)
    local memo = {}
    local shared = { memo = memo }
    local waiting = true
    resolveParts(slot, admin, shared, function(contexts)
        confirmThen(slot, function()
            -- Anything answered in a dialog or on the map is no longer the same press.
            local stillHeld = waiting and held or nil
            Hotbar.stopRepeat(slot, true)
            if not runParts(slot, contexts) then return end
            local rep = {
                admin = admin, memo = memo, shared = shared, held = stillHeld,
                interval = Hotbar.repeatInterval(slot), times = Hotbar.repeatTimes(slot),
                runs = 1,
            }
            rep.nextMs = getTimestampMs() + rep.interval
            if rep.times == 1 then return end
            repeating[slot] = rep
            repeatingCount = repeatingCount + 1
            Hotbar.invalidate(slot)
            if not stillHeld then
                Hotbar.say(admin, txt("RepeatStarted", string.format("%d", rep.interval)))
            end
        end)
    end)
    waiting = false
end

local function onRepeatTick()
    if repeatingCount <= 0 then return end
    local onBar = {}
    for _, slot in ipairs(Hotbar.state and Hotbar.state.slots or {}) do onBar[slot] = true end
    local now = getTimestampMs()
    local stops = {}
    for slot, rep in pairs(repeating) do
        local admin = rep.admin
        local stop = nil
        if not onBar[slot] or admin ~= getPlayer() or not Hotbar.canUse(admin) then
            stop = { quietly = true }
        elseif rep.held and not rep.held() then
            stop = { quietly = true }
        else
            local ok, reason = Hotbar.slotAvailability(slot, admin)
            if not ok then
                Hotbar.say(admin, reason, true)
                stop = {}
            end
        end
        if not stop and rep.nextMs <= now then
            if not runRepeat(slot, rep) then
                stop = {}
            else
                rep.runs = rep.runs + 1
                -- On schedule, unless a stall put it a whole interval behind.
                rep.nextMs = rep.nextMs + rep.interval
                if rep.nextMs <= now then rep.nextMs = now + rep.interval end
                if rep.times > 0 and rep.runs >= rep.times then stop = {} end
            end
        end
        if stop then
            stop.slot = slot
            table.insert(stops, stop)
        end
    end
    for _, stop in ipairs(stops) do Hotbar.stopRepeat(stop.slot, stop.quietly) end
end

Events.OnTick.Add(onRepeatTick)

--- Use a slot. held (optional): the slot was pressed rather than clicked, and
-- held() tells whether that press is still held (see "Repeating a slot").
function Hotbar.activate(slot, admin, held)
    admin = admin or getPlayer()
    if not admin or not Hotbar.canUse(admin) then return end
    -- A second click ends the slot's repeat or picking, or closes the window the first
    -- one opened.
    if Hotbar.isRepeating(slot) then return Hotbar.stopRepeat(slot) end
    if activePicker and activePicker.slot == slot then return Hotbar.endPicking() end
    if closeSlotWindows(slot) then return end
    local ok, reason = Hotbar.slotAvailability(slot, admin)
    if not ok then
        Hotbar.say(admin, reason, true)
        return
    end

    if Hotbar.keepsPicking(slot) then return startPicking(slot, admin) end
    local repeatMode = Hotbar.repeatModeOf(slot)
    if repeatMode then
        return startRepeat(slot, admin, repeatMode == REPEAT_HOLD and held or nil)
    end
    resolveParts(slot, admin, {}, function(contexts)
        confirmThen(slot, function() runParts(slot, contexts) end)
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
    Hotbar.stopRepeat(slot, true)
    for i, other in ipairs(state.slots) do
        if other == slot then
            table.remove(state.slots, i)
            break
        end
    end
    Hotbar.save()
    Hotbar.refreshBar()
end

--- Move a slot so it lands before the slot now at insertBefore (#slots + 1 = the end).
function Hotbar.moveSlotTo(slot, insertBefore)
    local slots = Hotbar.state.slots
    for i, other in ipairs(slots) do
        if other == slot then
            local target = insertBefore > i and insertBefore - 1 or insertBefore
            target = math.max(1, math.min(#slots, target))
            if target ~= i then
                table.remove(slots, i)
                table.insert(slots, target, slot)
                Hotbar.save()
                Hotbar.refreshBar()
            end
            return
        end
    end
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

    if self.bar.dragging == self then
        -- Its place while it is carried: an empty outline.
        self:drawRectBorder(0, 0, w, h, 0.6, 0.6, 0.6, 0.6)
        return
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
        self.tooltip = not self.bar.dragging and self.bar:tooltipFor(self.slot, state) or nil
    end
    self:updateTooltip()
end

function SlotButton:render()
    if self.bar.dragging == self then return end
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
    -- "+N": the slot also runs N steps after its own action; "R": it repeats.
    local right = self.width - 3
    local steps = self.slot.steps and #self.slot.steps or 0
    if steps > 0 then
        local text = "+" .. string.format("%d", steps)
        local textWidth = getTextManager():MeasureStringX(UIFont.Small, text)
        right = right - textWidth
        self:drawText(text, right, cell - FONT_HGT_SMALL - 1, 1, 0.85, 0.4, alpha, UIFont.Small)
    end
    if Hotbar.repeatModeOf(self.slot) then
        local textWidth = getTextManager():MeasureStringX(UIFont.Small, "R")
        self:drawText("R", right - textWidth - 1, cell - FONT_HGT_SMALL - 1, 0.55, 0.8, 1, alpha, UIFont.Small)
    end
    if self.keyText then
        self:drawText(self.keyText, 3, 1, 1, 1, 1, 0.8 * alpha, UIFont.Small)
    end
    if Hotbar.state.labels then
        local label = truncate(Hotbar.slotTitle(self.slot), self.width - 4, UIFont.Small)
        self:drawTextCentre(label, self.width / 2, cell, 0.95, 0.95, 0.95, alpha, UIFont.Small)
    end
end

-- Dragging a slot along the bar reorders it. A press only turns into a drag once the
-- mouse has moved this far, so an ordinary click still uses the slot.
local DRAG_THRESHOLD = 6

--- The slot's icon following the mouse while it is dragged. Top level so it draws over
-- everything, and deaf to the mouse so the drop lands on what is under it.
local DragGhost = ISPanel:derive("ZomboidFixesB42_AdminHotbarGhost")

function DragGhost:new(button)
    local o = ISPanel:new(getMouseX(), getMouseY(), button.bar.cell, button.bar.cell)
    setmetatable(o, self)
    self.__index = self
    o.button = button
    o.background = false
    return o
end

function DragGhost:prerender()
    self:setX(getMouseX() - self.width / 2)
    self:setY(getMouseY() - self.height / 2)
    self:drawRect(0, 0, self.width, self.height, 0.6, 0.07, 0.07, 0.07)
    self:drawRectBorder(0, 0, self.width, self.height, 0.9, 0.8, 0.8, 0.8)
    local texture = Hotbar.iconTexture(self.button.slot)
    if texture then
        local pad = math.max(3, math.floor(self.width / 10))
        local tint = self.button.slot.tint or { r = 1, g = 1, b = 1 }
        self:drawTextureScaledAspect(texture, pad, pad, self.width - pad * 2, self.height - pad * 2, 0.9, tint.r, tint.g, tint.b)
    end
end

local function mouseHeld()
    return isMouseButtonDown(0)
end

function SlotButton:onMouseDown(x, y)
    ISButton.onMouseDown(self, x, y)
    if self.slot then
        self.dragFrom = { x = getMouseX(), y = getMouseY() }
        -- Repeat while held: the press uses the slot, the release does not (onSlotClick).
        if Hotbar.repeatModeOf(self.slot) == REPEAT_HOLD then
            Hotbar.activate(self.slot, nil, mouseHeld)
        end
    end
end

function SlotButton:checkDrag()
    if not self.pressed or not self.dragFrom or self.bar.dragging then return end
    local moved = math.abs(getMouseX() - self.dragFrom.x) + math.abs(getMouseY() - self.dragFrom.y)
    if moved < DRAG_THRESHOLD then return end
    -- Moving a slot held to repeat ends the repeat the press started.
    local rep = repeating[self.slot]
    if rep and rep.held then Hotbar.stopRepeat(self.slot, true) end
    self.bar.dragging = self
    self:setCapture(true)
    local ghost = DragGhost:new(self)
    ghost:initialise()
    ghost:addToUIManager()
    ghost:setAlwaysOnTop(true)
    ghost:setWantMouseEvents(false)
    self.ghost = ghost
end

function SlotButton:onMouseMove(dx, dy)
    ISButton.onMouseMove(self, dx, dy)
    self:checkDrag()
end

function SlotButton:onMouseMoveOutside(dx, dy)
    ISButton.onMouseMoveOutside(self, dx, dy)
    self:checkDrag()
end

function SlotButton:endDrag()
    self:setCapture(false)
    self.pressed = false
    self.dragFrom = nil
    if self.ghost then
        self.ghost:removeFromUIManager()
        self.ghost = nil
    end
    local bar = self.bar
    bar.dragging = nil
    local target = bar:dropIndex()
    if target then Hotbar.moveSlotTo(self.slot, target) end
end

function SlotButton:onMouseUp(x, y)
    if self.bar.dragging == self then return self:endDrag() end
    self.dragFrom = nil
    return ISButton.onMouseUp(self, x, y)
end

function SlotButton:onMouseUpOutside(x, y)
    if self.bar.dragging == self then return self:endDrag() end
    self.dragFrom = nil
    return ISButton.onMouseUpOutside(self, x, y)
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
    o.mouseWasDown = {}
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
            button.keyText = Hotbar.slotKeyText(button.index)
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
    -- A slot that repeats while held was used when pressed (SlotButton:onMouseDown).
    if Hotbar.repeatModeOf(button.slot) == REPEAT_HOLD then return end
    Hotbar.activate(button.slot)
end

--- Where a dragged slot would land: the index of the slot it would go before, or
-- #slots + 1 for the end. nil when the mouse has left the bar (the drag is cancelled).
function Bar:dropIndex()
    local mx, my = getMouseX() - self:getAbsoluteX(), getMouseY() - self:getAbsoluteY()
    local margin = self.cell
    if mx < -margin or my < -margin or mx > self.width + margin or my > self.height + margin then
        return nil
    end
    local vertical = Hotbar.state.vertical
    local along = vertical and my or mx
    local count = #Hotbar.state.slots
    for _, button in ipairs(self.buttons) do
        if button.index then
            local middle = vertical and (button:getY() + button:getHeight() / 2) or (button:getX() + button:getWidth() / 2)
            if along < middle then return button.index end
        end
    end
    return count + 1
end

function Bar:drawDropMarker()
    local target = self:dropIndex()
    if not target then return end
    local vertical = Hotbar.state.vertical
    local on = Hotbar.state.on
    local position
    for _, button in ipairs(self.buttons) do
        if button.index == target then
            position = vertical and button:getY() or button:getX()
        end
    end
    if not position then
        -- The end: just after the last slot.
        local last = self.buttons[#self.buttons - 1]
        if not last then return end
        position = vertical and last:getBottom() + 3 or last:getRight() + 3
    end
    if vertical then
        self:drawRect(3, position - 3, self.width - 6, 3, 1, on.r, on.g, on.b)
    else
        self:drawRect(position - 3, 3, 3, self.height - 6, 1, on.r, on.g, on.b)
    end
end

function Bar:prerender()
    self:drawRect(0, 0, self.width, self.height, 0.55, 0, 0, 0)
    self:drawRectBorder(0, 0, self.width, self.height, 0.8, 0.35, 0.35, 0.35)
    if self.dragging then self:drawDropMarker() end
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

--- One line per setting of a slot or step, indented for a step.
local function settingLines(part, action, lines, indent)
    if part.window and action.openUI then
        table.insert(lines, indent .. txt("OpensWindow"))
        return
    end
    for _, spec in ipairs(action.params) do
        local summary = Hotbar.describeSetting(part, spec)
        if summary then table.insert(lines, indent .. spec.title .. ": " .. summary) end
    end
end

function Bar:tooltipFor(slot, state)
    local action = Hotbar.getAction(slot.action)
    local lines = { Hotbar.slotTitle(slot) }
    local steps = slot.steps or {}
    if action and action.tooltip and #steps == 0 then table.insert(lines, action.tooltip) end
    if action then
        if #steps > 0 then
            table.insert(lines, "1. " .. Hotbar.titleOf(action, slot))
            settingLines(slot, action, lines, "    ")
        else
            settingLines(slot, action, lines, "")
        end
    end
    for index, step in ipairs(steps) do
        local stepAction = Hotbar.getAction(step.action)
        if stepAction then
            local delay = Hotbar.stepDelay(step)
            local when = delay > 0 and txt("StepAfter", string.format("%d", delay)) or txt("StepAtOnce")
            local follow = stepAction.toggle and Hotbar.syncModeOf(slot) and Hotbar.followOf(step)
            if follow == FOLLOW_SAME then
                when = when .. " " .. txt("StepFollowsSame")
            elseif follow == FOLLOW_OPPOSITE then
                when = when .. " " .. txt("StepFollowsOpposite")
            end
            table.insert(lines, string.format("%d", index + 1) .. ". " .. Hotbar.titleOf(stepAction, step) .. " " .. when)
            settingLines(step, stepAction, lines, "    ")
        end
    end
    if #steps > 0 and Hotbar.asksWhenUsed(slot) then
        table.insert(lines, txt("StepsAskOnce"))
    end
    local syncMode = Hotbar.syncModeOf(slot)
    if syncMode and action and action.toggle and not slot.window then
        table.insert(lines, txt(syncMode == SYNC_ONLY and "SyncOnlyTooltip" or "SyncUpdateTooltip"))
    end
    local repeatMode = Hotbar.repeatModeOf(slot)
    if repeatMode and not Hotbar.keepsPicking(slot) then
        local interval = string.format("%d", Hotbar.repeatInterval(slot))
        local times = Hotbar.repeatTimes(slot)
        local key = repeatMode == REPEAT_HOLD and "RepeatHoldTooltip" or "RepeatClickTooltip"
        if times > 0 then key = key .. "Times" end
        table.insert(lines, txt(key, interval, string.format("%d", times)))
    end
    if state.repeating then
        local rep = repeating[slot]
        table.insert(lines, txt(rep and rep.held and "StateRepeatingHeld" or "StateRepeating",
            string.format("%d", rep and rep.runs or 0)))
    elseif state.toggle then
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
        if raw == PICK_MANY then return txt("SettingPickMany") end
        if raw == nil or raw == "@pick" then return txt("SettingPick") end
        return raw
    elseif spec.type == "vehicle" then
        if raw == PICK_MANY then return txt("SettingPickMany") end
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
    self:fillActionMenu(context, function(actionId) self:onAddAction(actionId, insertAt) end)
end

--- Every action by category; onPick(actionId) when one is chosen.
function Bar:fillActionMenu(context, onPick)
    local admin = getPlayer()
    for _, category in ipairs(Hotbar.categories) do
        local actions = sortedActions(category.id)
        if #actions > 0 then
            local option = context:addOption(category.title, nil, nil)
            local sub = ISContextMenu:getNew(context)
            context:addSubMenu(option, sub)
            for _, action in ipairs(actions) do
                local item = sub:addOption(Hotbar.titleOf(action, nil), action.id, onPick)
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
                s.syncMode = saved.syncMode
                s.repeatMode = saved.repeatMode
                s.repeatMs = saved.repeatMs
                s.repeatTimes = saved.repeatTimes
                s.pending = nil
                Hotbar.stopRepeat(s, true)
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
        self:addStepMenu(context, slot)
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

--- "Add a step" (any action, run after the slot's own) and, once there are steps,
-- "Steps" to edit, reorder or remove each of them.
function Bar:addStepMenu(context, slot)
    local addOption = context:addOption(txt("AddStep"), nil, nil)
    local addMenu = ISContextMenu:getNew(context)
    context:addSubMenu(addOption, addMenu)
    self:fillActionMenu(addMenu, function(actionId) Hotbar.addStep(slot, actionId) end)
    local tooltip = ISWorldObjectContextMenu.addToolTip()
    tooltip.description = txt("AddStepTooltip")
    addOption.toolTip = tooltip

    local steps = slot.steps or {}
    if #steps == 0 then return end
    local stepsOption = context:addOption(txt("Steps"), nil, nil)
    local stepsMenu = ISContextMenu:getNew(context)
    context:addSubMenu(stepsOption, stepsMenu)
    for index, step in ipairs(steps) do
        local title = string.format("%d", index + 1) .. ". " .. Hotbar.titleOf(Hotbar.getAction(step.action), step)
        local stepOption = stepsMenu:addOption(title, nil, nil)
        local stepMenu = ISContextMenu:getNew(stepsMenu)
        stepsMenu:addSubMenu(stepOption, stepMenu)
        stepMenu:addOption(txt("Edit"), step, function(s) Hotbar.editStep(slot, s) end)
        if index > 1 then
            stepMenu:addOption(txt("StepEarlier"), step, function(s) Hotbar.moveStep(slot, s, -1) end)
        end
        if index < #steps then
            stepMenu:addOption(txt("StepLater"), step, function(s) Hotbar.moveStep(slot, s, 1) end)
        end
        stepMenu:addOption(txt("Remove"), step, function(s) Hotbar.removeStep(slot, s) end)
    end
end

local function stepsChanged(slot)
    if slot.steps and #slot.steps == 0 then slot.steps = nil end
    slot.pending = nil
    Hotbar.invalidate(slot)
    Hotbar.save()
    Hotbar.refreshBar()
end

--- Add a step to a slot, through the settings dialog (every step has at least its delay).
function Hotbar.addStep(slot, actionId)
    local action = Hotbar.getAction(actionId)
    if not action then return end
    local step = { action = actionId, settings = {}, window = false, follow = FOLLOW_SAME }
    Hotbar.openSettings(step, function(saved)
        slot.steps = slot.steps or {}
        table.insert(slot.steps, {
            action = saved.action, settings = saved.settings or {}, window = saved.window == true, delay = saved.delay,
            follow = saved.follow,
        })
        stepsChanged(slot)
    end, slot)
end

function Hotbar.editStep(slot, step)
    Hotbar.openSettings(step, function(saved)
        step.settings = saved.settings or {}
        step.window = saved.window == true
        step.delay = saved.delay
        step.follow = saved.follow
        stepsChanged(slot)
    end, slot)
end

function Hotbar.moveStep(slot, step, delta)
    local steps = slot.steps or {}
    for i, other in ipairs(steps) do
        if other == step then
            local j = i + delta
            if j >= 1 and j <= #steps then
                steps[i], steps[j] = steps[j], steps[i]
                stepsChanged(slot)
            end
            return
        end
    end
end

function Hotbar.removeStep(slot, step)
    local steps = slot.steps or {}
    for i, other in ipairs(steps) do
        if other == step then
            table.remove(steps, i)
            stepsChanged(slot)
            return
        end
    end
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

--[[
    Focus. UIManager draws its top-level elements in list order and only moves one to
    the front when it asks (bringToTop -> UIManager.pushToTop, applied at the next
    UIManager.update). Many vanilla windows never ask on a click: ISInventoryPage's
    onMouseDown does not, and ISPanel only does when it is dragged. So whichever was
    created last stays in front, which is usually the bar, and a window clicked under
    it stays under it.

    So the bar gives the stack a focus rule of its own. On each left or right press,
    find what the press landed on, the way UIManager.updateMouseButtons walks the list
    (top first, visible elements, a collapsed window only as tall as its
    maxDrawHeight): if it is the bar, the bar comes to the front; if it is another
    window the bar is drawn over, that window comes to the front. Windows the bar is
    already under are left where they are, as are always-on-top elements, tooltips,
    context menus, world icons and anything covering the whole screen (a clear
    full-screen element would otherwise end up over the bar and take its clicks).
--]]
local FOCUS_BUTTONS = { 0, 1 }

local function landsOn(ui, mx, my)
    if not ui:isVisible() then return false end
    local x, y = ui:getX(), ui:getY()
    local height = ui:getHeight()
    local maxDraw = ui:getMaxDrawHeight()
    if maxDraw and maxDraw ~= -1 then height = math.min(height, maxDraw) end
    return mx >= x and my >= y and mx < x + ui:getWidth() and my < y + height
end

local function takesFocus(ui)
    if ui:isAlwaysOnTop() then return false end
    local core = getCore()
    if ui:getWidth() >= core:getScreenWidth() and ui:getHeight() >= core:getScreenHeight() then return false end
    local window = ui:getTable()
    return window == nil or isWindowTable(window)
end

function Bar:updateFocus()
    local pressed = false
    for _, btn in ipairs(FOCUS_BUTTONS) do
        local down = isMouseButtonDown(btn)
        if down and not self.mouseWasDown[btn] then pressed = true end
        self.mouseWasDown[btn] = down
    end
    if not pressed then return end

    local mx, my = getMouseX(), getMouseY()
    local uis = UIManager.getUI()
    local barAbove = false
    for i = uis:size() - 1, 0, -1 do
        local ui = uis:get(i)
        if ui == self.javaObject then
            if landsOn(ui, mx, my) then
                self:bringToTop()
                return
            end
            barAbove = true
        elseif landsOn(ui, mx, my) and takesFocus(ui) then
            if barAbove then ui:bringToTop() end
            return
        end
    end
end

function Bar:update()
    ISPanel.update(self)
    local admin = getPlayer()
    if not admin or not Hotbar.canUse(admin) then
        self:setVisible(false)
        return
    end
    self:updateFocus()

    local now = getTimestampMs()
    -- Key binds can change in the options screen at any time.
    if now - (self.lastKeys or 0) >= 1000 then
        self.lastKeys = now
        self:updateKeyTexts()
    end
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

local LABEL_WIDTH = 110
-- The control column: this much at 1920 wide and below, a quarter of wider screens, up to the max.
local CONTROL_WIDTH = 480
local CONTROL_WIDTH_MAX = 720
local HINT_COLOUR = { r = 0.8, g = 0.8, b = 0.8 }

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

--- owner: the dialog edits a step of that slot, which has settings, a delay and, for a
-- toggle, how it follows the first part (the label, icon and "Ask before running"
-- belong to the slot).
function Settings:new(slot, onSave, owner)
    -- The label column is as wide as its longest label, so no label runs under its control.
    local labelWidth = LABEL_WIDTH
    local labels = { txt("Label"), txt("Icon"), txt("OnClick"), txt("Repeat"), txt("RepeatEvery"),
        txt("RepeatTimes"), txt("StepToggle"), txt("StepDelay") }
    local action = Hotbar.getAction(slot.action)
    for _, spec in ipairs(action and action.params or {}) do table.insert(labels, spec.title) end
    local tm = getTextManager()
    for _, text in ipairs(labels) do
        labelWidth = math.max(labelWidth, tm:MeasureStringX(UIFont.Small, text) + 8)
    end
    local core = getCore()
    local controlWidth = math.floor(math.max(CONTROL_WIDTH, math.min(CONTROL_WIDTH_MAX, core:getScreenWidth() / 4)))
    local width = labelWidth + controlWidth + UI_BORDER_SPACING * 3
    local o = ISPanel:new(core:getScreenWidth() / 2 - width / 2, 120, width, 200)
    setmetatable(o, self)
    self.__index = self
    o.slot = slot
    o.owner = owner
    o.isStep = owner ~= nil
    o.action = action
    o.labelWidth = labelWidth
    o.controlWidth = controlWidth
    o.modeHints = {}
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

--- Grey (or colour's) small text wrapped over the dialog's width; returns the y below it.
function Settings:addHint(text, y, colour)
    colour = colour or HINT_COLOUR
    for _, line in ipairs(wrapLines(text, self.width - UI_BORDER_SPACING * 2 - 2, UIFont.Small)) do
        local label = ISLabel:new(UI_BORDER_SPACING + 1, y, FONT_HGT_SMALL, line, colour.r, colour.g, colour.b, 1, UIFont.Small, true)
        label:initialise()
        self:addChild(label)
        y = y + FONT_HGT_SMALL + 2
    end
    return y
end

--- Grey text on a control's row, to the right of it (a unit or a range).
function Settings:addSuffix(text, x, y)
    local label = ISLabel:new(x, y, BUTTON_HGT, text, HINT_COLOUR.r, HINT_COLOUR.g, HINT_COLOUR.b, 1, UIFont.Small, true)
    label:initialise()
    self:addChild(label)
    return label
end

--- A short hint under a combo that follows its selection (hints keyed by option data), with
-- the full explanation as a tooltip on the row's label and on the hint. The lines of the
-- longest hint are reserved so nothing below moves; returns the y below them.
function Settings:addModeHint(combo, hints, rowLabel, help, y, colour)
    colour = colour or HINT_COLOUR
    local width = self.width - UI_BORDER_SPACING * 2 - 2
    local lineCount = 1
    for _, text in pairs(hints) do
        lineCount = math.max(lineCount, #wrapLines(text, width, UIFont.Small))
    end
    local hint = { combo = combo, hints = hints, width = width, lines = {} }
    for i = 1, lineCount do
        local line = ISLabel:new(UI_BORDER_SPACING + 1, y, FONT_HGT_SMALL, "", colour.r, colour.g, colour.b, 1, UIFont.Small, true)
        line:initialise()
        line:setTooltip(help)
        self:addChild(line)
        hint.lines[i] = line
        y = y + FONT_HGT_SMALL + 2
    end
    rowLabel:setTooltip(help)
    table.insert(self.modeHints, hint)
    self:updateModeHint(hint)
    return y
end

--- Does a step of the slot follow its first part (a toggle, not opening its window, set
-- to Same or Opposite state)?
function Settings:hasFollowers()
    for _, step in ipairs(self.slot.steps or {}) do
        local action = Hotbar.getAction(step.action)
        if action and action.toggle and not step.window and Hotbar.followOf(step) then return true end
    end
    return false
end

function Settings:updateModeHint(hint)
    if hint.selected == hint.combo.selected then return end
    hint.selected = hint.combo.selected
    local text = hint.hints[hint.combo:getOptionData(hint.selected)] or ""
    local lines = wrapLines(text, hint.width, UIFont.Small)
    for i, line in ipairs(hint.lines) do line:setName(lines[i] or "") end
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
    local cx = UI_BORDER_SPACING * 2 + self.labelWidth
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

    if self.isStep then
        if action.toggle then
            local label = self:addLabel(txt("StepToggle"), y)
            self.followCombo = self:addCombo(cx, y, self.controlWidth, {
                { text = txt("StepToggleSame"), data = FOLLOW_SAME },
                { text = txt("StepToggleOpposite"), data = FOLLOW_OPPOSITE },
                { text = txt("StepToggleOwn"), data = "own" },
            }, Hotbar.followOf(self.slot) or "own")
            y = y + BUTTON_HGT + 2
            y = self:addModeHint(self.followCombo, {
                [FOLLOW_SAME] = txt("StepToggleSameHint"),
                [FOLLOW_OPPOSITE] = txt("StepToggleOppositeHint"),
                own = txt("StepToggleOwnHint"),
            }, label, txt("StepToggleHint"), y)
            local lead = Hotbar.getAction(self.owner.action)
            if not (lead and lead.toggle) or self.owner.window then
                y = self:addHint(txt("StepToggleNoLead"), y, AMBER)
            end
            y = y + UI_BORDER_SPACING
        end
        local delayLabel = self:addLabel(txt("StepDelay"), y)
        delayLabel:setTooltip(txt("StepDelayHint"))
        self.delayEntry = self:addEntry(cx, y, 100, string.format("%d", Hotbar.stepDelay(self.slot)), true)
        self:addSuffix(txt("StepDelayUnit"), cx + 110, y):setTooltip(txt("StepDelayHint"))
        y = y + BUTTON_HGT + UI_BORDER_SPACING * 2
        return self:addSaveCancel(y)
    end

    self:addLabel(txt("Label"), y)
    self.labelEntry = self:addEntry(cx, y, self.controlWidth, self.slot.label or "")
    self.labelEntry:setPlaceholderText(Hotbar.titleOf(action, self.slot))
    y = y + BUTTON_HGT + UI_BORDER_SPACING

    self:addLabel(txt("Icon"), y)
    -- As tall as the other buttons (addButton), twice as wide so the icon reads.
    local iconWidth = BUTTON_HGT * 2
    self.iconButton = self:addButton(cx, y, iconWidth, "", Settings.onIcon)
    self.iconButton.render = Settings.renderIconButton
    self.iconButton.settingsWindow = self
    self:addButton(cx + iconWidth + UI_BORDER_SPACING, y, 110, txt("IconDefault"), Settings.onIconDefault)
    y = y + BUTTON_HGT + UI_BORDER_SPACING * 2

    if action.toggle then
        local label = self:addLabel(txt("OnClick"), y)
        self.syncCombo = self:addCombo(cx, y, self.controlWidth, {
            { text = txt("OnClickFlip"), data = SYNC_FLIP },
            { text = txt("OnClickSyncUpdate"), data = SYNC_UPDATE },
            { text = txt("OnClickSyncOnly"), data = SYNC_ONLY },
        }, Hotbar.syncModeOf(self.slot) or SYNC_FLIP)
        y = y + BUTTON_HGT + 2
        y = self:addModeHint(self.syncCombo, {
            [SYNC_FLIP] = txt("OnClickFlipHint"),
            [SYNC_UPDATE] = txt("OnClickSyncUpdateHint"),
            [SYNC_ONLY] = txt("OnClickSyncOnlyHint"),
        }, label, txt("OnClickHint"), y)
        -- Steps saved before "Follow step 1" existed read as independent, which is
        -- easy to miss: say so while a mode that syncs is picked.
        if self.slot.steps and #self.slot.steps > 0 and not self:hasFollowers() then
            y = self:addModeHint(self.syncCombo, {
                [SYNC_UPDATE] = txt("OnClickNoFollowersUpdate"),
                [SYNC_ONLY] = txt("OnClickNoFollowersOnly"),
            }, label, txt("OnClickHint"), y, AMBER)
        end
        y = y + UI_BORDER_SPACING * 2
    end

    local repeatLabel = self:addLabel(txt("Repeat"), y)
    self.repeatCombo = self:addCombo(cx, y, self.controlWidth, {
        { text = txt("RepeatOff"), data = "off" },
        { text = txt("RepeatClick"), data = REPEAT_CLICK },
        { text = txt("RepeatHold"), data = REPEAT_HOLD },
    }, Hotbar.repeatModeOf(self.slot) or "off")
    y = y + BUTTON_HGT + 2
    y = self:addModeHint(self.repeatCombo, {
        off = txt("RepeatOffHint"),
        [REPEAT_CLICK] = txt("RepeatClickHint"),
        [REPEAT_HOLD] = txt("RepeatHoldHint"),
    }, repeatLabel, txt("RepeatHint"), y)
    y = y + 4
    -- Greyed out while Off (their values are kept for turning it on again, see prerender).
    self.repeatRow = {}
    table.insert(self.repeatRow, self:addLabel(txt("RepeatEvery"), y))
    self.repeatMsEntry = self:addEntry(cx, y, 100, string.format("%d", Hotbar.repeatInterval(self.slot)), true)
    table.insert(self.repeatRow, self:addSuffix(txt("RepeatEveryUnit"), cx + 110, y))
    y = y + BUTTON_HGT + 4
    table.insert(self.repeatRow, self:addLabel(txt("RepeatTimes"), y))
    self.repeatTimesEntry = self:addEntry(cx, y, 100, string.format("%d", Hotbar.repeatTimes(self.slot)), true)
    table.insert(self.repeatRow, self:addSuffix(txt("RepeatTimesUnit"), cx + 110, y))
    y = y + BUTTON_HGT + UI_BORDER_SPACING * 2

    local confirm = self.slot.confirm
    if confirm == nil then confirm = Hotbar.defaultConfirm(self.slot) end
    self.confirmTick = self:addTick(cx, y, self.controlWidth, txt("AskBeforeRunning"), confirm)
    y = y + BUTTON_HGT + UI_BORDER_SPACING * 2

    self:addSaveCancel(y)
end

function Settings:addSaveCancel(y)
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
        row.entry = self:addEntry(cx + 160, y, self.controlWidth - 160 - 40, mode == "name" and raw or "")
        row.pick = self:addButton(cx + self.controlWidth - 32, y, 32, "...", function()
            Hotbar.pickPlayer(getPlayer(), function(username)
                row.entry:setText(username)
                row.combo:selectData("name")
            end)
        end)
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "location" then
        local mode = raw
        if mode ~= "@me" and not isPick(mode) and mode ~= "@player" then
            mode = Hotbar.parseCoords(raw) and "fixed" or "@pick"
        end
        local options = {
            { text = txt("SettingMyPosition"), data = "@me" },
            { text = txt("SettingPick"), data = "@pick" },
            { text = txt("SettingPickMany"), data = PICK_MANY },
        }
        if Hotbar.hasPlayerParam(self.action) then
            table.insert(options, { text = txt("SettingPlayerPosition"), data = "@player" })
        end
        table.insert(options, { text = txt("SettingFixed"), data = "fixed" })
        row.combo = self:addCombo(cx, y, self.controlWidth, options, mode)
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
        row.combo = self:addCombo(cx, y, self.controlWidth, {
            { text = txt("SettingNearVehicle"), data = "@near" },
            { text = txt("SettingPick"), data = "@pick" },
            { text = txt("SettingPickMany"), data = PICK_MANY },
        }, isPick(raw) and raw or "@near")
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
        row.entry = self:addEntry(cx, y, self.controlWidth, raw or "")
        if spec.hint then row.entry:setPlaceholderText(spec.hint) end
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "bool" then
        row.tick = self:addTick(cx, y, self.controlWidth, spec.tickText or getText("IGUI_DebugMenu_Enabled"), raw == true)
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "choice" then
        local choices = Hotbar.choicesOf(spec)
        if spec.search or #choices > 30 then
            row.value = raw
            row.button = self:addButton(cx, y, self.controlWidth - 90, "", function()
                Hotbar.pickFromList(spec.title, Hotbar.choicesOf(spec), function(data)
                    row.value = data
                    row.button:setTitle(Hotbar.choiceText(spec, data))
                end)
            end)
            row.button:setTitle(raw ~= nil and Hotbar.choiceText(spec, raw) or (spec.optional and txt("SettingNone") or txt("SettingAsk")))
            self:addButton(cx + self.controlWidth - 80, y, 80, spec.optional and txt("Clear") or txt("SettingAskShort"), function()
                row.value = nil
                row.button:setTitle(spec.optional and txt("SettingNone") or txt("SettingAsk"))
            end)
        else
            local options = {}
            if not spec.noAsk then
                table.insert(options, { text = spec.optional and txt("SettingNone") or txt("SettingAsk"), data = nil })
            end
            for _, choice in ipairs(choices) do table.insert(options, choice) end
            row.combo = self:addCombo(cx, y, self.controlWidth, options, raw)
        end
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "tile" then
        row.value = raw ~= "" and raw or nil
        local function titleOf(value)
            return value or (spec.optional and txt("SettingNone") or txt("SettingAsk"))
        end
        row.button = self:addButton(cx, y, self.controlWidth - 90, titleOf(row.value), function()
            if not Hotbar.Icons then return end
            Hotbar.Icons.openTilePicker(row.value, function(tile)
                if not tile then return end
                row.value = tile
                row.button:setTitle(titleOf(tile))
            end)
        end)
        self:addButton(cx + self.controlWidth - 80, y, 80, spec.optional and txt("Clear") or txt("SettingAskShort"), function()
            row.value = nil
            row.button:setTitle(titleOf(nil))
        end)
        return y + BUTTON_HGT + UI_BORDER_SPACING

    elseif spec.type == "preset" then
        row.value = raw
        local summary = raw ~= nil and (spec.summary and spec.summary(raw) or txt("SettingPreset")) or txt("PresetNone")
        row.label = ISLabel:new(cx, y, BUTTON_HGT, summary, 0.85, 0.85, 0.85, 1, UIFont.Small, true)
        row.label:initialise()
        self:addChild(row.label)
        self:addButton(cx + self.controlWidth - 80, y, 80, txt("Clear"), function()
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
        elseif spec.type == "preset" or spec.type == "tile" then
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
    }
    if self.isStep then
        -- An empty entry keeps the default.
        local delay = tonumber(self.delayEntry:getText())
        if delay then slot.delay = Hotbar.stepDelay({ delay = delay }) end
        if self.followCombo then
            slot.follow = Hotbar.followOf({ follow = self.followCombo:getOptionData(self.followCombo.selected) })
        end
    else
        slot.icon = self.icon
        slot.tint = self.tint
        local label = string.trim(self.labelEntry:getText() or "")
        slot.label = label ~= "" and label or nil
        local confirm = self.confirmTick.selected[1] == true
        if confirm ~= Hotbar.defaultConfirm(self.slot) then
            slot.confirm = confirm
        end
        if self.syncCombo then
            slot.syncMode = self.syncCombo:getOptionData(self.syncCombo.selected)
        end
        slot.repeatMode = Hotbar.repeatModeOf({ repeatMode = self.repeatCombo:getOptionData(self.repeatCombo.selected) })
        -- Empty entries keep the defaults; kept while Off, for turning it on again.
        local interval = tonumber(self.repeatMsEntry:getText())
        if interval then slot.repeatMs = Hotbar.repeatInterval({ repeatMs = interval }) end
        local times = tonumber(self.repeatTimesEntry:getText())
        if times then slot.repeatTimes = Hotbar.repeatTimes({ repeatTimes = times }) end
    end
    self:close()
    self.onSave(slot)
end

function Settings:prerender()
    ISPanel.prerender(self)
    for _, hint in ipairs(self.modeHints) do self:updateModeHint(hint) end
    if self.repeatCombo then
        local on = self.repeatCombo:getOptionData(self.repeatCombo.selected) ~= "off"
        if on ~= self.repeatOn then
            self.repeatOn = on
            self.repeatMsEntry:setEditable(on)
            self.repeatTimesEntry:setEditable(on)
            for _, label in ipairs(self.repeatRow) do label.a = on and 1 or 0.4 end
        end
    end
    self:drawText(txt("SettingsTitle", Hotbar.titleOf(self.action, self.slot)), UI_BORDER_SPACING + 1, UI_BORDER_SPACING, 1, 1, 1, 1, UIFont.Medium)
end

function Settings:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

--- Open the settings dialog for a slot, or for a step of owner (new or existing).
-- onSave(slot) gets a new table.
function Hotbar.openSettings(slot, onSave, owner)
    local action = Hotbar.getAction(slot.action)
    if not action then return end
    local window = Settings:new(slot, onSave, owner)
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

-- The bar's own icon, drawn rather than shipped: a disc with three slots in a row,
-- green while the bar is shown, red while it is hidden. Outlined like the game's own
-- sidebar icons: a thin white line outside a black one, round the disc and each slot.
local SIDEBAR_ON = { r = 0.2, g = 0.65, b = 0.25 }
local SIDEBAR_OFF = { r = 0.7, g = 0.2, b = 0.2 }

--- A disc of diameter `size` centred on (cx, cy), with the white-outside-black outline.
local function outlinedDisc(element, tex, cx, cy, size, stroke, colour)
    local function disc(d, a, r, g, b)
        element:drawTextureScaled(tex, cx - d / 2, cy - d / 2, d, d, a, r, g, b)
    end
    disc(size + stroke * 4, 1, 1, 1, 1)
    disc(size + stroke * 2, 1, 0.05, 0.05, 0.05)
    disc(size, 1, colour.r, colour.g, colour.b)
end

local function renderSidebarButton(self)
    local tex = circle()
    local shown = Hotbar.isVisible()
    local colour = shown and SIDEBAR_ON or SIDEBAR_OFF
    local lift = self:isMouseOver() and 0.12 or 0
    local stroke = math.max(1, math.floor(math.min(self.width, self.height) / 40 + 0.5))
    local size = math.min(self.width, self.height) - 2 - stroke * 4
    local cx, cy = self.width / 2, self.height / 2
    if tex then
        outlinedDisc(self, tex, cx, cy, size, stroke, {
            r = math.min(1, colour.r + lift), g = math.min(1, colour.g + lift), b = math.min(1, colour.b + lift),
        })
    end
    local square = math.max(3, math.floor(size * 0.19))
    local gap = math.max(2, math.floor(size * 0.1)) + stroke
    local left = math.floor(cx - (square * 3 + gap * 2) / 2)
    local top = math.floor(cy - square / 2)
    for i = 0, 2 do
        local x = left + i * (square + gap)
        self:drawRect(x - stroke, top - stroke, square + stroke * 2, square + stroke * 2, 1, 0.05, 0.05, 0.05)
        self:drawRect(x, top, square, square, 1, 0.96, 0.96, 0.96)
    end

    -- A toggle still on while the bar is hidden: a small green dot, so cheats are not forgotten.
    local admin = getPlayer()
    if tex and admin and not shown and Hotbar.anyToggleOn(admin) then
        local dot = math.max(8, math.floor(self.width / 6))
        local half = dot / 2 + stroke * 2
        outlinedDisc(self, tex, self.width - half, half, dot, stroke, Hotbar.state.on)
    end
end

--- The bottom of the lowest sidebar button, the way ISEquippedItem:shrinkWrap measures.
local function lowestButtonBottom(sidebar)
    local bottom = 0
    for _, child in pairs(sidebar:getChildren()) do
        if child.Type == "ISButton" and child ~= sidebar.zomboidFixesHotbarBtn then
            bottom = math.max(bottom, child:getBottom())
        end
    end
    return bottom
end

local vanillaInitialise = ISEquippedItem.initialise

function ISEquippedItem:initialise()
    vanillaInitialise(self)
    -- Sized like the other sidebar buttons (vanilla's texture size is a file local).
    local model = self.adminBtn or self.healthBtn or self.invBtn
    if not model then return end
    -- Under the Admin button on a server; single player has none, so under the lowest button.
    local top = self.adminBtn and self.adminBtn:getBottom() or lowestButtonBottom(self)

    local button = ISButton:new(0, top + UI_BORDER_SPACING + 5,
        model:getWidth(), model:getHeight(), "", self, ISEquippedItem.onOptionMouseDown)
    button.internal = "ZOMBOIDFIXES_HOTBAR"
    button:initialise()
    button:instantiate()
    button:setDisplayBackground(false)
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.1 }
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

    local visible = Hotbar.canUse(self.chr)
    if self.adminBtn and not self.adminBtn:isVisible() then visible = false end
    button:setVisible(visible)
    if not visible then return end

    local bottom = button:getBottom()
    if self.adminBtn then
        button:setY(self.adminBtn:getBottom() + UI_BORDER_SPACING + 5)
        bottom = button:getBottom()
        if self.warManagerBtn and self.warManagerBtn:isVisible() then
            self.warManagerBtn:setY(bottom + UI_BORDER_SPACING)
            bottom = self.warManagerBtn:getBottom()
        end
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

--[[
    The keys are vanilla key bindings (Options > Key Bindings, in a section of their
    own), added the way the game adds its own: entries appended to the keyBinding
    table (shared/keyBinding.lua). MainOptions.loadKeys, run whenever the options
    screen is built, hands every entry to Core.addKeyBinding(name, key, altKey,
    shift, ctrl, alt) and restores it from keysB42.ini, which it also saves to, so a
    bind keeps its Shift / Ctrl / Alt, gets vanilla's duplicate check, and is tested
    with getCore():isKey(name, key). isKey applies vanilla's modifier rule
    (Core.invalidBindingShiftCtrl): a bind with a modifier only fires while it is
    held, and a bind without one steps aside when another bind on the same key
    matches the held modifiers exactly, so "Shift + 1" here no longer also picks
    item hotbar slot 1, and "1" no longer fires "Shift + 1".

    Not PZAPI.ModOptions key binds: those keep only the key code (the options
    screen shows "SHIFT + 1", but getValue() and ModOptions.ini have no modifiers,
    so the bind is really "1").
--]]

local KEY_SECTION = "[ZF Admin Hotbar]"
local KEY_TOGGLE = "ZF Admin Hotbar Toggle"

-- Short internal names: MainOptions sizes the label column by the widest bind name
-- (not its translation), and keysB42.ini is keyed by them.
local function slotKeyName(index)
    return "ZF Admin Hotbar Slot " .. string.format("%d", index)
end

-- keyBinding.lua (shared) is run again whenever Lua reloads, and so is this file.
local function addKeyBindings()
    for _, bind in ipairs(keyBinding) do
        if bind.value == KEY_SECTION then return end
    end
    table.insert(keyBinding, { value = KEY_SECTION })
    table.insert(keyBinding, { value = KEY_TOGGLE, key = 0 })
    for i = 1, SLOT_KEYS do
        table.insert(keyBinding, { value = slotKeyName(i), key = 0 })
    end
end

if keyBinding then addKeyBindings() end

--- The bind as MainOptions.loadKeys left it: { key, shift, ctrl, alt }, or nil.
local function bindOf(name)
    for _, bind in ipairs(MainOptions and MainOptions.keys or {}) do
        if bind.value == name then return bind end
    end
    return nil
end

function Hotbar.slotKey(index)
    return getCore():getKey(slotKeyName(index))
end

--- A slot's key as the bar shows it, with its modifiers ("S+1", "C+F2"), or nil.
function Hotbar.slotKeyText(index)
    local key = Hotbar.slotKey(index)
    if not key or key == 0 then return nil end
    local bind = bindOf(slotKeyName(index)) or {}
    local prefix = (bind.ctrl and "C+" or "") .. (bind.alt and "A+" or "") .. (bind.shift and "S+" or "")
    return prefix .. getKeyName(key)
end

local function onKeyPressed(key)
    if not key or key == 0 or not Hotbar.state then return end
    local admin = getPlayer()
    if not admin or not Hotbar.canUse(admin) then return end

    local core = getCore()
    if core:isKey(KEY_TOGGLE, key) then
        Hotbar.toggle()
        return
    end
    for i = 1, SLOT_KEYS do
        if core:isKey(slotKeyName(i), key) then
            local slot = Hotbar.state.slots[i]
            -- A slot that repeats while held was used when the key went down.
            if slot and Hotbar.repeatModeOf(slot) ~= REPEAT_HOLD then Hotbar.activate(slot, admin) end
            return
        end
    end
end

--- OnKeyPressed fires when a key is released (GameKeyboard.update), OnKeyStartPressed
-- when it goes down: a slot that repeats while held starts on the press.
local function onKeyStartPressed(key)
    if not key or key == 0 or not Hotbar.state then return end
    local admin = getPlayer()
    if not admin or not Hotbar.canUse(admin) then return end

    local core = getCore()
    for i = 1, SLOT_KEYS do
        if core:isKey(slotKeyName(i), key) then
            local slot = Hotbar.state.slots[i]
            if slot and Hotbar.repeatModeOf(slot) == REPEAT_HOLD then
                Hotbar.activate(slot, admin, function() return isKeyDown(key) end)
            end
            return
        end
    end
end

Events.OnKeyPressed.Add(onKeyPressed)
Events.OnKeyStartPressed.Add(onKeyStartPressed)

-- Start ------------------------------------------------------------------------------------------

local function onGameStart()
    -- The key bindings reach Core when the options screen is built; if it was built
    -- before this file added them (a Lua reload without a new screen), load them now.
    if MainOptions and MainOptions.loadKeys and not bindOf(KEY_TOGGLE) then
        MainOptions.loadKeys()
    end
    Hotbar.load()
    Hotbar.refreshBar()
end

Events.OnGameStart.Add(onGameStart)
