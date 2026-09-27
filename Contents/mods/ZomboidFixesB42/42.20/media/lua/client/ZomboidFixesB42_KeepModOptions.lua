--[[
    Zomboid Fixes B42.20 -- client, mod options of mods that are not loaded are kept

    Every mod's PZAPI.ModOptions settings share one file, Zomboid/Lua/ModOptions.ini,
    one line per option: "type|modOptionsID|optionID|value". Vanilla means to keep
    the lines of mods that are not loaded right now. PZAPI.ModOptions:load
    (client/PZAPI/ModOptions.lua:292) puts every line it has no registered option for
    into PZAPI.ModOptions.OtherOptions (:329), and :save writes them back after the
    loaded mods' lines (:286):

        for i, line in ipairs(PZAPI.ModOptions.OtherOptions) do
            fileOutput:write(line)
        end

    but readLine strips the line ending and nothing puts it back. So the first save
    made with some mods missing glues all their lines into one:

        tickbox|A|a|truetickbox|B|b|falsekeybind|C|c|20

    That line still survives saves while A stays unloaded. Once A is loaded again,
    load splits it on "|", sees mod A and option a (:305), fails to read the value
    "truetickbox" and drops the line, and the next save writes A with its defaults
    and B and C not at all. Playing with a different mod list and pressing Apply in
    the options therefore resets or deletes the settings of every mod that was not
    loaded, once two or more of them had options.

    A second path wipes the whole file. MainOptions only builds the Mods page, and
    so only calls load, when some loaded mod registered options
    (OptionScreens/MainOptions.lua:409 -> addModOptionsPanel -> load at :2796), but
    Apply always calls save (:3766). With no such mod loaded, OtherOptions is still
    empty and save writes an empty file.

    Both are fixed without touching how a value is written or read:
      * load reads through a reader that splits glued lines back apart (every
        glued value is followed by one of the seven option type names), so options
        glued by an earlier save come back too.
      * save reads the file again itself, keeps every line whose mod or option is
        not registered now, and hands those to vanilla's save with their line
        endings. It does not rely on load having run.

    A textentry value holding "|" was never readable by vanilla; such a line is kept
    as it is. This only works while this mod is loaded: a game played without it
    still saves the vanilla way, but the glued lines that leaves behind are split
    apart again the next time this mod loads.

    Key bindings lose the same way. A mod can add its own keys to the Key Bindings
    tab by appending to the global keyBinding table (shared/keyBinding.lua), and they
    are saved with vanilla's in Zomboid/Lua/keysB42.ini as "Name=key:30;shift:true".
    That file is rewritten from scratch (getFileWriter(..., true, false)) from the
    keys known right now, in three places:

        MainOptions.saveKeys (OptionScreens/MainOptions.lua:3706), run by Apply/Save,
            writes every entry of MainOptions.keyText;
        MainOptions:create (:417) after a key file version upgrade, the same but
            without the PZAPI.ModOptions keybinds;
        pzopt's copy of that create step (pzopt_optimizations_options.lua:3016).

    loadKeys (:3472) only reads back lines whose name is in keyBinding, and the
    writers only know those. So pressing Apply at the main menu, where a server's mods
    are not loaded yet, or in a game with a different mod list, deletes the keys of
    every mod that is not loaded, and they come back unbound.

    All three call the global getFileWriter by name when they run, so it is wrapped
    for keysB42.ini only: before the file is truncated its lines are read, the
    writer handed back passes every write through and notes the names written, and
    on close the old lines whose names were not written are appended. The loader
    finds a key by name wherever it sits in the file, and once the mod is loaded
    again its key is written in its own section and the kept copy is dropped.

    No sandbox option: the files belong to each player's own computer and are mostly
    saved at the main menu, where no sandbox is loaded, so it is always on.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local FILE_NAME = "ModOptions.ini"

-- Every value vanilla writes ends where the next line's type begins, so a glued
-- value is split at whichever of these it ends with. "multipletickbox" must be
-- tried before "tickbox".
local TYPES = { "multipletickbox", "textentry", "colorpicker", "combobox", "tickbox", "keybind", "slider" }

local function isType(name)
    for _, t in ipairs(TYPES) do
        if t == name then return true end
    end
    return false
end

-- Splits on "|" keeping empty fields ("textentry|M|x|" has an empty value).
local function splitFields(line)
    local fields = {}
    for field in string.gmatch(line .. "|", "([^|]*)|") do
        table.insert(fields, field)
    end
    return fields
end

-- One line of the file, as the one or more option lines it holds.
local function unglue(line)
    local fields = splitFields(line)
    local count = #fields
    if count <= 4 or (count - 1) % 3 ~= 0 or not isType(fields[1]) then
        return { line }
    end
    local lines = {}
    local optionType = fields[1]
    for i = 2, count, 3 do
        local value = fields[i + 2]
        local nextType = nil
        if i + 2 < count then
            for _, t in ipairs(TYPES) do
                if #value >= #t and string.sub(value, -#t) == t then
                    nextType = t
                    break
                end
            end
            if nextType == nil then return { line } end
            value = string.sub(value, 1, #value - #nextType)
        end
        table.insert(lines, optionType .. "|" .. fields[i] .. "|" .. fields[i + 1] .. "|" .. value)
        optionType = nextType
    end
    return lines
end

-- Every option line in the file, glued ones split apart.
local function readLines()
    local lines = {}
    local file = getFileReader(FILE_NAME, false)
    if file == nil then return lines end
    while true do
        local line = file:readLine()
        if line == nil then break end
        if line ~= "" then
            for _, part in ipairs(unglue(line)) do
                table.insert(lines, part)
            end
        end
    end
    file:close()
    return lines
end

-- The lines save would lose: mod or option not registered in this session. When a
-- line appears twice the later one wins, as it would in load.
local function linesToKeep(modOptions)
    local order, byKey = {}, {}
    for _, line in ipairs(readLines()) do
        local fields = splitFields(line)
        local options = #fields >= 4 and modOptions.Dict[fields[2]] or nil
        if options == nil or options.dict[fields[3]] == nil then
            local key = #fields >= 4 and (fields[2] .. "|" .. fields[3]) or line
            if byKey[key] == nil then table.insert(order, key) end
            byKey[key] = line
        end
    end
    local lines = {}
    for _, key in ipairs(order) do
        table.insert(lines, byKey[key])
    end
    return lines
end

local function install()
    if PZAPI == nil or PZAPI.ModOptions == nil then return end
    local modOptions = PZAPI.ModOptions
    local vanillaLoad = modOptions.load
    local vanillaSave = modOptions.save

    function modOptions:load(...)
        local lines = readLines()
        local index = 0
        local reader = {
            readLine = function()
                index = index + 1
                return lines[index]
            end,
            close = function() end,
        }
        local realGetFileReader = getFileReader
        getFileReader = function(name, createIfNull)
            if name == FILE_NAME then return reader end
            return realGetFileReader(name, createIfNull)
        end
        local ok, err = pcall(vanillaLoad, self, ...)
        getFileReader = realGetFileReader
        if not ok then error(err) end
    end

    function modOptions:save(...)
        local kept = linesToKeep(modOptions)
        local withEndings = {}
        for i, line in ipairs(kept) do
            withEndings[i] = line .. "\r\n"
        end
        modOptions.OtherOptions = withEndings
        local ok, err = pcall(vanillaSave, self, ...)
        modOptions.OtherOptions = kept
        if not ok then error(err) end
    end
end

-- ---------------------------------------------------------------------------
-- Key bindings

local KEYS_FILE = "keysB42.ini"

-- The binding a "Name=key:..." line is for, or nil for the VERSION line, section
-- headers ("[Player Control]") and anything else the loader would not read as one.
local function keyName(line)
    if string.sub(line, 1, 1) == "[" then return nil end
    local name = string.match(line, "^([^=]+)=")
    if name == nil or name == "VERSION" then return nil end
    return name
end

-- The binding lines of the key file as it is now, before a writer truncates it.
local function readKeyLines()
    local lines = {}
    local file = getFileReader(KEYS_FILE, false)
    if file == nil then return lines end
    while true do
        local line = file:readLine()
        if line == nil then break end
        if keyName(line) then table.insert(lines, line) end
    end
    file:close()
    return lines
end

-- Stands in for the Java writer: every write goes straight through, and close
-- first appends the old lines of bindings nobody wrote this time.
local function keepingWriter(writer, oldLines)
    local written = {}
    local proxy = {}

    local function note(text)
        for line in string.gmatch(text, "[^\r\n]+") do
            local name = keyName(line)
            if name then written[name] = true end
        end
    end

    function proxy:write(text)
        note(text)
        return writer:write(text)
    end

    function proxy:writeln(text)
        note(text)
        return writer:writeln(text)
    end

    function proxy:close()
        for _, line in ipairs(oldLines) do
            local name = keyName(line)
            if not written[name] then
                written[name] = true
                writer:write(line .. "\r\n")
            end
        end
        return writer:close()
    end

    return proxy
end

local function installKeys()
    local realGetFileWriter = getFileWriter
    getFileWriter = function(name, createIfNull, append)
        if name ~= KEYS_FILE or append then
            return realGetFileWriter(name, createIfNull, append)
        end
        local oldLines = readKeyLines()
        local writer = realGetFileWriter(name, createIfNull, append)
        if writer == nil or #oldLines == 0 then return writer end
        return keepingWriter(writer, oldLines)
    end
end

install()
installKeys()
