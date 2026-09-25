--[[
    Zomboid Fixes B42.20 -- client, admin hotbar "Add to Hotbar"

    Settings too rich for a small form are taken from the vanilla window that
    already edits them: an "Add to Hotbar" button in each opens the hotbar's
    settings dialog filled in with what the window shows, and saving adds the slot.

      Item List           the selected item              -> Spawn item
      Spawn Vehicle       the selected vehicle           -> Spawn vehicle
      Horde Manager       count, radius, outfit, flags,
                          health and the picked square   -> Spawn horde
      Trigger Thunder     everyone, or the chosen player -> Thunder / Lightning
      Climate Control     the ticked overrides           -> Climate preset (a toggle)
      Weather tab         an event and its duration      -> Weather event
      Server Options      the selected option            -> Server option (a toggle
                                                            for true/false options)
      Teleport            the coordinates                -> Teleport to location
      Scoreboard          a player                       -> any player action
      Tools menu          the clicked square             -> teleport, noise, horde,
                                                            fire, explosion there

    The Body window's button lives in ZomboidFixesB42_BodyStats.lua.

    Each vanilla window is left as it is apart from the one button; where there was
    no room, its bottom buttons move down by one row.
--]]

if not isClient() then return end

require "ZomboidFixesB42_AdminHotbar"
require "ISUI/AdminPanel/ISItemsListTable"
require "ISUI/AdminPanel/ISMiniScoreboardUI"
require "ISUI/AdminPanel/ISServerOptions"
require "ISUI/AdminPanel/ISAdmPanelClimate"
require "ISUI/AdminPanel/ISAdmPanelWeather"
require "DebugUIs/ISSpawnVehicleUI"
require "DebugUIs/ISSpawnHordeUI"
require "DebugUIs/ISTriggerThunderUI"
require "DebugUIs/ISTeleportDebugUI"
require "DebugUIs/AdminContextMenu"

local Hotbar = ZomboidFixesB42.AdminHotbar
local txt = Hotbar.txt

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local UI_BORDER_SPACING = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6

local function canCapture()
    local player = getPlayer()
    return player ~= nil and Hotbar.canUse(player) and Hotbar.state ~= nil
end

local function captureButton(parent, x, y, width, onClick)
    local button = ISButton:new(x, y, width, BUTTON_HGT, txt("AddToHotbar"), parent, onClick)
    button:initialise()
    button:instantiate()
    button.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
    button.tooltip = txt("AddToHotbarTooltip")
    parent:addChild(button)
    return button
end

local function buttonWidth()
    return getTextManager():MeasureStringX(UIFont.Small, txt("AddToHotbar")) + UI_BORDER_SPACING * 2
end

--- Push the given buttons down one row and grow the window to match.
local function makeRoom(window, buttons)
    local delta = BUTTON_HGT + UI_BORDER_SPACING
    local top = nil
    for _, button in ipairs(buttons) do
        if button then
            top = top and math.min(top, button:getY()) or button:getY()
            button:setY(button:getY() + delta)
        end
    end
    window:setHeight(window:getHeight() + delta)
    return top
end

-- Item List --------------------------------------------------------------------------------

local vanillaItemsCreate = ISItemsListTable.createChildren

function ISItemsListTable:createChildren()
    vanillaItemsCreate(self)
    if not canCapture() or not self.buttonAddMultiple then return end
    local anchor = self.buttonAddMultiple
    self.zomboidFixesHotbarBtn = captureButton(self, anchor:getRight() + UI_BORDER_SPACING, anchor:getY(), buttonWidth(), function(list)
        local row = list.datas.items[list.datas.selected]
        local item = row and row.item
        if not item then return end
        Hotbar.capture("items.spawn", { item = item:getFullName(), count = 1, player = "@me" })
    end)
    self.zomboidFixesHotbarBtn.borderColor = self.buttonBorderColor
end

local vanillaItemsUpdate = ISItemsListTable.update

function ISItemsListTable:update()
    vanillaItemsUpdate(self)
    if self.zomboidFixesHotbarBtn then
        self.zomboidFixesHotbarBtn.enable = self.datas.items[self.datas.selected] ~= nil
    end
end

-- Spawn Vehicle -------------------------------------------------------------------------------

local vanillaVehicleInit = ISSpawnVehicleUI.initialise

function ISSpawnVehicleUI:initialise()
    vanillaVehicleInit(self)
    if not canCapture() or not self.spawn then return end
    local top = makeRoom(self, { self.getKey, self.repair, self.spawn, self.close })
    local width = self.close:getRight() - self.spawn:getX()
    captureButton(self, self.spawn:getX(), top, width, function(window)
        local script = window:getVehicle()
        if script then
            Hotbar.capture("vehicles.spawn", { vehicle = script, location = "@me" })
        end
    end)
