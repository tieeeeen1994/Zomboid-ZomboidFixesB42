--[[
    Zomboid Fixes B42.20 -- client, the server-kept admin powers in the corner cheat list

    The faded list of active cheats in the bottom right corner (ISVersionWaterMark's
    WaterMarkUI:render, 42.21) is one IGUI_CheatPanel_<tooltip> line per CheatType
    the local player isCheatSet, drawn upwards from just above the version text.
    Every vanilla Admin Powers option sets such a flag on the player, so they all
    show. The powers this mod keeps on the server (God Vehicle, No Wear, Endless
    Supplies; shared/ZomboidFixesB42_ServerPowers.lua) are no player flag, so the
    list never showed them. Full Bright borrows the Always Day flag and renames that
    line itself (ZomboidFixesB42_AdminFullBright.lua).

    So the render is wrapped: while it runs, the panel's drawTextRight is replaced
    by one that notes the highest line drawn (vanilla's coordinates, server info and
    cheats, Full Bright's renaming inside it), then each server power that is on
    (what the server last answered, def.active) is drawn above them in the same
    style. Each power's line follows its own sandbox option; no option of its own,
    it is part of each power.
--]]

require "ISUI/ISVersionWaterMark"

local ServerPowers = ZomboidFixesB42.ServerPowers

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.NewSmall)
-- Vanilla's spacing and fade for the cheat lines.
local STEP = FONT_HGT_SMALL + 3
local ALPHA = 0.3

local function activeLines()
    local lines = {}
    for _, def in ipairs(ServerPowers.list) do
        if def.hasOption and def.active and ServerPowers.isEnabled(def) then
            lines[#lines + 1] = getText("IGUI_CheatPanel_" .. def.id)
        end
    end
    return lines
end

if WaterMarkUI then
    local innerRender = WaterMarkUI.render
    WaterMarkUI.render = function(self, ...)
        local lines = activeLines()
        if #lines == 0 then return innerRender(self, ...) end
        local outer = rawget(self, "drawTextRight")
        local drawTextRight = self.drawTextRight
        local top = nil
        self.drawTextRight = function(panel, text, x, y, ...)
            if top == nil or y < top then top = y end
            return drawTextRight(panel, text, x, y, ...)
        end
        local ok, err = pcall(innerRender, self, ...)
        self.drawTextRight = outer
        if not ok then error(err) end
        -- Vanilla draws nothing without a player.
        if not self.chr or not self.revButton then return end
        local y = top and (top - STEP) or -STEP
        for _, text in ipairs(lines) do
            drawTextRight(self, text, self.revButton:getWidth(), y, 1, 1, 1, ALPHA, UIFont.NewSmall)
            y = y - STEP
        end
    end
end
