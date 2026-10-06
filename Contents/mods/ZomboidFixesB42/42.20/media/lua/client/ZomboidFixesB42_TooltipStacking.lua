--[[
    Zomboid Fixes B42.20 -- client, bag attachment slots no longer drawn over other mods' tooltip lines

    Plysken Attachments Reborn (mod id PAR, zPAR_Tooltip.lua) lists a bag's attachment
    slots in a box of its own under the item tooltip. Its ISToolTipInv:render draws that
    box before calling the rest of the render, at self.tooltip:getHeight(): the height of
    the ObjectTooltip, which vanilla's render last set by measuring the item's own text
    (item:DoTooltip with setMeasureOnly). Mods that add lines to the bottom of the
    tooltip make the panel taller than that, and the ObjectTooltip does not follow:

      * Dynamic Backpack Upgrades (ToolTipInvOverride.lua) swaps the panel's setHeight
        and drawRectBorder for the length of a render, adds its rows (upgrade slots,
        capacity, weight reduction) to the height and draws them where the item's text
        ends. The panel's background, drawn after Plysken's box, then covers the top of
        that box, and its rows are drawn over the attachment slot names.

    So once the whole render chain has drawn the tooltip, the ObjectTooltip's height is
    set to the panel's. Plysken's box, drawn as the next frame starts, then begins under
    the added rows. Vanilla measures the ObjectTooltip again at the start of its own
    render, so the item's text and everything placed from it are unchanged.

    Installed from OnGameStart, on top of every other mod's override (all their files
    have been read by then). It only helps when Plysken's render runs before Dynamic
    Backpack Upgrades', i.e. Plysken's mod loads after it (the usual order). The other way
    round, Plysken's own setHeight / drawRectBorder calls land in Dynamic Backpack
    Upgrades' swapped methods, which take the first one for vanilla's and draw their rows
    at the top of the tooltip; nothing outside those two mods' local functions can change
    that. Tien's Bag Upgrades, its replacement, draws its lines after the render and sets
    the height itself, so it stacks with Plysken's box in either order.
--]]

require "ISUI/ISToolTipInv"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.TooltipStacking == true
end

local installed = false

local function install()
    if installed then return end
    installed = true

    local previousRender = ISToolTipInv.render

    function ISToolTipInv:render()
        previousRender(self)
        if not isEnabled() then return end
        -- Vanilla draws nothing while a context menu is open.
        if ISContextMenu.instance and ISContextMenu.instance.visibleCheck then return end
        local tooltip = self.tooltip
        if tooltip and self.height and self.height > tooltip:getHeight() then
            tooltip:setHeight(self.height)
        end
    end
end

Events.OnGameStart.Add(install)
