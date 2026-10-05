--[[
    Zomboid Fixes B42.20 -- client, admins look at a player's health, and heal a part
    without taking its treatment off

    Health button. Vanilla shows another player's health window only through a
    Medical Check: ISWorldObjectContextMenu.onMedicalCheck -> requestMedicalCheck,
    the patient gets a yes/no dialog (ISHealthPanel.ReceiveMedicalCheckRequest), and
    only on yes does ISMedicalCheckAction run, ending in perform(): ISHealthPanel:new
    (patient), setOtherPlayer(doctor), doctor:startReceivingBodyDamageUpdates
    (patient). Even an admin with Capability.CanMedicalCheat has to ask
    (canPerformMedicalCheck only skips the other checks). The asking is all in Lua:
    BodyDamageUpdatePacket (START_UPDATING) only needs LoginOnServer, and the
    server's BodyDamageSync then streams the patient's real body to the asker every
    0.5 s into the client's getBodyDamageRemote(), which the panel shows. So a Health
    button next to Body in the Player Stats window opens the same window the way
    perform() does, straight away. The client applies each update to its own copy
    of the patient (PlayerID lookup), so the patient has to be loaded on this client:
    the button is off for anyone it does not have (getPlayerByOnlineID).

    The open window then runs ISHealthPanel:update, which closes it when either
    player moves unless the doctor's role has CanMedicalCheat (the button needs it),
    and blanks it with "too far away" beyond 2 tiles unless ISHealthPanel.cheat (the
    Health cheat admin power) is on; for a window opened here that is held on for
    the duration of the update only.

    Heal, keep treatment. The health window's Cheat menu (ISHealthPanel.cheat) has
    Full Health for a part and for the body, which call BodyPart.RestoreToFullHealth:
    it also takes off the bandage, the poultices, the splint and the stitches. Two
    entries next to them heal every injury and leave those on (the body part
    condition "Healed" in shared/ZomboidFixesB42_BodyStats.lua). They go through the
    body stats editor's set command, so the server checks CanModifyBodyStats and the
    rank, logs it, and applies it to the real character without the patient's
    client having to pass it on (vanilla's own cheat for another player is relayed
    through the patient's client). The menu is built by doBodyPartContextMenu without
    returning it, so ISContextMenu.get is wrapped for the call to catch it.

    Both are part of the BodyStatsEditor sandbox option.
--]]

require "ISUI/PlayerStats/ISPlayerStatsUI"
require "ISUI/ISContextMenu"
require "XpSystem/ISUI/ISHealthPanel"
require "TimedActions/ISMedicalCheckAction"
require "ZomboidFixesB42_BodyStats"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local BodyStats = ZomboidFixesB42.BodyStats

local UI_BORDER_SPACING = 10

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.BodyStatsEditor == true
end

local function hasCapability(player, name)
    local role = player and player:getRole()
    return role ~= nil and Capability[name] ~= nil and role:hasCapability(Capability[name])
end

-- Health button ------------------------------------------------------------------

--- Whether the Player Stats window's viewer may open this player's health window.
local function canOpenHealth(ui)
    if not isEnabled() or not ui.char or not ui.admin then return false end
    -- Single player offers the Player Stats window in debug mode only.
    if not isClient() then return true end
    if ui.char:isLocalPlayer() then return true end
    if not hasCapability(ui.admin, "CanMedicalCheat") then return false end
    return getPlayerByOnlineID(ui.char:getOnlineID()) == ui.char
end

--- Open a player's health window for an admin, as ISMedicalCheckAction:perform does.
local function openHealth(admin, patient)
    local playerNum = admin:getPlayerNum()
    local x = getPlayerScreenLeft(playerNum) + 70
    local y = getPlayerScreenTop(playerNum) + 50

    local panel
    local window = ISMedicalCheckAction.getHealthWindowForPlayer(patient)
    if window then
        panel = window.nested
        window:removeFromUIManager()
    else
        panel = ISHealthPanel:new(patient, x, y, 400, 400)
        panel:initialise()
    end

    local name = patient:getDescriptor():getForename() .. " " .. patient:getDescriptor():getSurname()
    if isClient() then name = patient:getDisguisedDisplayName() end
    local wrap = panel:wrapInCollapsableWindow(getText("IGUI_health_playerHealth", name), false)
    wrap:addToUIManager()
    ISMedicalCheckAction.HealthWindows[patient] = wrap

    if patient ~= admin and not patient:isLocalPlayer() then
        panel.doctorLevel = admin:getPerkLevel(Perks.Doctor)
        panel:setOtherPlayer(admin)
        panel.zfixAdminView = true
        admin:startReceivingBodyDamageUpdates(patient)
    end
end

local vanillaStatsCreate = ISPlayerStatsUI.create

function ISPlayerStatsUI:create()
    vanillaStatsCreate(self)
    if not isEnabled() then return end

    local title = getText("IGUI_ZomboidFixesB42_Health_Button")
    local width = math.max(self.buttonWidth, getTextManager():MeasureStringX(UIFont.Small, title) + UI_BORDER_SPACING * 2)
    self.zomboidFixesHealthBtn = ISButton:new(0, 0, width, self.buttonHeight, title, self, ISPlayerStatsUI.onOptionMouseDown)
    self.zomboidFixesHealthBtn.internal = "ZOMBOIDFIXES_HEALTH"
    self.zomboidFixesHealthBtn:initialise()
    self.zomboidFixesHealthBtn:instantiate()
    self.zomboidFixesHealthBtn.borderColor = self.buttonBorderColor
    self.zomboidFixesHealthBtn.tooltip = getText("IGUI_ZomboidFixesB42_Health_Tooltip")
    self.mainPanel:addChild(self.zomboidFixesHealthBtn)
end

local vanillaStatsRender = ISPlayerStatsUI.render

function ISPlayerStatsUI:render()
    vanillaStatsRender(self)
    -- After Body (laid out by the body stats file's render, which runs inside this
    -- one), or after Manage Inventory when there is no Body button.
    local button = self.zomboidFixesHealthBtn
    local anchor = self.zomboidFixesBodyBtn or self.manageInvBtn
    if button and anchor then
        button:setX(anchor:getRight() + UI_BORDER_SPACING)
        button:setY(anchor:getY())
    end
end

local vanillaStatsUpdateButtons = ISPlayerStatsUI.updateButtons

function ISPlayerStatsUI:updateButtons()
    vanillaStatsUpdateButtons(self)
    if self.zomboidFixesHealthBtn then
        self.zomboidFixesHealthBtn.enable = canOpenHealth(self)
    end
end

local vanillaStatsOnOptionMouseDown = ISPlayerStatsUI.onOptionMouseDown

function ISPlayerStatsUI:onOptionMouseDown(button, x, y)
    if button.internal == "ZOMBOIDFIXES_HEALTH" then
        if canOpenHealth(self) then openHealth(self.admin, self.char) end
        return
    end
    return vanillaStatsOnOptionMouseDown(self, button, x, y)
end

local vanillaPanelUpdate = ISHealthPanel.update

function ISHealthPanel:update()
    if not self.zfixAdminView then return vanillaPanelUpdate(self) end
    local cheat = ISHealthPanel.cheat
    ISHealthPanel.cheat = true
    local ok, err = pcall(vanillaPanelUpdate, self)
    ISHealthPanel.cheat = cheat
    if not ok then error(err) end
end

-- Heal, keep treatment ------------------------------------------------------------

--- The local player working the panel: the doctor for someone else's window.
local function adminOf(panel)
    return panel.otherPlayer or panel.character
end

local function canHeal(panel)
    if not isEnabled() or not BodyStats or not ZomboidFixesB42.sendBodyStats then return false end
    if not isClient() then return true end
    return hasCapability(adminOf(panel), "CanModifyBodyStats")
end

local function healParts(panel, partTypes)
    local values = {}
    for _, partType in ipairs(partTypes) do
        values[BodyStats.partKey(partType, BodyStats.HEALED)] = true
    end
    ZomboidFixesB42.sendBodyStats(adminOf(panel), panel:getPatient():getUsername(), values)
end

local function onHealPart(panel, partType)
    healParts(panel, { partType })
end

local function onHealBody(panel)
    healParts(panel, BodyStats.PART_TYPES)
end

local function subMenuOf(menu, name)
    local option = menu and menu:getOptionFromName(name)
    if not option or not option.subOption then return nil end
    return menu:getSubMenu(option.subOption)
end

local vanillaBodyPartMenu = ISHealthPanel.doBodyPartContextMenu

function ISHealthPanel:doBodyPartContextMenu(bodyPart, x, y)
    local context
    local vanillaGet = ISContextMenu.get
    ISContextMenu.get = function(...)
        context = vanillaGet(...)
        return context
    end
    local ok, err = pcall(vanillaBodyPartMenu, self, bodyPart, x, y)
    ISContextMenu.get = vanillaGet
    if not ok then error(err) end

    if not context or not ISHealthPanel.cheat or not bodyPart or not canHeal(self) then return end
    local cheatMenu = subMenuOf(context, getText("ContextMenu_Cheat"))
    if not cheatMenu then return end
    -- Each one right after vanilla's Full Health it stands beside, which is last.
    local partMenu = subMenuOf(cheatMenu, getText("ContextMenu_Partchange"))
    if partMenu then
        partMenu:addOption(getText("IGUI_ZomboidFixesB42_HealKeepTreatment"), self, onHealPart,
            BodyPartType.ToString(bodyPart:getType()))
    end
    cheatMenu:addOption(getText("IGUI_ZomboidFixesB42_HealBodyKeepTreatment"), self, onHealBody)
end
