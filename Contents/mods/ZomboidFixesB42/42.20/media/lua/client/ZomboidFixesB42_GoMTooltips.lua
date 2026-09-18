--[[
    Zomboid Fixes B42.20 -- client, Guns of Marz tooltips

    Guns of Marz adds an "Information" block to the tooltip of every gun and
    attachment it ships, one note per line, out of its own table:

        MarzWeapons/ItemTooltipsTable.tooltipsPergun[fullType]

    Some of those notes are long -- "Allows mounting of scopes in AK family rifles
    (AK-47, AK-74, AKS-74U, ASVAL, SVD)" is eighty characters -- and a tooltip is
    only ever as narrow as its widest line. ObjectTooltip.Layout.render measures
    every label it is given and then does

        if left + widthTotal + ui.padRight > ui.width then
            ui.setWidth(left + widthTotal + ui.padRight)

    so a single long note stretches the whole tooltip, stat block and all, into a
    banner across the screen. Nothing wraps it, because a label is drawn with one
    DrawText call and only an explicit newline in it adds a line -- and a newline
    would not help anyway, since the width is measured off the whole string.

    So the wrap has to happen before the text reaches the tooltip, by breaking each
    note into several shorter notes. That is done to the table rather than to the
    drawing: Guns of Marz replaces ISToolTipInv.render wholesale, and a second
    override on top of theirs would be a fight over the same method. It reads
    tooltipsPergun fresh on every frame, and its own reader already accepts a list
    of lines, so rewriting the data is enough and leaves their rendering untouched.

    The limit is in characters, not pixels, so it does not depend on the tooltip
    font. A player on the large tooltip font gets the same number of words per line
    and a proportionally wider tooltip, which is what they asked for by choosing a
    bigger font.

    Runs on each client, because tooltips are drawn there. Does nothing unless Guns
    of Marz is loaded: the require below fails harmlessly without it.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local TOOLTIP_MODULE = "MarzWeapons/ItemTooltipsTable"

-- In front of every line after the first, so a wrapped line reads as the rest of
-- the note above it rather than as another fact.
local CONTINUATION = "  "

local applied = false

--- The greatest number of characters a tooltip line may have. 0 means leave the
-- tooltips alone, which is also what an absent option gives, so the fix ships
-- inert.
local function lineLength()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    local limit = vars and vars.GoMTooltipLineLength
    if type(limit) ~= "number" or limit < 1 then return 0 end
    return math.floor(limit)
end

--- The lines of one tooltip entry. Guns of Marz accepts either a list of lines or
-- a single newline separated string, so both are read here the same way it does.
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

--- Break one note over as many lines as it needs, appending them to out. Words are
-- never split: a word longer than the limit gets a line to itself and overhangs,
-- which is better than a tooltip full of hyphens and cannot loop forever.
local function wrapInto(out, note, limit)
    local indent = ""
    local line = nil

    for word in string.gmatch(note, "%S+") do
        if not line then
            line = word
        elseif #line + 1 + #word <= limit then
            line = line .. " " .. word
        else
            out[#out + 1] = line
            indent = CONTINUATION
            line = indent .. word
        end
    end

    if line then out[#out + 1] = line end
end

local function apply()
    if applied then return end

    local limit = lineLength()
    if limit == 0 then return end

    -- Without Guns of Marz there is no such module and require raises, which is the
    -- whole of the availability check.
    local ok, tooltips = pcall(require, TOOLTIP_MODULE)
    if not ok or type(tooltips) ~= "table" then return end

    local perGun = tooltips.tooltipsPergun
    if type(perGun) ~= "table" then return end

    applied = true

    for fullType, entry in pairs(perGun) do
        local wrapped = {}
        for _, note in ipairs(toLines(entry)) do
            wrapInto(wrapped, note, limit)
        end
        if #wrapped > 0 then
            perGun[fullType] = wrapped
        end
    end
end

Events.OnGameStart.Add(apply)
