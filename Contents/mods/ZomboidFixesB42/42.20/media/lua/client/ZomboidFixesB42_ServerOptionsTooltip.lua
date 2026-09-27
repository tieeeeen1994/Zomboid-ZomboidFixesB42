--[[
    Zomboid Fixes B42.20 -- client, the admin Server Options tooltip no longer sticks

    The admin panel's Server Options window (ISServerOptions, client/ISUI/AdminPanel/
    ISServerOptions.lua) shows the tooltip of the option under the mouse in a top-level
    ISToolTip that follows the mouse. Its onMouseMove creates it over a row (:42-50) and
    removes it (hideTooltip, :62-68) only on a later onMouseMove over the window that is
    not over a row. Nothing else ever removes it:

      * the window has no onMouseMoveOutside, so leaving it straight from a row, quickly
        enough that no onMouseMove lands on the window on the way out, leaves it up;
      * Close and the "leave without reloading" dialog (:214-215, :229-230) take the
        window out of the UI manager and leave the tooltip where it is.

    After either, nothing holds a reference to it any more, and an option's tooltip
    ("Disables character speed anti-cheat protection.") follows the mouse around the
    game for the rest of the session.

    The other admin windows get this right. ISRolesList and ISAdminPowerUI give their
    tooltips an owner (ISToolTip:setOwner), and ISToolTip:prerender removes a tooltip
    whose owner is no longer isReallyVisible: hidden, or, for a top-level window, gone
    from the UI manager (UIElement.isReallyVisible checks UIManager.getUI()). ISRolesList
    also hides its tooltip in onMouseMoveOutside. This does both for ISServerOptions:
    the window becomes its tooltip's owner, so every way of closing it (its own buttons,
    the admin panel, the admin hotbar) takes the tooltip along, and moving the mouse off
    the window hides it.
--]]

require "ISUI/AdminPanel/ISServerOptions"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.ServerOptionsTooltip == true
end

local previousOnMouseMove = ISServerOptions.onMouseMove

function ISServerOptions:onMouseMove(dx, dy)
    previousOnMouseMove(self, dx, dy)
    if self.tooltip and isEnabled() then
        self.tooltip:setOwner(self)
    end
end

-- ISPanel's, which drags the window while it is held (moveWithMouse).
local previousOnMouseMoveOutside = ISServerOptions.onMouseMoveOutside

function ISServerOptions:onMouseMoveOutside(dx, dy)
    if previousOnMouseMoveOutside then previousOnMouseMoveOutside(self, dx, dy) end
    if isEnabled() then self:hideTooltip() end
end
