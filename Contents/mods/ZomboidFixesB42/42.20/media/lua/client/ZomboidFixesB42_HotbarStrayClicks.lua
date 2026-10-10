--[[
    Zomboid Fixes B42.20 -- client, the equipment hotbar only takes clicks that start on it

    Clicking a context menu option that lies over the equipment hotbar (client/Hotbar/
    ISHotbar.lua) sometimes uses the hotbar slot under the option instead of choosing it.

    Java hands the press and the release to the UI elements separately, each in its own
    frame (UIManager.updateMouseButtons, ~757): top element first, stopping at the first
    one under the mouse that takes it. An open context menu is brought to the front
    (ISContextMenu.get) and takes both, so the hotbar below should get neither. But a
    slot is used on the release alone: ISHotbar:onMouseUp (~631) calls activateSlot for
    whatever slot is under the mouse and never asks where the press went. So once the
    menu is gone before the button comes up (it has closed by the time the release is
    handed out, and Java gives the release to the next element down), the release
    reaches the hotbar and uses a slot. What closes the menu in between was not traced.

    So a slot is only used when the press landed on the hotbar too: ISHotbar:onMouseDown
    (Java calls it when the press reaches the bar) notes it, and the note is cleared
    in ISHotbar:update every frame the left button is up and on every release, so a press
    that went elsewhere never leaves one behind. A release that arrives on its own does
    nothing. Dropping a dragged item on a slot (ISMouseDrag.dragging, a press in an
    inventory window) works as before, as do the number keys.

    The wrappers are installed when this file loads. TienCustomizableHotbar wraps the same
    methods at OnGameStart and calls these for presses on the slots.
--]]

require "Hotbar/ISHotbar"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.HotbarStrayClicks == true
end

local previousDown = ISHotbar.onMouseDown

function ISHotbar:onMouseDown(x, y)
    self.zfixPressedHere = true
    return previousDown(self, x, y)
end

local previousUp = ISHotbar.onMouseUp

function ISHotbar:onMouseUp(x, y)
    local pressedHere = self.zfixPressedHere
    self.zfixPressedHere = nil
    if isEnabled() and not pressedHere and not ISMouseDrag.dragging then
        return true
    end
    return previousUp(self, x, y)
end

local previousUpOutside = ISHotbar.onMouseUpOutside

function ISHotbar:onMouseUpOutside(x, y)
    self.zfixPressedHere = nil
    if previousUpOutside then
        return previousUpOutside(self, x, y)
    end
end

local previousUpdate = ISHotbar.update

function ISHotbar:update()
    previousUpdate(self)
    if not isMouseButtonDown(0) then
        self.zfixPressedHere = nil
    end
end
