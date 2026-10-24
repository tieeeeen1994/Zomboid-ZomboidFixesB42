--[[
    Zomboid Fixes B42.21 -- client, storm controls

    Adds a Storm tab to the admin Climate Control window (ISAdminWeather, opened
    from the admin panel, or from the debug menu in single player). Vanilla's
    Weather tab can only trigger a storm, tropical storm or blizzard of a given
    length: every one has strength 0.95 and comes from the same side, and its
    lightning goes wherever chance puts it. The server file explains the Java
    behind that and how the storm is built instead.

    ISAdminWeather:initialise registers its tabs (ISDebugPanelBase.registerPanel)
    and ISDebugPanelBase.createChildren builds them, sorted by title, so a tab
    registered after vanilla's initialise is built with the rest. The window is
    created once (ISDebugPanelBase.OnOpenPanel keeps ISAdminWeather.instance), so
    the tab follows the sandbox option as it was when the window first opened.

    The settings are sent to the server, which checks the ClimateManager
    capability (the window's own) and answers with a result shown under the Start
    button. In single player the window only opens in debug mode, and the tab
    calls the server file's Storm.start directly (sendServerCommand cannot answer
    there).

    Players to aim at come from scoreboardUpdate (OnScoreboardUpdate lists
    everyone online; getOnlinePlayers only holds the players this client has
    loaded), asked again each time the tab is shown.
--]]

require "DebugUIs/DebugMenu/Base/ISDebugSubPanelBase"
require "ISUI/AdminPanel/ISAdminWeather"

ZomboidFixesB42 = ZomboidFixesB42 or {}
-- shared/ZomboidFixesB42_Storm.lua has loaded already (shared loads before
-- client); a require of that name could find this file instead.
local Storm = ZomboidFixesB42.Storm

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6

local GOOD_COLOR = { r = 0.4, g = 0.9, b = 0.4 }
local BAD_COLOR = { r = 0.9, g = 0.4, b = 0.4 }
local PLAIN_COLOR = { r = 0.8, g = 0.8, b = 0.8 }

local RESULT_TEXT = {
    started = "IGUI_ZomboidFixesB42_Storm_Started",
    failed = "IGUI_ZomboidFixesB42_Storm_Failed",
    bad = "IGUI_ZomboidFixesB42_Storm_Failed",
    denied = "IGUI_ZomboidFixesB42_Storm_Denied",
    disabled = "IGUI_ZomboidFixesB42_Storm_Disabled",
}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.StormControls == true
end

local function canUse(player)
    if not player then return false end
    if not isClient() then return isDebugEnabled() end
    local role = player:getRole()
    return role ~= nil and role:hasCapability(Capability.ClimateManager)
end

local StormPanel = ISDebugSubPanelBase:derive("ZomboidFixesB42_StormPanel")

-- The panel on show, for the scoreboard and server replies.
local activePanel = nil

-- Building the tab -----------------------------------------------------------------

function StormPanel:addCombo(name, rowY, titleKey, tooltipKey)
    local _, label = ISDebugUtils.addLabel(self, name .. "Title", self.col0X, rowY + 2, getText(titleKey), UIFont.Small)
    label.tooltip = getText(tooltipKey)

    local combo = ISComboBox:new(self.col2X, rowY, self.colW - 10, BUTTON_HGT, self, nil)
    combo:initialise()
    self:addChild(combo)
    self[name] = combo
    return rowY + BUTTON_HGT + UI_BORDER_SPACING
end

