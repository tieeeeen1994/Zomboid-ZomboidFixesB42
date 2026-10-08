--[[
    Zomboid Fixes B42.20 -- client, Admin Powers window layout

    The Admin Powers window (ISAdminPowerUI, 42.21) has two tick box columns and
    puts each power in the one its AddOption named: vanilla has 11 on the left and
    13 on the right, and every power a mod adds lands where it says (this mod's Full
    Bright, God Vehicle and No Wear go right). So the right column runs longer and
    longer while the left one ends early.

    The window is also placed only once, when it is first made
    (ISAdminPowerUI:new centres a 480 x 350 box on the screen), and then grows
    downwards to fit the columns (updateAdminPower, on every opening). With a large
    font or a short screen that pushes the bottom, Save and Close included, past
    the bottom of the screen.

    So the powers the admin may use (vanilla's rule:
    -debug, or the role holds the power's capability; a power this mod adds that is
    off in the sandbox options is left out, option.zfixEnabled) are split evenly
    between the two columns in the window's own order (left column first), and
    after each opening the window is moved back onto the screen if any part of it
    is off it (centred on the axis that overflows).
--]]

require "ISUI/AdminPanel/ISAdminPowerUI"

--- The options the window shows to this admin, in the window's order: every
-- left-side option, then every right-side one.
local function shownOptions(window)
    local list = {}
    for _, side in ipairs({ "left", "right" }) do
        for _, option in ipairs(ISAdminPowerUI.OptionList) do
            if option.side == side
                and (isDebugEnabled() or window.player:getRole():hasCapability(option.capability))
                and not (option.zfixEnabled and not option.zfixEnabled()) then
                list[#list + 1] = option
            end
        end
    end
    return list
end

function ISAdminPowerUI:addAdminPowerOptionsLeft()
    self.optionsLeft = {}
    self.cheatTooltipsLeft = {}
    local list = shownOptions(self)
    for i = 1, math.ceil(#list / 2) do
        self:addOptionLeft(list[i])
    end
    self.tickBoxLeft:setWidthToFit()
end

function ISAdminPowerUI:addAdminPowerOptionsRight()
    self.optionsRight = {}
    self.cheatTooltipsRight = {}
    local list = shownOptions(self)
    for i = math.ceil(#list / 2) + 1, #list do
        self:addOptionRight(list[i])
    end
    self.tickBoxRight:setWidthToFit()
end

local vanillaUpdate = ISAdminPowerUI.updateAdminPower

function ISAdminPowerUI:updateAdminPower(...)
    local result = vanillaUpdate(self, ...)
    local core = getCore()
    local screenW, screenH = core:getScreenWidth(), core:getScreenHeight()
    if self:getY() < 0 or self:getY() + self:getHeight() > screenH then
        self:setY(math.max(0, math.floor((screenH - self:getHeight()) / 2)))
    end
    if self:getX() < 0 or self:getX() + self:getWidth() > screenW then
        self:setX(math.max(0, math.floor((screenW - self:getWidth()) / 2)))
    end
    return result
end
