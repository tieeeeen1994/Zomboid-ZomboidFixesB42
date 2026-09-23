--[[
    Zomboid Fixes B42.20 -- client, shift-click range with Nick's Inventory Selection Fix

    Nick's Inventory Selection Fix stops selections deselecting themselves, and in
    doing so exposes a vanilla quirk: shift-click starts behaving like ctrl-click,
    adding the clicked row to the selection instead of selecting from-and-to.

    Vanilla's shift branch (ISInventoryPane.lua:1676-1692) ranges from the anchor row
    in self.firstSelect. When the anchor is nil it falls back to ctrl-style "add this
    row, keep the rest". The anchor is only maintained by clicks on rows: a marquee
    drag-box never sets it, the empty-space mouse-down that precedes one nils it
    (ISInventoryPane.lua:1716-1718), and nothing validates it after rows shift, so it
    is routinely missing or stale exactly when a selection exists.

    Vanilla masked all of that: refreshContainer lost every selection within a refresh
    or two, so the ctrl-style fallback only ever fired against an already-empty
    selection and read as a plain single click. Once selections persist, the fallback
    fires against a live selection and shift reads as ctrl.

    Fix at the state, not the branch: on a shift mouse-down over a row, discard an
    anchor that no longer points at a row, and derive a missing anchor from the
    current selection - its bottom row when clicking at or above the selection, its
    top row otherwise, so the new range covers the prior selection - then let
    vanilla's own range code run. With no selection and no anchor, vanilla's fallback
    is a plain single select, which is correct. The faulty read is the first use of
    firstSelect in the handler, so seeding it beforehand is enough and no vanilla code
    needs to be copied.

    Nick's mod has since shipped its own copy of this, which does not work in
    practice, so this one does not rely on it. It is installed from OnGameStart rather
    than at load, so it wraps whatever every other mod has put on onMouseDown and
    runs first. Without Nick's mod, or with the option off, it hands every click
    straight to what was there before.

    Taken over from NISF Shift Range Fix.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.NISFShiftRange == true
end

--- Seed self.firstSelect so vanilla's shift branch ranges instead of adding a row.
local function seedAnchor(self)
    local mo = self.mouseOverOption
    if not mo or mo == 0 or not self.items or self.items[mo] == nil then return end

    local anchor = self.firstSelect
    if type(anchor) ~= "number" or anchor < 1 or self.items[anchor] == nil then
        anchor = nil
    end
    if anchor == nil and self.selected then
        local minRow, maxRow
        for row in pairs(self.selected) do
            if type(row) == "number" and self.items[row] ~= nil then
                if not minRow or row < minRow then minRow = row end
                if not maxRow or row > maxRow then maxRow = row end
            end
        end
        if minRow then
            if mo <= minRow then
                anchor = maxRow
            else
                anchor = minRow
            end
        end
    end
    self.firstSelect = anchor
end

local function install()
    -- Nick's mod defines this table from each of its files; nothing else does.
    if NicksInventorySelectionFix == nil then return end

    local previousOnMouseDown = ISInventoryPane.onMouseDown

    function ISInventoryPane:onMouseDown(x, y, ...)
        -- Read every click rather than once at install, so an admin changing the
        -- option mid-game takes effect both ways. Player 0 only, the same guard
        -- vanilla opens with: other players are joypad-driven.
        if isEnabled() and self.player == 0 and isShiftKeyDown() then
            seedAnchor(self)
        end
        return previousOnMouseDown(self, x, y, ...)
    end
end

Events.OnGameStart.Add(install)