--- A slider row. With optional set, its title is a tick box: unticked, the game
-- decides that setting as vanilla would.
function StormPanel:addSliderRow(name, rowY, titleKey, tooltipKey, min, max, step, value, format, optional)
    local tooltip = getText(tooltipKey)
    if optional then
        local options = { { text = getText(titleKey), ticked = false } }
        local _, tick = ISDebugUtils.addTickBox(self, name .. "Tick", self.col0X, rowY, self.colW, BUTTON_HGT, "", options, nil)
        tick.tooltip = tooltip
        self[name .. "Tick"] = tick
    else
        local _, label = ISDebugUtils.addLabel(self, name .. "Title", self.col0X, rowY + 2, getText(titleKey), UIFont.Small)
        label.tooltip = tooltip
    end

    local _, valueLabel = ISDebugUtils.addLabel(self, name .. "Value", self.col2X - 20, rowY + 2, "", UIFont.Small, false)
    local _, slider = ISDebugUtils.addSlider(self, name, self.col2X, rowY + (BUTTON_HGT / 2) - 9, self.colW - 10, 18, StormPanel.onSliderChange)
    slider.valueLabel = valueLabel
    slider.format = format
    slider:setValues(min, max, step, step)
    slider:setCurrentValue(value)
    self[name] = slider
    return rowY + BUTTON_HGT + UI_BORDER_SPACING
end

function StormPanel:createChildren()
    ISPanel.createChildren(self)

    local x = UI_BORDER_SPACING + 1
    local w = self.width - 40
    self.colW = w / 3
    self.col0X = UI_BORDER_SPACING
    self.col2X = UI_BORDER_SPACING + self.colW * 2
    self:initHorzBars(x, w)

    local rowY = ISDebugUtils.addLabel(self, "Info", x, UI_BORDER_SPACING + 1, getText("IGUI_ZomboidFixesB42_Storm_Info"), UIFont.Small)
    rowY = ISDebugUtils.addHorzBar(self, rowY + UI_BORDER_SPACING) + UI_BORDER_SPACING

    rowY = self:addCombo("typeCombo", rowY, "IGUI_ZomboidFixesB42_Storm_Type", "IGUI_ZomboidFixesB42_Storm_TypeTooltip")
    for _, def in ipairs(Storm.TYPES) do
        self.typeCombo:addOptionWithData(getText(def.textKey), def.id)
    end
    rowY = self:addCombo("fromCombo", rowY, "IGUI_ZomboidFixesB42_Storm_From", "IGUI_ZomboidFixesB42_Storm_FromTooltip")
    for _, def in ipairs(Storm.DIRECTIONS) do
        self.fromCombo:addOptionWithData(getText(def.textKey), def.id)
    end
    rowY = self:addCombo("overCombo", rowY, "IGUI_ZomboidFixesB42_Storm_Over", "IGUI_ZomboidFixesB42_Storm_OverTooltip")
    self:fillTargets({})
    rowY = self:addCombo("frontCombo", rowY, "IGUI_ZomboidFixesB42_Storm_Temperature", "IGUI_ZomboidFixesB42_Storm_TemperatureTooltip")
    self.frontCombo:addOptionWithData(getText("IGUI_ZomboidFixesB42_Storm_TemperatureDrops"), false)
    self.frontCombo:addOptionWithData(getText("IGUI_ZomboidFixesB42_Storm_TemperatureRises"), true)

    rowY = ISDebugUtils.addHorzBar(self, rowY) + UI_BORDER_SPACING
    rowY = self:addSliderRow("hoursSlider", rowY, "IGUI_ZomboidFixesB42_Storm_Hours", "IGUI_ZomboidFixesB42_Storm_HoursTooltip",
        Storm.HOURS_MIN, Storm.HOURS_MAX, 1, Storm.HOURS_DEFAULT, "IGUI_ZomboidFixesB42_Storm_HoursValue")
    rowY = self:addSliderRow("strengthSlider", rowY, "IGUI_ZomboidFixesB42_Storm_Strength", "IGUI_ZomboidFixesB42_Storm_StrengthTooltip",
        Storm.STRENGTH_MIN * 100, Storm.STRENGTH_MAX * 100, 1, Storm.STRENGTH_DEFAULT * 100, "IGUI_ZomboidFixesB42_Storm_PercentValue")

    rowY = ISDebugUtils.addHorzBar(self, rowY) + UI_BORDER_SPACING
    rowY = ISDebugUtils.addLabel(self, "OptionalInfo", x, rowY, getText("IGUI_ZomboidFixesB42_Storm_OptionalInfo"), UIFont.Small) + UI_BORDER_SPACING
    rowY = self:addSliderRow("cloudsSlider", rowY, "IGUI_ZomboidFixesB42_Storm_Clouds", "IGUI_ZomboidFixesB42_Storm_CloudsTooltip",
        Storm.CLOUDS_MIN, Storm.CLOUDS_MAX, 1, Storm.CLOUDS_DEFAULT, "IGUI_ZomboidFixesB42_Storm_CountValue", true)
    rowY = self:addSliderRow("widthSlider", rowY, "IGUI_ZomboidFixesB42_Storm_Width", "IGUI_ZomboidFixesB42_Storm_WidthTooltip",
        Storm.WIDTH_MIN, Storm.WIDTH_MAX, 500, Storm.WIDTH_DEFAULT, "IGUI_ZomboidFixesB42_Storm_TilesValue", true)
    rowY = self:addSliderRow("frequencySlider", rowY, "IGUI_ZomboidFixesB42_Storm_Frequency", "IGUI_ZomboidFixesB42_Storm_FrequencyTooltip",
        0, 100, 1, Storm.FREQUENCY_DEFAULT, "IGUI_ZomboidFixesB42_Storm_PercentValue", true)
    rowY = self:addSliderRow("lightningSlider", rowY, "IGUI_ZomboidFixesB42_Storm_Lightning", "IGUI_ZomboidFixesB42_Storm_LightningTooltip",
        0, 100, 1, Storm.LIGHTNING_DEFAULT, "IGUI_ZomboidFixesB42_Storm_PercentValue", true)
    rowY = self:addSliderRow("windSlider", rowY, "IGUI_ZomboidFixesB42_Storm_Wind", "IGUI_ZomboidFixesB42_Storm_WindTooltip",
        0, getClimateManager():getMaxWindspeedKph(), 1, Storm.WIND_KPH_DEFAULT, "IGUI_ZomboidFixesB42_Storm_KphValue", true)

    local options = { { text = getText("IGUI_ZomboidFixesB42_Storm_WindFromStorm"), ticked = true } }
    local _, tick = ISDebugUtils.addTickBox(self, "WindFromStormTick", self.col0X, rowY, self.colW * 2, BUTTON_HGT, "", options, nil)
    tick.tooltip = getText("IGUI_ZomboidFixesB42_Storm_WindFromStormTooltip")
    self.windFromStormTick = tick
    rowY = rowY + BUTTON_HGT + UI_BORDER_SPACING

    rowY = ISDebugUtils.addHorzBar(self, rowY) + UI_BORDER_SPACING
    local _, button = ISDebugUtils.addButton(self, "Start", self.col2X, rowY, self.colW - 10, BUTTON_HGT, getText("IGUI_ZomboidFixesB42_Storm_Start"), StormPanel.onClick)
    button.tooltip = getText("IGUI_ZomboidFixesB42_Storm_StartTooltip")
    local _, status = ISDebugUtils.addLabel(self, "Status", self.col2X - 20, rowY + 2, "", UIFont.Small, false)
    self.statusLabel = status
    rowY = rowY + BUTTON_HGT + UI_BORDER_SPACING

    self:setScrollHeight(rowY + UI_BORDER_SPACING)
    activePanel = self
