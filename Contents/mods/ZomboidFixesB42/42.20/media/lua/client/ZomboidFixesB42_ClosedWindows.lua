--[[
    Zomboid Fixes B42.20 -- client, a closed chat window and Lua console stay closed

    Chat (client/Chat/ISChat.lua, 42.21): ISChat.createChat (OnGameStart, multiplayer
    only) registers the window with ISLayoutManager, whose restore hides it when
    layout.ini says visible=false, and then calls ISChat.instance:setVisible(true) on
    the next line, so the chat opens on every join whatever the player did. Closing it
    is the window's X (ISChat:close, ignored while the chat is locked); it comes back
    with the chat key (ISChat:focus).

    Lua console (zombie/ui/UIDebugConsole, -debug only): a Java window that
    UIManager.init creates on every game start, visible when the debug option
    UI.DebugConsole.StartVisible is on (default on; DebugOptions keeps it in
    <cachedir>/debug-options.ini). The Toggle Lua Console key (GameWindow, only with
    -debug) and its own close button (NewWindow.ButtonClicked "close") just hide it;
    neither touches the option, so it is back at the next start.

    So the chat's open/closed state is kept in Zomboid/Lua/ZomboidFixesB42_Windows.ini,
    written when the player closes or opens it and applied after vanilla's createChat
    (this OnGameStart handler is added after it). The console's state is written into
    its own debug option (setBoolean + save, as the Debug Options window does) whenever
    it changes. Hiding every UI (the Toggle UI key, the Esc menu, joypad setup) goes
    through ISUIHandler.setVisibleAllUI, which lists what it hid in
    ISUIHandler.visibleUI until it shows them again; no change is recorded meanwhile, so
    quitting from the Esc menu does not count as closing.
--]]

require "Chat/ISChat"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.RememberClosedWindows == true
end

local STATE_FILE = "ZomboidFixesB42_Windows.ini"
local CONSOLE_OPTION = "UI.DebugConsole.StartVisible"

local chatVisible = nil

local function loadState()
    local reader = getFileReader(STATE_FILE, false)
    if not reader then return end
    while true do
        local line = reader:readLine()
        if not line then break end
        local value = string.match(line, "^chat=(%a+)$")
        if value then chatVisible = value == "true" end
    end
    reader:close()
end

local function saveChat(visible)
    if not isEnabled() or chatVisible == visible then return end
    chatVisible = visible
    local writer = getFileWriter(STATE_FILE, true, false)
    writer:write("chat=" .. tostring(visible) .. "\n")
    writer:close()
end

-- A hide-all is in effect while it remembers what it hid.
local function allUIShown()
    return ISUIHandler == nil or (ISUIHandler.allUIVisible ~= false and #ISUIHandler.visibleUI == 0)
end

loadState()

-- Chat. The X button calls self.close as it was when the window was built (at game
-- start, after this file loaded), so this wrapper is the one it calls.

local previousClose = ISChat.close
function ISChat:close(...)
    previousClose(self, ...)
    if not self:getIsVisible() and allUIShown() then saveChat(false) end
end

local previousFocus = ISChat.focus
function ISChat:focus(...)
    previousFocus(self, ...)
    saveChat(true)
end

Events.OnGameStart.Add(function()
    if not isEnabled() or chatVisible ~= false then return end
    local chat = ISChat.instance or ISChat.chat
    if chat then
        chat:unfocus()
        chat:setVisible(false)
    end
end)

-- Lua console.

local consoleSeen = nil

Events.OnTick.Add(function()
    if not getCore():getDebug() or not isEnabled() then return end
    local console = UIManager.getDebugConsole()
    if not console then return end
    local visible = console:isVisible()
    if consoleSeen == nil then
        consoleSeen = visible
        return
    end
    if visible == consoleSeen or not allUIShown() then return end
    consoleSeen = visible
    local options = getDebugOptions()
    if options:getBoolean(CONSOLE_OPTION) ~= visible then
        options:setBoolean(CONSOLE_OPTION, visible)
        options:save()
    end
end)

-- Every game start makes a new console.
Events.OnGameStart.Add(function()
    consoleSeen = nil
end)
