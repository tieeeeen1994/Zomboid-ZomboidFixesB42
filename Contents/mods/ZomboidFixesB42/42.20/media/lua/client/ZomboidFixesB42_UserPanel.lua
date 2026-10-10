--[[
    Zomboid Fixes B42.20 -- client, the User Panel's corner info choices are remembered

    The multiplayer User Panel (client/ISUI/UserPanel/ISUserPanelUI.lua, 42.21) has two
    tick boxes, Show connection info and Show server info. They call the Lua globals
    setShowConnectionInfo / setShowServerInfo, which only set two static fields of
    zombie/network/NetworkAIParams (both false when the game starts; its Init puts them
    back to false / true on connect with -debug). Nothing saves them, so they are gone
    after every restart of the game. ISVersionWaterMark's WaterMarkUI:render reads them
    (isShowServerInfo / isShowConnectionInfo) to draw the server time and ping line and
    the "name" (ip:port) line in the bottom right corner.

    The same corner always shows the game version (WaterMarkUI.revButton, a borderless
    button at the very bottom that copies the git revision when clicked) and, while the
    server option ShowCoordinates is on (or with -debug), a line with the player's
    x / y / z, the screen resolution and the frame rate. Neither can be turned off.

    So the choices are kept in Zomboid/Lua/ZomboidFixesB42_UserPanel.ini (one file for
    every server: it is a display preference) and the two Java flags are set again at
    OnGameStart. The panel gets two more tick boxes, Show game version and Show
    coordinates and resolution (the latter only while that line is drawn at all). The
    render is wrapped: the version button is hidden, the coordinates line is skipped,
    and every other line (server info, connection info, cheats, this mod's own lines
    from AdminPowersWatermark and AdminFullBright, both inside this wrapper) is drawn
    lower by the room they left, so the corner has no gap. Multiplayer only, like the
    panel itself.
--]]

require "ISUI/UserPanel/ISUserPanelUI"
require "ISUI/ISVersionWaterMark"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.UserPanelDisplay == true
end

local STATE_FILE = "ZomboidFixesB42_UserPanel.ini"
local KEYS = { "connection", "server", "version", "coordinates" }

-- Only what was ever chosen: a missing key leaves vanilla's behaviour.
local settings = {}

local function load()
    local reader = getFileReader(STATE_FILE, false)
    if not reader then return end
    while true do
        local line = reader:readLine()
        if not line then break end
        local key, value = string.match(line, "^(%a+)=(%a+)$")
        if key then settings[key] = value == "true" end
    end
    reader:close()
end

local function save()
    local writer = getFileWriter(STATE_FILE, true, false)
    for _, key in ipairs(KEYS) do
        if settings[key] ~= nil then
            writer:write(key .. "=" .. tostring(settings[key]) .. "\n")
        end
    end
    writer:close()
end

local function set(key, value)
    if not isEnabled() then return end
    value = value == true
    if settings[key] == value then return end
    settings[key] = value
    save()
end

load()

Events.OnGameStart.Add(function()
    if not isClient() or not isEnabled() then return end
    if settings.connection ~= nil then setShowConnectionInfo(settings.connection) end
    if settings.server ~= nil then setShowServerInfo(settings.server) end
end)

-- The panel: remember the two vanilla tick boxes, add the two new ones above Close.

local previousShowConnectionInfo = ISUserPanelUI.onShowConnectionInfo
function ISUserPanelUI:onShowConnectionInfo(option, enabled, ...)
    previousShowConnectionInfo(self, option, enabled, ...)
    set("connection", enabled)
end

local previousShowServerInfo = ISUserPanelUI.onShowServerInfo
function ISUserPanelUI:onShowServerInfo(option, enabled, ...)
    previousShowServerInfo(self, option, enabled, ...)
    set("server", enabled)
end

function ISUserPanelUI:zfixOnShowVersion(option, enabled)
    set("version", enabled)
end

function ISUserPanelUI:zfixOnShowCoordinates(option, enabled)
    set("coordinates", enabled)
end

-- Vanilla's condition for drawing the coordinates line (WaterMarkUI:render).
local function coordinatesShown()
    return isDebugEnabled() or (isClient() and getServerOptions():getBoolean("ShowCoordinates"))
end

local previousCreate = ISUserPanelUI.create
function ISUserPanelUI:create(...)
    previousCreate(self, ...)
    if not isEnabled() or not self.cancel or not self.showServerInfo then return end
    local spacing = self.cancel.y - self.showServerInfo:getBottom()
    local bottomMargin = self.height - self.cancel:getBottom()
    local x, y = self.showServerInfo.x, self.cancel.y
    local width = self.showServerInfo:getWidth()
    local height = self.showServerInfo:getHeight()

    local function addTickBox(textKey, selected, method)
        local text = getText(textKey)
        local box = ISTickBox:new(x, y, width, height, text, self, method)
        box:initialise()
        box:instantiate()
        box.selected[1] = selected
        box:addOption(text)
        self:addChild(box)
        y = y + box:getHeight() + spacing
        return box
    end

    self.zfixShowVersion = addTickBox("IGUI_ZomboidFixesB42_UserPanel_ShowVersion",
        settings.version ~= false, ISUserPanelUI.zfixOnShowVersion)
    if coordinatesShown() then
        self.zfixShowCoordinates = addTickBox("IGUI_ZomboidFixesB42_UserPanel_ShowCoordinates",
            settings.coordinates ~= false, ISUserPanelUI.zfixOnShowCoordinates)
    end

    self.cancel:setY(y)
    self:setHeight(self.cancel:getBottom() + bottomMargin)
    -- A longer label widens the panel and every child, as vanilla's create does.
    local widest = 0
    for _, child in pairs(self:getChildren()) do
        widest = math.max(widest, child:getWidth())
    end
    if widest > width then
        for _, child in pairs(self:getChildren()) do
            child:setWidth(widest)
        end
        self:setWidth(self.width + widest - width)
    end
end

-- The corner: hide the version and the coordinates line, close the gap they leave.

local STEP = getTextManager():getFontHeight(UIFont.NewSmall) + 3
local COORDINATES_LINE = "^x: %-?%d+ , y: %-?%d+, z: "

if WaterMarkUI then
    local innerRender = WaterMarkUI.render
    WaterMarkUI.render = function(self, ...)
        local active = isClient() and isEnabled()
        local hideVersion = active and settings.version == false
        local hideCoordinates = active and settings.coordinates == false
        if self.revButton and self.revButton:isVisible() == hideVersion then
            self.revButton:setVisible(not hideVersion)
        end
        if not hideVersion and not hideCoordinates then return innerRender(self, ...) end
        local shift = 0
        if hideVersion and self.revButton then shift = self.revButton:getHeight() end
        local outer = rawget(self, "drawTextRight")
        local drawTextRight = self.drawTextRight
        self.drawTextRight = function(panel, text, x, y, ...)
            if hideCoordinates and type(text) == "string" and string.find(text, COORDINATES_LINE) then
                -- Drawn first, so every later line moves down into its place.
                shift = shift + STEP
                return
            end
            return drawTextRight(panel, text, x, y + shift, ...)
        end
        local ok, err = pcall(innerRender, self, ...)
        self.drawTextRight = outer
        if not ok then error(err) end
    end
end