end

--- Fills the Passes over list: the fixed choices, then each online player but
-- the admin. Keeps the choice made, if it is still there.
function StormPanel:fillTargets(players)
    local combo = self.overCombo
    local old = combo.options[combo.selected] and combo:getOptionData(combo.selected)
    combo:clear()

    combo:addOptionWithData(getText("IGUI_ZomboidFixesB42_Storm_OverRandomPlayer"), { over = "randomPlayer" })
    combo:addOptionWithData(getText("IGUI_ZomboidFixesB42_Storm_OverMe"), { over = "me" })
    combo:addOptionWithData(getText("IGUI_ZomboidFixesB42_Storm_OverAnywhere"), { over = "anywhere" })
    local me = getPlayer() and getPlayer():getUsername()
    for _, entry in ipairs(players) do
        if entry.username ~= me then
            combo:addOptionWithData(getText("IGUI_ZomboidFixesB42_Storm_OverPlayer", entry.name), { over = "player", username = entry.username })
        end
    end

    combo.selected = 1
    if old then
        for i = 1, #combo.options do
            local data = combo:getOptionData(i)
            if data.over == old.over and data.username == old.username then
                combo.selected = i
                break
            end
        end
    end
end

function StormPanel:onMadeActive()
    activePanel = self
    if isClient() then scoreboardUpdate() end
