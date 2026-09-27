--[[
    Zomboid Fixes B42.20 -- client, Guns of Marz tooltips

    A tooltip is only ever as narrow as its widest line. ObjectTooltip.Layout.render
    measures every label it is given and then does

        if left + widthTotal + ui.padRight > ui.width then
            ui.setWidth(left + widthTotal + ui.padRight)

    so one long line stretches the whole tooltip, stat block and all, into a banner
    across the screen. The line that does it is vanilla rather than Guns of Marz:
    WeaponPart.DoTooltip pastes every weapon an attachment fits onto a single label,

        Translator.getText("Tooltip_weapon_CanBeMountOn") + ": "
            + this.mountOnDisplayName.toString().replaceAll("\\[", "").replaceAll("\\]", "")

    which is fine for the handful of vanilla guns and absurd once Guns of Marz has
    added thirty.

    That label cannot be edited after the fact. Lua sees only a Java class's methods
    and its static fields -- LuaJavaClassExposer skips every instance field -- and
    ObjectTooltip.LayoutItem keeps label, hasValue and its colours in public fields
    with no getters at all. So a label the game has written can be added to but never
    read back. It is the same wall that makes Guns of Marz write "tooltip.padLeft or
    5", where the 5 always wins, and makes StarlitLibrary recompute a layout's y
    offset by hand rather than read Layout.offsetY. (getClassFieldVal would read
    them, but LuaManager.validateReflectionAccess throws "Not in debug" unless the
    game was started with -debug.)

    What is reachable is the data behind the label. mountOnDisplayName is filled by
    setMountOn, a public method, from each weapon script's getDisplayName, and
    Item.setDisplayName is public too. A label may also hold newlines:
    LayoutItem.calcSizes counts them into its height, and AngelCodeFont.getWidth
    restarts its count at each one and keeps the widest line. So for the length of
    the draw, every weapon that should start a new line has "\n" put in front of
    its script's display name, setMountOn rebuilds the list from them, and the game
    writes its own line already wrapped, in its own place, under its own header.
    Afterwards the names are put back and setMountOn is run again to rebuild the
    list from them.

    Three details make that safe rather than reckless. setMountOn clears its own
    field and not the list it is handed, so only setMountOn(getMountOn()) would
    destroy the data, and every call below builds a fresh list. The whole swap
    happens inside one synchronous render call, so nothing reads the altered names
    in between. And the draw is wrapped in pcall, so the restore still runs if it
    throws.

    The seam that gives us the layout at all is
    InventoryItem.DoTooltipEmbedded(tooltipUI, layoutOverride, offsetY): handed a
    layout it fills it and stops, leaving

        if layoutOverride == null then
            y = layout.render(tooltipUI.padLeft, y, tooltipUI)
            tooltipUI.endLayout(layout)
            ...

    to the caller. Its padding and starting y are worked out again here, because
    both live in instance fields Lua cannot see.

    The magazine line. A gun's ammo line is written by HandWeapon.DoTooltip as

        if (this.getMaxAmmo() > 0) {
            ...
            if (this.bulletName == null)
                this.bulletName = InventoryItemFactory.CreateItem(this.getMagazineType()).getDisplayName();
            item.setLabel(this.bulletName + ":", ...);
            item.setValue(count + " / " + this.getMaxAmmo(), ...);

    so it names the gun's MagazineType and counts against the gun's MaxAmmo, and the
    name is cached in a private field for the life of the item. Guns of Marz makes the
    magazine an attachment (part type "Clip") and sets the gun's MagazineType and
    MaxAmmo from it only once, in its OnCreate. Put a 150 round drum in an M16 and
    the line reads "STANAG 30Rds 5.56x45mm Magazine: 150+1 / 30". The label cannot be
    fixed in place, for the reasons above, and bulletName has no setter. But the whole
    line depends on getMaxAmmo() > 0, and setMaxAmmo is public. So while the layout
    is filled the gun's MaxAmmo is 0 and the game leaves the line out; it is restored
    straight after the fill, before anything else runs, and again after the pcall if
    the fill threw. A corrected line -- the attached magazine's name, the rounds in
    the gun and the magazine's own capacity -- is then added to the same layout, so
    it lines up with the rows above it. It can only go at the end of the game's rows
    (after "Mod: Guns of Marz"), because a layout can be added to but not inserted
    into. The one other line that reads MaxAmmo, "Spent rounds: n / max", shows only
    for a gun whose spent casings stay in it and would read "/ 0" meanwhile.

    Only a gun whose attached magazine differs from its MagazineType or MaxAmmo is
    redrawn: while they still agree the game's line is right and stays where it is.
    GoM only ever sets MagazineType at creation, before any tooltip, so the cached
    name agrees with it.

    Only weapon parts and such guns go through any of this. Everything else is handed
    to whichever render was already installed, which leaves Guns of Marz's tooltip
    drawing, and the equipment slot hook it installs from inside it, working as they
    do now. The items drawn here would lose the "Information" block it appends, since
    its render no longer runs for them, so the same block is rebuilt here from the
    same table.

    Runs on each client, because tooltips are drawn there. Does nothing unless Guns
    of Marz is loaded: the require below fails harmlessly without it.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local TOOLTIP_MODULE = "MarzWeapons/ItemTooltipsTable"

-- In front of every line after the first, so a wrapped line reads as the rest of
-- the line above it rather than as another fact.
local CONTINUATION = "  "

-- Guns of Marz's own heading and colours for its block, copied so that the tooltips
-- this file draws itself are not told apart from the ones it leaves alone.
local INFO_HEADING = "Information"

-- Below this the game pads the tooltip out to a fixed width, so wrapping any harder
-- only makes it taller. Matches InventoryItem.DoTooltipEmbedded.
local MIN_TOOLTIP_WIDTH = 150

-- The column minimums DoTooltipEmbedded gives a layout it makes itself; one handed
-- in as an override has to be given them by the caller.
local MIN_COLUMN_WIDTH = 80

-- The part type Guns of Marz magazines attach as.
local MAGAZINE_PART = "Clip"

--- The greatest number of characters a tooltip line may have. 0 means leave the
-- tooltips alone, which is also what an absent option gives, so the fix ships
-- inert: the render hook is installed but hands every tooltip straight on.
local function lineLength()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    local limit = vars and vars.GoMTooltipLineLength
    if type(limit) ~= "number" or limit < 1 then return 0 end
    return math.floor(limit)
end

local function magazineLineEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.GoMMagazineTooltip == true
end

--- Break text on spaces. Words are never split: one longer than the limit gets a
-- line to itself and overhangs, which is better than a tooltip full of hyphens and
-- cannot loop forever.
local function wrapWords(text, limit)
    if limit < 1 then limit = 1 end

    local lines = {}
    local line = nil

    for word in string.gmatch(text, "%S+") do
        if not line then
            line = word
        elseif #line + 1 + #word <= limit then
            line = line .. " " .. word
        else
            lines[#lines + 1] = line
            line = word
        end
    end

    if line then lines[#lines + 1] = line end
    return lines
end

--- Add one piece of text to the layout, over as many lines as it needs. The first
-- line and the ones after it are indented separately: a note carries on under
-- itself, while a list already sitting under a heading stays flush with itself.
local function addWrapped(layout, text, limit, firstIndent, restIndent, r, g, b, a)
    local lines = wrapWords(text, limit - math.max(#firstIndent, #restIndent))
    for i = 1, #lines do
        local prefix = i == 1 and firstIndent or restIndent
        layout:addItem():setLabel(prefix .. lines[i], r, g, b, a)
    end
end

--- The lines of one Guns of Marz tooltip entry. It accepts either a list of lines
-- or a single newline separated string, so both are read here the way it does.
local function toLines(entry)
    local lines = {}

    if type(entry) == "string" then
        for line in string.gmatch(entry, "[^\r\n]+") do
            lines[#lines + 1] = line
        end
    elseif type(entry) == "table" then
        for i = 1, #entry do
            if type(entry[i]) == "string" and entry[i] ~= "" then
                lines[#lines + 1] = entry[i]
            end
        end
    end

    return lines
end

-- ---------------------------------------------------------------------------
-- The mount list

--- The weapon types an attachment fits, as a plain Lua list. Copied out rather than
-- held onto: getMountOn hands back the live field, and setMountOn clears that field
-- before it reads its argument, so passing it straight back would empty it.
local function mountTypes(item)
    local list = item:getMountOn()
    if not list then return nil end

    local count = list:size()
    if count == 0 then return nil end

    local types = {}
    for i = 0, count - 1 do
        types[#types + 1] = list:get(i)
    end
    return types
end

local function javaList(types)
    local list = ArrayList.new()
    for i = 1, #types do
        list:add(types[i])
    end
    return list
end

--- Put a line break in front of every weapon name that should start a new line,
-- and return what was changed so it can be put back. The game joins the names with
-- ", " after "Can be mounted on: ", so the lines are measured the same way. Names
-- are never split: one longer than the limit gets a line to itself and overhangs.
local function breakNames(types, limit)
    local scripts = ScriptManager.instance
    local changed = {}
    local used = #(getText("Tooltip_weapon_CanBeMountOn") .. ": ")
    local first = true

    for i = 1, #types do
        local script = scripts:getItem(types[i])
        -- setMountOn drops a type with no script, so it takes no room either.
        if script then
            local name = script:getDisplayName()
            if not first and used + 2 + #name > limit then
                -- A weapon listed twice shares one script; change it only once so
                -- the original is the one saved.
                if not changed[script] then
                    changed[script] = name
                    script:setDisplayName("\n" .. CONTINUATION .. name)
                end
                used = #CONTINUATION + #name
            else
                used = used + (first and 0 or 2) + #name
            end
            first = false
        end
    end

    return changed
end

local function restoreNames(changed)
    for script, name in pairs(changed) do
        script:setDisplayName(name)
    end
end

-- ---------------------------------------------------------------------------
-- The magazine line

--- The magazine attached to a gun whose own ammo line would name the wrong one, or
-- nil. See the header: while the gun's MagazineType and MaxAmmo still match the
-- attachment, the game's line is right and is left alone.
local function mismatchedMagazine(item)
    if not magazineLineEnabled() or not instanceof(item, "HandWeapon") then return nil end
    if item:getMaxAmmo() <= 0 or not item:isContainsClip() then return nil end

    local magazine = item:getWeaponPart(MAGAZINE_PART)
    if not magazine or magazine:getMaxAmmo() <= 0 then return nil end

    if magazine:getFullType() == item:getMagazineType() and magazine:getMaxAmmo() == item:getMaxAmmo() then
        return nil
    end
    return magazine
end

--- The line HandWeapon.DoTooltip would have written, counted against the magazine
-- actually in the gun. Same colours and the same "+1" for a chambered round.
local function addMagazineLine(layout, weapon, magazine)
    local count = string.format("%d", weapon:getCurrentAmmoCount())
    if weapon:isRoundChambered() then count = count .. "+1" end

    local row = layout:addItem()
    row:setLabel(magazine:getDisplayName() .. ":", 1.0, 1.0, 0.8, 1.0)
    row:setValue(count .. " / " .. string.format("%d", magazine:getMaxAmmo()), 1.0, 1.0, 1.0, 1.0)
end

-- ---------------------------------------------------------------------------
-- Drawing

--- ObjectTooltip.checkFont sets every pad from the width of one digit, and
-- beginLayout copies them onto the tooltip. They live in instance fields, so they
-- are worked out again rather than read back.
local function padding(tooltip)
    local charWidth = getTextManager():MeasureStringX(tooltip:getFont(), "0")
    return charWidth, math.floor(charWidth / 2)
end

--- Where DoTooltipEmbedded leaves its layout, which it would have parked in
-- Layout.offsetY: below the item name, and below the row of contained items when
-- there is one.
local function layoutTop(tooltip, item, padTop)
    local lineSpacing = tooltip:getLineSpacing()
    local y = padTop + lineSpacing + 5

    local extra = item:getExtraItems()
    if extra and extra:size() > 0 then
        y = y + lineSpacing + 5
    end

    return y
end

--- Fill the tooltip's layout the way the game would, with a weapon part's mount
-- list broken onto lines when limit is above 0 and a gun's magazine line corrected
-- when magazine is given, add the Guns of Marz block (wrapped only when limit is
-- above 0), then render. The two halves of DoTooltipEmbedded that the layout
-- override skips -- the render and the minimum width -- are repeated here.
local function drawTooltip(tooltip, item, gomLines, limit, magazine)
    local types = nil
    if limit > 0 and instanceof(item, "WeaponPart") then
        types = mountTypes(item)
    end
    local padSide, padEnd = padding(tooltip)

    local changed = nil
    local maxAmmo = nil
    local ok, err = pcall(function()
        if types then
            changed = breakNames(types, limit)
            item:setMountOn(javaList(types))
        end

        local layout = tooltip:beginLayout()
        layout:setMinLabelWidth(MIN_COLUMN_WIDTH)
        layout:setMinValueWidth(MIN_COLUMN_WIDTH)

        if magazine then
            maxAmmo = item:getMaxAmmo()
            item:setMaxAmmo(0)
        end
        item:DoTooltipEmbedded(tooltip, layout, 0)
        if magazine then
            item:setMaxAmmo(maxAmmo)
            maxAmmo = nil
            addMagazineLine(layout, item, magazine)
        end

        if gomLines then
            layout:addItem():setLabel(INFO_HEADING, 1, 0.02, 0.02, 1)
            for _, line in ipairs(gomLines) do
                if limit > 0 then
                    addWrapped(layout, line, limit, "", CONTINUATION, 1.0, 1.0, 1.0, 1.0)
                else
                    layout:addItem():setLabel(line, 1.0, 1.0, 1.0, 1.0)
                end
            end
        end

        local y = layout:render(padSide, layoutTop(tooltip, item, padEnd), tooltip)
        tooltip:endLayout(layout)

        tooltip:setHeight(y + padEnd)
        if tooltip:getWidth() < MIN_TOOLTIP_WIDTH then
            tooltip:setWidth(MIN_TOOLTIP_WIDTH)
        end
    end)

    -- Always, including when the draw threw, and always from a list of our own so
    -- that setMountOn cannot clear the one it is reading.
    if maxAmmo then item:setMaxAmmo(maxAmmo) end
    if changed then restoreNames(changed) end
    if types then item:setMountOn(javaList(types)) end

    if not ok then error(err, 0) end
end

--- Position the tooltip and draw it twice, once to measure and once for real. This
-- is ISToolTipInv:render with its two item:DoTooltip calls replaced; the placement
-- either side of them is vanilla's and is kept the same, so a redrawn tooltip sits
-- where the game's would.
local function renderTooltip(self, item, gomLines, limit, magazine)
    local tooltip = self.tooltip

    local mx = getMouseX() + 24
    local my = getMouseY() + 24
    if not self.followMouse then
        mx = self:getX()
        my = self:getY()
        if self.anchorBottomLeft then
            mx = self.anchorBottomLeft.x
            my = self.anchorBottomLeft.y
        end
    end

    tooltip:setX(mx)
    tooltip:setY(my)

    tooltip:setWidth(50)
    tooltip:setMeasureOnly(true)
    drawTooltip(tooltip, item, gomLines, limit, magazine)
    tooltip:setMeasureOnly(false)

    local core = getCore()
    local maxX = core:getScreenWidth()
    local maxY = core:getScreenHeight()
    local tw = tooltip:getWidth()
    local th = tooltip:getHeight()

    tooltip:setX(math.max(0, math.min(mx, maxX - tw - 1)))
    if not self.followMouse and self.anchorBottomLeft then
        tooltip:setY(math.max(0, math.min(my - th, maxY - th - 1)))
    else
        tooltip:setY(math.max(0, math.min(my, maxY - th - 1)))
    end

    if self.contextMenu and self.contextMenu.joyfocus then
        local playerNum = self.contextMenu.player
        tooltip:setX(getPlayerScreenLeft(playerNum) + 60)
        tooltip:setY(getPlayerScreenTop(playerNum) + 60)
    elseif self.contextMenu and self.contextMenu.currentOptionRect then
        if self.contextMenu.currentOptionRect.height > 32 then
            self:setY(my + self.contextMenu.currentOptionRect.height)
        end
        self:adjustPositionToAvoidOverlap(self.contextMenu.currentOptionRect)
    end

    self:setX(tooltip:getX())
    self:setY(tooltip:getY())
    self:setWidth(tw)
    self:setHeight(th)

    if self.followMouse and self.contextMenu == nil then
        self:adjustPositionToAvoidOverlap({ x = mx - 48, y = my - 48, width = 48, height = 48 })
    end

    self:drawRect(0, 0, self.width, self.height, self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
    self:drawRectBorder(0, 0, self.width, self.height, self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    drawTooltip(tooltip, item, gomLines, limit, magazine)
end

--- Replace ISToolTipInv:render with one that wraps weapon part tooltips, corrects
-- the magazine line of guns whose magazine was swapped, and hands everything else
-- to whatever was there before. Installed from OnGameStart rather than at load, so
-- it goes on top of the overrides other mods put in place while their files were
-- read.
local function install(module)
    local previousRender = ISToolTipInv.render

    -- Everything this reaches across the Java bridge is reached by name and cannot
    -- be checked for up front, so the first call of each fix is made under pcall. A
    -- failure there gives up on that fix for the rest of the session rather than
    -- throwing once a frame for as long as the mouse rests on an item.
    local checked = {}
    local broken = {}

    function ISToolTipInv:render()
        -- Options are read every draw rather than once at install, so an admin
        -- changing one mid-game takes effect both ways.
        local item = self.item
        if not item then return previousRender(self) end

        local limit = lineLength()
        local fix = nil
        local magazine = nil
        if instanceof(item, "WeaponPart") then
            if limit > 0 then fix = "wrap" end
        else
            magazine = mismatchedMagazine(item)
            if magazine then
                fix = "magazine"
                -- Guns are not wrapped: Guns of Marz draws their block as it is.
                limit = 0
            end
        end
        if not fix or broken[fix] then
            return previousRender(self)
        end

        if ISContextMenu.instance and ISContextMenu.instance.visibleCheck then return end

        local entry = module.tooltipsPergun[item:getFullType()]
        local gomLines = entry and toLines(entry) or nil
        if gomLines and #gomLines == 0 then gomLines = nil end

        if checked[fix] then
            return renderTooltip(self, item, gomLines, limit, magazine)
        end

        local ok, err = pcall(renderTooltip, self, item, gomLines, limit, magazine)
        if ok then
            checked[fix] = true
        else
            broken[fix] = true
            print("ZomboidFixesB42: Guns of Marz tooltip fix '" .. fix .. "' turned off, " .. tostring(err))
            return previousRender(self)
        end
    end
end

--- The Guns of Marz tooltip module, or nil when it is not loaded -- which is the
-- whole of the availability check, and is why nothing here is gated on a mod id:
-- the previous version of the mod ships the same table under a different one.
local function tooltipsModule()
    local ok, module = pcall(require, TOOLTIP_MODULE)
    if not ok or type(module) ~= "table" then return nil end
    if type(module.tooltipsPergun) ~= "table" then return nil end
    return module
end

local function apply()
    local module = tooltipsModule()
    if not module then return end

    install(module)
end

Events.OnGameStart.Add(apply)
