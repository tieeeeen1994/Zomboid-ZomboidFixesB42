--[[
    Zomboid Fixes B42.20 -- client, key bindings declared twice, hotbar keys ignoring Shift

    Mods add keys to the Key Bindings tab by appending to the global keyBinding
    table (shared/keyBinding.lua). Nothing stops two entries from having the same
    name, and Plysken Attachments Reborn (PAR_Keybinds.lua) declares "Hotbar 6",
    "Hotbar 7" and "Hotbar 8" again under its own [PARKeys] section, with keys 6, 7
    and 8, although vanilla B42 already has them under [Hotkeys]. The game keeps one
    binding per name (Core.keyMaps, a HashMap), but the options screen keeps both rows
    and treats them inconsistently:

        MainOptions.loadKeys (OptionScreens/MainOptions.lua:3478) makes one row per
            entry, but remembers only the last one per name (knownKeys[bind.value]
            = bind, :3513), so keysB42.ini is read into the [PARKeys] row only. The
            [Hotkeys] row always shows its default key, 6, 7 or 8.
        keyPressHandler (:3806) also takes the last row of that name, so rebinding
            the [Hotkeys] row changes the [PARKeys] row and the row clicked keeps
            showing 6, 7 or 8.
        ISSetKeybindDialog:onClear (ISUI/ISSetKeybindDialog.lua:86) takes the first
            row, so clearing the [PARKeys] row clears the [Hotkeys] one.
        saveKeys (:3711) writes both rows: the [Hotkeys] one with its default key.

    The binding that works is the last row's, so keys still work, but the [Hotkeys]
    rows cannot be set and show the wrong keys. At the main menu, where that mod
    is not loaded, the same file shows correctly, so it looks fixed after quitting.

    Before every loadKeys, a binding whose name is already in keyBinding is
    dropped, keeping the first one (vanilla's own for these), plus a section header
    left with nothing under it. A file saved while both rows existed still loads
    right: loadKeys reads every line of a name and the later line wins, and the
    next save writes each name once.

    The same mod replaces ISHotbar:getSlotForKey (ISHotbar.lua:680, called by the
    hotbar's key handlers ~726, ~750, ~803) with "key == getCore():getKey(name)",
    which ignores Shift, Ctrl and Alt: a slot bound to Shift+/ is also used by a
    plain /. Vanilla's own version uses getCore():isKey (Core.invalidBindingShiftCtrl
    checks the modifiers), for slots 1 to 8 only. At OnGameStart, after every mod's
    files have loaded, getSlotForKey is replaced with vanilla's isKey test over
    every "Hotbar <n>" binding in keyBinding (20 with that mod), which is vanilla's
    function when no mod adds slots.

    No sandbox option: key bindings belong to each player's own computer and are
    mostly loaded and saved at the main menu, where no sandbox is loaded, so it is
    always on.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isHeader(bind)
    return type(bind.value) == "string" and string.sub(bind.value, 1, 1) == "["
end

-- Drops every binding whose name came earlier in keyBinding, and any section header
-- this leaves empty. Edits the global table in place, since other files hold it.
local function dropDuplicateBinds()
    if type(keyBinding) ~= "table" then return end
    local seen = {}
    local result = {}
    local headerIndex = nil
    local keptInSection, droppedInSection = 0, 0

    local function closeSection()
        if headerIndex ~= nil and keptInSection == 0 and droppedInSection > 0 then
            table.remove(result, headerIndex)
        end
    end

    for _, bind in ipairs(keyBinding) do
        if isHeader(bind) then
            closeSection()
            table.insert(result, bind)
            headerIndex = #result
            keptInSection, droppedInSection = 0, 0
        elseif bind.value ~= nil and seen[bind.value] then
            droppedInSection = droppedInSection + 1
            print("[ZomboidFixesB42] Key binding \"" .. tostring(bind.value)
                .. "\" is declared twice; keeping the first")
        else
            if bind.value ~= nil then seen[bind.value] = true end
            table.insert(result, bind)
            keptInSection = keptInSection + 1
        end
    end
    closeSection()

    local count = #keyBinding
    if #result == count then return end
    for i = 1, count do
        keyBinding[i] = result[i]
    end
end

if MainOptions and MainOptions.loadKeys then
    local vanillaLoadKeys = MainOptions.loadKeys
    function MainOptions.loadKeys(...)
        dropDuplicateBinds()
        return vanillaLoadKeys(...)
    end
end

-- The "Hotbar <n>" binding names in slot order, up to the highest n declared.
local function hotbarKeyNames()
    local count = 0
    for _, bind in ipairs(keyBinding or {}) do
        local n = type(bind.value) == "string" and tonumber(string.match(bind.value, "^Hotbar (%d+)$"))
        if n and n > count then count = n end
    end
    local names = {}
    for i = 1, count do
        names[i] = "Hotbar " .. string.format("%d", i)
    end
    return names
end

local function installSlotKeys()
    if not ISHotbar then return end
    local names = hotbarKeyNames()
    function ISHotbar:getSlotForKey(key)
        local core = getCore()
        for i, name in ipairs(names) do
            if core:isKey(name, key) then return i end
        end
        return -1
    end
end

Events.OnGameStart.Add(installSlotKeys)