end

function StormPanel:prerender()
    ISDebugSubPanelBase.prerender(self)
    -- The tick boxes grey out the sliders they stand for.
    for _, name in ipairs({ "cloudsSlider", "widthSlider", "frequencySlider", "lightningSlider", "windSlider" }) do
        local on = self[name .. "Tick"].selected[1] == true
        self[name].disabled = not on
        self[name].valueLabel:setColor(on and 1 or 0.5, on and 1 or 0.5, on and 1 or 0.5)
    end
end

function StormPanel:onSliderChange(value, slider)
    if not slider.valueLabel or not slider.format then return end
    slider.valueLabel:setName(getText(slider.format, string.format("%d", math.floor(value + 0.5))))
end

-- Starting -------------------------------------------------------------------------

function StormPanel:optional(name, scale)
    if self[name .. "Tick"].selected[1] ~= true then return nil end
    return self[name]:getCurrentValue() / (scale or 1)
end

function StormPanel:collect()
    local target = self.overCombo:getOptionData(self.overCombo.selected) or { over = "randomPlayer" }
    return {
        type = self.typeCombo:getOptionData(self.typeCombo.selected),
        from = self.fromCombo:getOptionData(self.fromCombo.selected),
        over = target.over,
        username = target.username,
        coldFront = self.frontCombo:getOptionData(self.frontCombo.selected) == true,
        hours = self.hoursSlider:getCurrentValue(),
        strength = self.strengthSlider:getCurrentValue() / 100,
        clouds = self:optional("cloudsSlider"),
        width = self:optional("widthSlider"),
        frequency = self:optional("frequencySlider"),
        lightning = self:optional("lightningSlider"),
        windKph = self:optional("windSlider"),
        windFromStorm = self.windFromStormTick.selected[1] == true,
    }
end

function StormPanel:setStatus(textKey, color)
    self.statusLabel:setName(getText(textKey))
    self.statusLabel:setColor(color.r, color.g, color.b)
end

function StormPanel:showResult(result)
    self:setStatus(RESULT_TEXT[result] or "IGUI_ZomboidFixesB42_Storm_Failed", result == "started" and GOOD_COLOR or BAD_COLOR)
end

function StormPanel:onClick(button)
    if button.customData ~= "Start" then return end

    local player = getPlayer()
    if not isEnabled() then return self:showResult("disabled") end
    if not canUse(player) then return self:showResult("denied") end

    local args = self:collect()
    if isClient() then
        sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_STORM, args)
        self:setStatus("IGUI_ZomboidFixesB42_Storm_Sending", PLAIN_COLOR)
    elseif Storm.start then
        self:showResult(Storm.start(player, args))
    else
        self:showResult("failed")
    end
end

function StormPanel:new(x, y, width, height)
    local o = ISDebugSubPanelBase:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    return o
end

-- The window ------------------------------------------------------------------------

local vanillaInitialise = ISAdminWeather.initialise

function ISAdminWeather:initialise()
    vanillaInitialise(self)
    if isEnabled() and canUse(getPlayer()) then
        self:registerPanel(getText("IGUI_ZomboidFixesB42_Storm_Tab"), StormPanel)
    end
end

-- Events ----------------------------------------------------------------------------

local function onScoreboardUpdate(usernames, displayNames)
    if not activePanel or not activePanel:isReallyVisible() then return end
    local players = {}
    for i = 0, usernames:size() - 1 do
        local name = displayNames and displayNames:size() > i and displayNames:get(i) or usernames:get(i)
        table.insert(players, { username = usernames:get(i), name = name })
    end
    activePanel:fillTargets(players)
end

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_STORM_RESULT then return end
    if not activePanel or type(args) ~= "table" then return end
    activePanel:showResult(args.result)
end

Events.OnScoreboardUpdate.Add(onScoreboardUpdate)
Events.OnServerCommand.Add(onServerCommand)
