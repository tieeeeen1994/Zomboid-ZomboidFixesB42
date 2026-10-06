--[[
    Zomboid Fixes B42.20 -- client, the bag attachment slot box drawn at the tooltip's font size and under
    every other mod's tooltip lines

    Plysken Attachments Reborn (mod id PAR, zPAR_Tooltip.lua) lists a bag's attachment slots
    (modData.PARattachments, names from the global PARSlotsName) in a box of its own under the item
    tooltip. Its ISToolTipInv:render draws that box before calling the rest of the render, and gets it
    wrong two ways:

      * Size. Line heights are fixed per tooltip font option (fontConfig: Small 15 px, Medium and Large
        20 px), the slot icon is 10 x 10 at a fixed offset, and the box is as wide as the tooltip. The
        tooltip's real line spacing is the font's line height (ObjectTooltip.checkFont:
        getFontFromEnum(font):getLineHeight(), read with tooltip:getLineSpacing()), and the font size
        option (options.ini fontSize, 1x to 4x) scales every font. So past 1x the slot names are drawn
        over each other and below the box, and long names run out of its right side.
      * Position. It starts at self.tooltip:getHeight(): the height of the ObjectTooltip, which
        vanilla's render last set by measuring the item's own text (item:DoTooltip with
        setMeasureOnly). Mods that add lines to the bottom of the tooltip make the panel taller than
        that, and the ObjectTooltip does not follow. Dynamic Backpack Upgades (ToolTipInvOverride.lua)
        swaps the panel's setHeight and drawRectBorder for the length of a render and draws its rows
        where the item's text ends: its background, drawn after Plysken's box, covers the top of the
        box, and its rows are drawn over the slot names. Loaded the other way round, Plysken's own
        setHeight / drawRectBorder calls land in Dynamic Backpack Upgrades' swapped methods, which
        take the first one for vanilla's.

    Plysken's box is only drawn when modData.PARattachments holds a slot, and its render is the only
    reader, so for the length of the render chain the field is taken off the bag (synchronous, put
    back even on an error) and Plysken's render goes straight on to the rest of the chain. Once the
    whole chain has drawn the tooltip (vanilla's text, Dynamic Backpack Upgades' or Tien's Bag
    Upgrades' lines, which grow the panel), the box is drawn here under the panel: the tooltip's font
    and line spacing, ObjectTooltip's padding (the width of a "0", half that above and below), the icon
    two thirds of a line, as wide as its longest line, kept on screen (above the tooltip when there is
    no room below). Slots are listed by name. The panel and the ObjectTooltip are then as tall as the
    whole, so anything drawn after starts below; vanilla measures the ObjectTooltip again at the start
    of every render, so the item's text is unchanged.

    Installed from OnGameStart, on top of every other mod's override (all their files have been read by
    then), so it runs last.
--]]

require "ISUI/ISToolTipInv"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.TooltipStacking == true
end

local slotTexture = nil

--- Display names of the slots Plysken would list for this item, sorted (possibly empty), or nil when
-- it would draw no box.
local function slotNamesOf(item)
    if not PARSlotsName or not item or not instanceof(item, "InventoryContainer") then return nil end
    local slots = item:getModData().PARattachments
    if type(slots) ~= "table" then return nil end
    local any, names = false, {}
    for slot, on in pairs(slots) do
        if on then
            any = true
            local name = PARSlotsName[slot]
            if name then table.insert(names, name) end
        end
    end
    if not any then return nil end
    table.sort(names)
    return names
end

local function drawSlotBox(self, names)
    local tooltip = self.tooltip
    local font = tooltip:getFont()
    local lineH = tooltip:getLineSpacing()
    local tm = getTextManager()
    local pad = tm:MeasureStringX(font, "0")
    local padY = math.floor(pad / 2)
    local icon = math.max(10, math.floor(lineH * 2 / 3))
    local textX = pad + icon + padY
    local header = getText("IGUI_PAR_AttachmentSlots") .. ":"

    local width = math.max(self.width, pad + tm:MeasureStringX(font, header) + pad)
    for _, name in ipairs(names) do
        width = math.max(width, textX + tm:MeasureStringX(font, name) + pad)
    end
    local height = padY * 2 + lineH * (#names + 1)

    -- Share the panel's bottom border row; above it, sharing the top row, when there is no room below.
    local absX, absY = self:getAbsoluteX(), self:getAbsoluteY()
    local below = absY + self.height - 1 + height <= getCore():getScreenHeight()
    local top = below and (self.height - 1) or (1 - height)
    local left = math.min(0, getCore():getScreenWidth() - absX - width)
    left = math.max(left, -absX)

    local bg, border = self.backgroundColor, self.borderColor
    self:drawRect(left, top, width, height, bg.a, bg.r, bg.g, bg.b)
    self:drawRectBorder(left, top, width, height, border.a, border.r, border.g, border.b)

    local y = top + padY
    self:drawText(header, left + pad, y, 1, 1, 0.8, border.a, font)
    for _, name in ipairs(names) do
        y = y + lineH
        if slotTexture then
            self:drawTextureScaledAspect(slotTexture, left + pad, y + math.floor((lineH - icon) / 2), icon, icon, 1, 1, 1, 1)
        end
        self:drawText(name, left + textX, y, 1, 1, 1, 1, font)
    end

    if below then
        self:setHeight(top + height)
    end
end

local installed = false

local function install()
    if installed then return end
    installed = true
    slotTexture = getTexture("media/textures/Item_PARAttachmentSlot.png")

    local previousRender = ISToolTipInv.render

    function ISToolTipInv:render()
        if not isEnabled() then return previousRender(self) end

        local item = self.item
        local names = slotNamesOf(item)
        if names then
            local modData = item:getModData()
            local slots = modData.PARattachments
            modData.PARattachments = nil
            local ok, err = pcall(previousRender, self)
            modData.PARattachments = slots
            if not ok then error(err) end
        else
            previousRender(self)
        end

        -- Vanilla draws nothing while a context menu is open.
        if ISContextMenu.instance and ISContextMenu.instance.visibleCheck then return end
        if names and #names > 0 then
            drawSlotBox(self, names)
        end
        local tooltip = self.tooltip
        if tooltip and self.height and self.height > tooltip:getHeight() then
            tooltip:setHeight(self.height)
        end
    end
end

Events.OnGameStart.Add(install)