end

-- Horde Manager -------------------------------------------------------------------------------

-- ISSpawnHordeUI's tick box order: knocked down, crawler, fake dead, fall on front,
-- invulnerable, sitting, recording, ragdoll, on fire.
local HORDE_TICKS = { knockedDown = 1, crawler = 2, fakeDead = 3, fallOnFront = 4, invulnerable = 5, sitting = 6, ragdoll = 8, onFire = 9 }

local vanillaHordeCreate = ISSpawnHordeUI.createChildren

function ISSpawnHordeUI:createChildren()
    vanillaHordeCreate(self)
    if not canCapture() or not self.pickNewSq then return end
    local anchor = self.pickNewSq
    local button = captureButton(self, anchor:getRight() + UI_BORDER_SPACING, anchor:getY(), buttonWidth(), function(window)
        local settings = {
            location = Hotbar.coordsText(window.selectX, window.selectY, window.selectZ),
            count = window:getZombiesNumber(),
            radius = window:getRadius(),
            health = window.healthSlider:getCurrentValue(),
            outfit = window:getOutfit(),
        }
        for key, index in pairs(HORDE_TICKS) do
            settings[key] = window.boolOptions.selected[index] == true
        end
        Hotbar.capture("zombies.horde", settings)
    end)
    if button:getRight() + UI_BORDER_SPACING + 1 > self.width then
        self:setWidth(button:getRight() + UI_BORDER_SPACING + 1)
    end
end

-- Trigger Thunder -------------------------------------------------------------------------------

local vanillaThunderCreate = ISTriggerThunderUI.createChildren

function ISTriggerThunderUI:createChildren()
    vanillaThunderCreate(self)
    if not canCapture() or not self.triggerThunder then return end
    local width = math.max(self.triggerThunder:getWidth(), buttonWidth())
    local button = captureButton(self, self.width / 2 - width / 2, self.triggerThunder:getBottom() + UI_BORDER_SPACING, width, function(window)
        if window.tickBox:isSelected(1) then
            Hotbar.capture("weather.thunderAll", {})
            return
        end
        local option = window.users.options[window.users.selected]
        local player = option and option.data
        if player then
            -- The window's own thunder strikes with a flash; /lightning is the command that does.
            Hotbar.capture("weather.lightning", { player = player:getUsername() })
        end
    end)
    if button:getBottom() + UI_BORDER_SPACING > self.height then
        self:setHeight(button:getBottom() + UI_BORDER_SPACING)
    end
end

-- Climate Control ---------------------------------------------------------------------------------

local function findChild(parent, customData)
    for _, child in pairs(parent:getChildren()) do
        if child.customData == customData then return child end
    end
    return nil
end

local vanillaClimateCreate = ISAdmPanelClimate.createChildren

function ISAdmPanelClimate:createChildren()
    vanillaClimateCreate(self)
    if not canCapture() then return end
    local apply = findChild(self, "Apply")
    if not apply then return end
    captureButton(self, apply:getX() - apply:getWidth() - UI_BORDER_SPACING, apply:getY(), apply:getWidth(), function(panel)
        local preset = Hotbar.captureClimate and Hotbar.captureClimate()
        if not preset then
            Hotbar.say(getPlayer(), txt("ClimateNothingTicked"), true)
            return
        end
        Hotbar.capture("weather.preset", { preset = preset })
    end)
end

local vanillaWeatherCreate = ISAdmPanelWeather.createChildren

function ISAdmPanelWeather:createChildren()
    vanillaWeatherCreate(self)
    if not canCapture() then return end
    local generate = findChild(self, "Generate")
    if not generate then return end
    local y = (self.totalY or generate:getBottom()) + UI_BORDER_SPACING
    local button = captureButton(self, generate:getX(), y, generate:getWidth(), function(panel)
        local hours = panel.sliderDurationSlider:getCurrentValue()
        local strength = panel.sliderCustomStrSlider:getCurrentValue()
        local front = panel.tickBoxFrontType.selected[2] and "cold" or "warm"
        local context = ISContextMenu.get(0, getMouseX(), getMouseY())
        local function event(kind)
            Hotbar.capture("weather.event", { kind = kind, hours = hours, strength = strength, front = front })
        end
        context:addOption(getText("IGUI_climate_TriggerStorm"), "storm", event)
        context:addOption(getText("IGUI_climate_TriggerTropical"), "tropical", event)
        context:addOption(getText("IGUI_climate_TriggerBlizzard"), "blizzard", event)
        context:addOption(getText("IGUI_climate_Generate"), "generate", event)
        context:addOption(getText("IGUI_climate_StopWeather"), nil, function() Hotbar.capture("weather.stop", {}) end)
    end)
    self:setScrollHeight(button:getBottom() + UI_BORDER_SPACING + 1)
