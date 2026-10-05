--[[
    Zomboid Fixes B42.20 -- client, where this mod's context menu tooltips go

    A context menu option's tooltip (option.toolTip, an ISToolTip) is placed by
    ISToolTip:adjustPositionToAvoidOverlap: next to the hovered option, to the right
    of the menu first (placeRight), then the left, then above. To the right is
    exactly where the option's submenu opens, so the tooltips this mod puts on menu
    options that lead somewhere (the admin hotbar's action lists, Add step, the
    chopper and Turbo Game entries) covered the very menu the player was reaching for.

    A tooltip marked with ZomboidFixesB42.sideTooltip goes to the left of its menu
    instead (right only when there is no room on the left), and is drawn behind
    the open menus: ISContextMenu:showTooltip adds it to the UIManager once, after
    the menus, so here the open chain (root, then each visible submenu, which
    ISContextMenu keeps in self.subMenu) is brought back on top of it, parents
    before children as getNew does. Left of a submenu is where its parent menu is,
    so the parent now covers the tooltip rather than the other way round.

    Vanilla's tooltips are left alone. Context menu tooltips are pooled
    (ISWorldObjectContextMenu / ISInventoryPaneContextMenu .addToolTip, ISToolTip:reset
    when reused), so the mark is cleared on reset.

    Only this mod's own UI, so there is no sandbox option.
--]]

require "ISUI/ISToolTip"
require "ISUI/ISContextMenu"

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- Gap between the menu and the tooltip, as ISToolTip's own placeLeft/placeRight.
local GAP = 8

--- Mark a context menu tooltip to go left of its menu and behind it. Returns it.
function ZomboidFixesB42.sideTooltip(tooltip)
    if tooltip then tooltip.zfixMenuSide = true end
    return tooltip
end

local vanillaReset = ISToolTip.reset

function ISToolTip:reset()
    self.zfixMenuSide = nil
    return vanillaReset(self)
end

local vanillaAdjust = ISToolTip.adjustPositionToAvoidOverlap

function ISToolTip:adjustPositionToAvoidOverlap(avoidRect)
    local menu = self.contextMenu
    if not self.zfixMenuSide or not menu or menu.joyfocus or not menu.currentOptionRect then
        return vanillaAdjust(self, avoidRect)
    end
    -- The option rect is in screen coordinates and as wide as the menu.
    local x = avoidRect.x - self.width - GAP
    if x < 0 then return vanillaAdjust(self, avoidRect) end
    self:setX(x)
    self:setY(avoidRect.y)
end

local vanillaShowTooltip = ISContextMenu.showTooltip

function ISContextMenu:showTooltip(option)
    local before = self.toolTip
    vanillaShowTooltip(self, option)
    local tooltip = self.toolTip
    if not tooltip or tooltip == before or not tooltip.zfixMenuSide then return end
    -- Just added on top of everything: put the open menus back over it.
    local menu = getPlayerContextMenu(self.player)
    local guard = 0
    while menu and guard < 20 do
        if menu:getIsVisible() then menu:bringToTop() end
        menu = menu.subMenu
        guard = guard + 1
    end
end
