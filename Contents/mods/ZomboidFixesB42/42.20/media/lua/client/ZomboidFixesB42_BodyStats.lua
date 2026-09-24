--[[
    Zomboid Fixes B42.20 -- client, body stats editor

    The debug menu's Body panel, for admins, without -debug, for any player. It has
    the same rows, ranges and steps, and opens from three places:

      - a Body button in the Player Stats window, next to Manage Inventory, for
        the player that window shows (the admin panel's "Check your Stats", the
        scoreboard's "Check Stats" and the world context menu all lead there);
      - an "Edit your Body Stats" button in the admin panel, for yourself;
      - a "Body Stats" entry in the mini scoreboard's right-click menu, which only
        needs the player's name, so it also works for players this client has
        never seen.

    In multiplayer nothing is read from or written to this client's copy of the
    player. Another player's stats never reach this client -- which is also why the
    Player Stats window shows made-up values for anyone but yourself -- and even
    your own would be overwritten by the server within a second. So the window asks
    the server for the values every second and sends each change to the server,
    which applies it to the real character (see the shared and server files).

    A slider being dragged changes many times a second. Changes are collected and
    sent at most every FLUSH_MS, and the dragged value is shown until the server
    confirms it, so the slider does not jump back while the reply is on its way.

    God mode and invisibility are sent as the server's own /godmodplayer and
    /invisibleplayer commands, the same ones the scoreboard uses, because only the
    server's commands can tell every client about them.

    In single player there is no server: the window reads and changes the
    character directly, the way the debug panel does. There it opens from the
    Player Stats window, which single player only offers in debug mode.
--]]

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTickBox"
require "ISUI/PlayerStats/ISPlayerStatsUI"
require "ISUI/AdminPanel/ISAdminPanelUI"
require "ISUI/AdminPanel/ISMiniScoreboardUI"
require "RadioCom/ISUIRadio/ISSliderPanel"
require "DebugUIs/DebugMenu/ISDebugUtils"
require "DebugUIs/DebugMenu/Base/ISDebugSubPanelBase"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local BodyStats = ZomboidFixesB42.BodyStats

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6
local SCROLL_BAR_WIDTH = 13
local SLIDER_WIDTH = 300

-- How often a dragged slider's value is sent, and how often the values are asked
-- for while the window is open.
local FLUSH_MS = 200
local REFRESH_MS = 1000
-- A change the server has not confirmed by then is dropped, and the window shows
-- the server's value again.
local PENDING_MS = 3000

-- Marks this connection's change numbers; see the server file.
local SESSION = getTimestampMs()
local seq = 0

-- Open windows, by the username they show.
local windows = {}

local function hasCapability(player, name)
    local role = player and player:getRole()
    local capability = name and Capability[name]
    return role ~= nil and capability ~= nil and role:hasCapability(capability)
end

local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

-- Window -----------------------------------------------------------------------

local BodyStatsWindow = ISPanel:derive("ZomboidFixesB42_BodyStatsWindow")

function BodyStatsWindow:new(x, y, width, height, admin, username, target)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.admin = admin
    o.username = username
    -- Only used in single player, where there is no server to ask.
    o.target = target
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.moveWithMouse = true
    o.values = nil
    o.pending = {}
    o.queue = {}
    o.queued = false
    o.lastReply = 0
    o.lastRequest = 0
    o.lastFlush = 0
    o.status = isClient() and getText("IGUI_ZomboidFixesB42_BodyStats_Waiting") or nil
    return o
end

function BodyStatsWindow:createChildren()
    ISPanel.createChildren(self)

    self.closeBtn = ISButton:new(self.width - UI_BORDER_SPACING - 101, UI_BORDER_SPACING + 1, 100, BUTTON_HGT,
        getText("UI_btn_close"), self, BodyStatsWindow.close)
    self.closeBtn:initialise()
    self.closeBtn:instantiate()
    self.closeBtn:enableCancelColor()
    self:addChild(self.closeBtn)

    -- The title, then a line for the status.
    local top = UI_BORDER_SPACING + 1 + FONT_HGT_MEDIUM + UI_BORDER_SPACING + FONT_HGT_SMALL + UI_BORDER_SPACING
    local list = ISDebugSubPanelBase:new(0, top, self.width, self.height - top, true)
    list:initialise()
    list:instantiate()
    list.moveWithMouse = true
    list:addScrollBars()
    list.vscroll:setVisible(true)
    self:addChild(list)
    list:setScrollChildren(true)
    list.onMouseWheel = ISDebugUtils.onMouseWheel
    self.list = list

    self:createRows()
end

--- The debug panel's layout: its two notes, then a label, value and slider per
-- number, then a tick box per flag.
function BodyStatsWindow:createRows()
    local list = self.list
    local x, y = UI_BORDER_SPACING + 1, UI_BORDER_SPACING + 1
    local w = list.width - UI_BORDER_SPACING * 2 - SCROLL_BAR_WIDTH - 1
    list:initHorzBars(x, w)

    local obj
    y, obj = ISDebugUtils.addLabel(list, "info", x + w / 2, y, getText("IGUI_StatsAndBody_MoraleInfo"), UIFont.Small)
    obj.center = true
    y, obj = ISDebugUtils.addLabel(list, "info", x + w / 2, y, getText("IGUI_StatsAndBody_PainInfo"), UIFont.Small)
    obj.center = true
    y = ISDebugUtils.addHorzBar(list, y + UI_BORDER_SPACING) + UI_BORDER_SPACING + 1

    self.rows = {}
    local controlX = x + (w - SLIDER_WIDTH)
    for _, field in ipairs(BodyStats.getFields()) do
        local row = { field = field }
        local y2
        y2, row.label = ISDebugUtils.addLabel(list, field, x, y, getText(field.title), UIFont.Small)

        if field.bool then
            local tickBox = ISTickBox:new(controlX, y, SLIDER_WIDTH, BUTTON_HGT, field.key, self, BodyStatsWindow.onTicked)
            tickBox.choicesColor = { r = 1, g = 1, b = 1, a = 1 }
            tickBox.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
            tickBox:initialise()
            tickBox:instantiate()
            tickBox.customData = field
            -- Added before addOption, as ISDebugUtils.addTickBox does, or the
            -- option is kept on screen as if the box were at the top of it.
            list:addChild(tickBox)
            tickBox:addOption(getText("IGUI_DebugMenu_Enabled"))
            row.tickBox = tickBox
            y = math.max(tickBox:getBottom(), y2)
        else
            local _, value = ISDebugUtils.addLabel(list, field, controlX - 20, y, "-", UIFont.Small, false)
            local slider = ISSliderPanel:new(controlX, y, SLIDER_WIDTH, BUTTON_HGT, self, BodyStatsWindow.onSliderChange)
            slider:initialise()
            slider:instantiate()
            slider.valueLabel = false
            slider.customData = field
            list:addChild(slider)
            slider:setValues(field.min, field.max, field.step, field.step, true)
            row.value = value
            row.slider = slider
            y = math.max(slider:getBottom(), y2)
        end

        y = ISDebugUtils.addHorzBar(list, y + UI_BORDER_SPACING) + UI_BORDER_SPACING + 1
        table.insert(self.rows, row)
    end

    list:setScrollHeight(y + 1)
end

function BodyStatsWindow:isEditable()
    if not isClient() then return self.target ~= nil and not self.target:isDead() end
    return self.values ~= nil and self.status == nil
end

--- What a field shows: the value being changed, until the server confirms it, or
-- else the server's.
function BodyStatsWindow:displayValue(key)
    local pending = self.pending[key]
    if pending then return pending.value end
    return self.values and self.values[key]
end

function BodyStatsWindow:prerender()
    ISPanel.prerender(self)

    if not isClient() and self.target then
        self.values = BodyStats.read(self.target)
    end

    local title = getText("IGUI_ZomboidFixesB42_BodyStats_Title", self.username)
    self:drawText(title, UI_BORDER_SPACING + 1, UI_BORDER_SPACING + 1, 1, 1, 1, 1, UIFont.Medium)
    if self.status then
        self:drawText(self.status, UI_BORDER_SPACING + 1, UI_BORDER_SPACING * 2 + 1 + FONT_HGT_MEDIUM, 0.9, 0.55, 0.1, 1, UIFont.Small)
    end

    local editable = self:isEditable()
    for _, row in ipairs(self.rows or {}) do
        local field = row.field
        local value = self:displayValue(field.key)
        if row.slider then
            if value ~= nil then
                -- Set directly, as the debug panel does: setCurrentValue would
                -- report it back as a change. Left alone while being dragged.
                if not row.slider.dragInside then
                    row.slider.currentValue = clamp(value, field.min, field.max)
                end
                row.value:setName(ISDebugUtils.printval(value, 3))
            else
                row.value:setName("-")
            end
            row.slider.disabled = not editable
        else
            row.tickBox.selected[1] = value == true
            row.tickBox.enable = editable and (not isClient() or not field.capability or hasCapability(self.admin, field.capability))
        end
    end
end

function BodyStatsWindow:onSliderChange(newValue, slider)
    self:change(slider.customData, newValue)
end

function BodyStatsWindow:onTicked(index, selected, arg1, arg2, tickBox)
    self:change(tickBox.customData, selected == true)
end

function BodyStatsWindow:change(field, value)
    if not field or not self:isEditable() then return end

    if not isClient() then
        BodyStats.apply(self.target, field.key, value)
        return
    end

    local now = getTimestampMs()
    if field.command then
        if not hasCapability(self.admin, field.capability) then return end
        SendCommandToServer(field.command .. " \"" .. self.username .. "\" " .. (value and "-true" or "-false"))
        -- Not answered through this window; the next refresh shows the result.
        self.pending[field.key] = { value = value, time = now }
        return
    end

    seq = seq + 1
    self.pending[field.key] = { value = value, seq = seq, time = now }
    self.queue[field.key] = { v = value, seq = seq }
    self.queued = true
end

function BodyStatsWindow:request()
    self.lastRequest = getTimestampMs()
    sendClientCommand(self.admin, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_BODY_STATS_REQUEST, {
        target = self.username,
    })
end

function BodyStatsWindow:flush()
    local now = getTimestampMs()
    self.lastFlush = now
    -- The reply to a change carries the values too, so it stands in for a refresh.
    self.lastRequest = now
    sendClientCommand(self.admin, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_BODY_STATS_SET, {
        target = self.username,
        session = SESSION,
        values = self.queue,
    })
    self.queue = {}
    self.queued = false
end

function BodyStatsWindow:update()
    ISPanel.update(self)
    if not isClient() then return end

    local now = getTimestampMs()
    if self.queued and now - self.lastFlush >= FLUSH_MS then
        self:flush()
    elseif now - self.lastRequest >= REFRESH_MS then
        self:request()
    end

    for key, pending in pairs(self.pending) do
        if now - pending.time >= PENDING_MS and not self.queue[key] then
            self.pending[key] = nil
        end
    end
end

local STATUS_TEXT = {
    offline = "IGUI_ZomboidFixesB42_BodyStats_Offline",
    dead = "IGUI_ZomboidFixesB42_BodyStats_Dead",
    denied = "IGUI_ZomboidFixesB42_BodyStats_Denied",
}

function BodyStatsWindow:onState(args)
    -- Replies are numbered by the server; one overtaken by a newer one is stale.
    local n = tonumber(args.n) or 0
    if n <= self.lastReply then return end
    self.lastReply = n

    if args.status ~= "ok" then
        self.status = getText(STATUS_TEXT[args.status] or STATUS_TEXT.denied, self.username)
        return
    end

    self.status = nil
    if type(args.values) == "table" then
        self.values = args.values
    end
    if type(args.acks) == "table" then
        for key, ackSeq in pairs(args.acks) do
            local pending = self.pending[key]
            if pending and pending.seq and pending.seq <= ackSeq then
                self.pending[key] = nil
            end
        end
    end
end

function BodyStatsWindow:close()
    self:setVisible(false)
    self:removeFromUIManager()
    if windows[self.username] == self then
        windows[self.username] = nil
    end
end

--- Open the editor for a player, or bring its window forward if it is already open.
-- target is the player object, needed in single player only.
function ZomboidFixesB42.openBodyStats(admin, username, target)
    if not admin or type(username) ~= "string" then return end

    local existing = windows[username]
    if existing then
        existing:setVisible(true)
        existing:bringToTop()
        return existing
    end

    local core = getCore()
    local width = 600 + core:getOptionFontSizeReal() * 50
    local height = math.min(700, core:getScreenHeight() - 100)
    local x = core:getScreenWidth() / 2 - width / 2
    local y = core:getScreenHeight() / 2 - height / 2

    local window = BodyStatsWindow:new(x, y, width, height, admin, username, target)
    window:initialise()
    window:addToUIManager()
    window:setVisible(true)
    windows[username] = window
    if isClient() then window:request() end
    return window
end

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_BODY_STATS_STATE then return end
    if type(args) ~= "table" then return end
    local window = windows[args.target]
    if window then window:onState(args) end
end

Events.OnServerCommand.Add(onServerCommand)

-- Player Stats window ----------------------------------------------------------

--- Whether this admin may open the editor from a window about this player. Single
-- player follows the Player Stats window's own rule for its edit buttons.
local function canOpenFrom(ui)
    if not isClient() then return getCore():getDebug() end
    return hasCapability(ui.admin, "CanModifyBodyStats") and ui:canModifyThis()
end

local vanillaStatsCreate = ISPlayerStatsUI.create

function ISPlayerStatsUI:create()
    vanillaStatsCreate(self)

    local title = getText("IGUI_ZomboidFixesB42_BodyStats_Button")
    local width = math.max(self.buttonWidth, getTextManager():MeasureStringX(UIFont.Small, title) + UI_BORDER_SPACING * 2)
    self.zomboidFixesBodyBtn = ISButton:new(0, 0, width, self.buttonHeight, title, self, ISPlayerStatsUI.onOptionMouseDown)
    self.zomboidFixesBodyBtn.internal = "ZOMBOIDFIXES_BODYSTATS"
    self.zomboidFixesBodyBtn:initialise()
    self.zomboidFixesBodyBtn:instantiate()
    self.zomboidFixesBodyBtn.borderColor = self.buttonBorderColor
    self.zomboidFixesBodyBtn.tooltip = getText("IGUI_ZomboidFixesB42_BodyStats_Tooltip")
    self.mainPanel:addChild(self.zomboidFixesBodyBtn)
end

local vanillaStatsRender = ISPlayerStatsUI.render

function ISPlayerStatsUI:render()
    vanillaStatsRender(self)
    -- render lays the window out every frame, so this follows Manage Inventory.
    local button = self.zomboidFixesBodyBtn
    if button and self.manageInvBtn then
        button:setX(self.manageInvBtn:getRight() + UI_BORDER_SPACING)
        button:setY(self.manageInvBtn:getY())
    end
end

local vanillaStatsUpdateButtons = ISPlayerStatsUI.updateButtons

function ISPlayerStatsUI:updateButtons()
    vanillaStatsUpdateButtons(self)
    if self.zomboidFixesBodyBtn then
        self.zomboidFixesBodyBtn.enable = canOpenFrom(self)
    end
end

local vanillaStatsOnOptionMouseDown = ISPlayerStatsUI.onOptionMouseDown

function ISPlayerStatsUI:onOptionMouseDown(button, x, y)
    if button.internal == "ZOMBOIDFIXES_BODYSTATS" then
        if canOpenFrom(self) then
            ZomboidFixesB42.openBodyStats(self.admin, self.char:getUsername(), self.char)
        end
        return
    end
    return vanillaStatsOnOptionMouseDown(self, button, x, y)
end

-- Admin panel ------------------------------------------------------------------

local vanillaAdminCreate = ISAdminPanelUI.create

function ISAdminPanelUI:create()
    -- Added first, so that create's own sort puts it in the grid with the rest:
    -- create lays out every child it has at that point, alphabetically.
    self.zomboidFixesBodyBtn = ISButton:new(0, 0, 200, BUTTON_HGT, getText("IGUI_ZomboidFixesB42_BodyStats_AdminButton"), self, ISAdminPanelUI.onOptionMouseDown)
    self.zomboidFixesBodyBtn.internal = "ZOMBOIDFIXES_BODYSTATS"
    self.zomboidFixesBodyBtn:initialise()
    self.zomboidFixesBodyBtn:instantiate()
    self.zomboidFixesBodyBtn.borderColor = self.buttonBorderColor
    self.zomboidFixesBodyBtn.tooltip = getText("IGUI_ZomboidFixesB42_BodyStats_Tooltip")
    self:addChild(self.zomboidFixesBodyBtn)

    vanillaAdminCreate(self)
end

local vanillaAdminUpdateButtons = ISAdminPanelUI.updateButtons

function ISAdminPanelUI:updateButtons()
    vanillaAdminUpdateButtons(self)
    if self.zomboidFixesBodyBtn then
        self.zomboidFixesBodyBtn.enable = hasCapability(getPlayer(), "CanModifyBodyStats")
    end
end

local vanillaAdminOnOptionMouseDown = ISAdminPanelUI.onOptionMouseDown

function ISAdminPanelUI:onOptionMouseDown(button, x, y)
    if button.internal == "ZOMBOIDFIXES_BODYSTATS" then
        local player = getPlayer()
        if player and hasCapability(player, "CanModifyBodyStats") then
            ZomboidFixesB42.openBodyStats(player, player:getUsername(), player)
        end
        return
    end
    return vanillaAdminOnOptionMouseDown(self, button, x, y)
end

-- Mini scoreboard --------------------------------------------------------------

local vanillaScoreboardMenu = ISMiniScoreboardUI.doPlayerListContextMenu

function ISMiniScoreboardUI:doPlayerListContextMenu(player, x, y)
    -- The menu is built and shown inside vanilla's function and not returned, so
    -- ISContextMenu.get is watched for the duration of the call to catch it.
    local context
    local vanillaGet = ISContextMenu.get
    ISContextMenu.get = function(...)
        context = vanillaGet(...)
        return context
    end
    local ok, err = pcall(vanillaScoreboardMenu, self, player, x, y)
    ISContextMenu.get = vanillaGet
    if not ok then error(err) end

    if context and player and hasCapability(self.admin, "CanModifyBodyStats") then
        context:addOption(getText("IGUI_ZomboidFixesB42_BodyStats_ContextMenu"), self.admin,
            ZomboidFixesB42.openBodyStats, player.username)
    end
end