end

-- Server Options ------------------------------------------------------------------------------------

local vanillaOptionsCreate = ISServerOptions.create

function ISServerOptions:create()
    vanillaOptionsCreate(self)
    if not canCapture() or not self.saveBtn then return end
    if not Hotbar.hasCapability(self.player, "ChangeAndReloadServerOptions") then return end
    local width = buttonWidth()
    self.zomboidFixesHotbarBtn = captureButton(self, self.width / 2 - width / 2, self.saveBtn:getY(), width, function(window)
        local row = window.datas.items[window.datas.selected]
        local option = row and row.item
        if not option then return end
        local settings = { option = option:getName() }
        if not instanceof(option, "BooleanConfigOption") then
            settings.value = option:getValueAsString()
        end
        Hotbar.capture("server.option", settings)
    end)
end

-- Teleport ---------------------------------------------------------------------------------------------

local vanillaTeleportInit = ISTeleportDebugUI.initialise

function ISTeleportDebugUI:initialise()
    vanillaTeleportInit(self)
    if not canCapture() or not self.yes then return end
    local top = makeRoom(self, { self.yes, self.no })
    local width = self.no:getRight() - self.yes:getX()
    captureButton(self, self.yes:getX(), top, width, function(window)
        local x = tonumber(window.entryX:getInternalText())
        local y = tonumber(window.entryY:getInternalText())
        local z = tonumber(window.entryZ:getInternalText()) or 0
        if x and y then
            Hotbar.capture("teleport.location", { location = Hotbar.coordsText(x, y, z) })
        end
    end)
end

-- Scoreboard ----------------------------------------------------------------------------------------------

local vanillaScoreboardMenu = ISMiniScoreboardUI.doPlayerListContextMenu

function ISMiniScoreboardUI:doPlayerListContextMenu(player, x, y)
    -- The menu is built inside vanilla's function and not returned, so ISContextMenu.get
    -- is watched for the duration of the call to catch it.
    local context
    local vanillaGet = ISContextMenu.get
    ISContextMenu.get = function(...)
        context = vanillaGet(...)
        return context
    end
    local ok, err = pcall(vanillaScoreboardMenu, self, player, x, y)
    ISContextMenu.get = vanillaGet
    if not ok then error(err) end

    if not context or not player or not player.username or not canCapture() then return end
    local option = context:addOption(txt("AddToHotbar"), nil, nil)
    local sub = ISContextMenu:getNew(context)
    context:addSubMenu(option, sub)
    for _, id in ipairs(Hotbar.actionOrder) do
        local action = Hotbar.actions[id]
        local key = Hotbar.hasPlayerParam(action)
        if key and not action.hidden and Hotbar.availability(action, self.admin) then
            sub:addOption(Hotbar.titleOf(action, nil), id, function(actionId)
                Hotbar.capture(actionId, { [key] = player.username })
            end)
        end
    end
end

-- Tools menu -------------------------------------------------------------------------------------------------

local SPOT_ACTIONS = {
    { id = "teleport.location", key = "SaveSpotTeleport" },
    { id = "noise.make", key = "SaveSpotNoise" },
    { id = "zombies.horde", key = "SaveSpotHorde" },
    { id = "zombies.add", key = "SaveSpotZombie" },
    { id = "noise.fire", key = "SaveSpotFire" },
    { id = "noise.explosion", key = "SaveSpotExplosion" },
}

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end
    if not canCapture() then return end

    local tools = context:getOptionFromName("Tools")
    local toolsMenu = tools and tools.subOption and context:getSubMenu(tools.subOption)
    if not toolsMenu then return end

    local square = nil
    for _, object in ipairs(worldobjects) do
        square = object:getSquare()
        if square then break end
    end
    if not square then return end

    local admin = getSpecificPlayer(playerNum)
    local coords = Hotbar.coordsText(square:getX(), square:getY(), square:getZ())
    local option = toolsMenu:addOption(txt("AddToHotbar"), nil, nil)
    local sub = toolsMenu:getNew(toolsMenu)
    toolsMenu:addSubMenu(option, sub)
    for _, spot in ipairs(SPOT_ACTIONS) do
        local action = Hotbar.getAction(spot.id)
        if action and Hotbar.availability(action, admin) then
            sub:addOption(txt(spot.key), spot.id, function(actionId)
                Hotbar.capture(actionId, { location = coords })
            end)
        end
    end
end

-- After AdminContextMenu's own handler, which builds the Tools menu: handlers run in
-- the order they were added, and the require above loads it first.
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
