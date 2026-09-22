--[[
    Zomboid Fixes B42.20 -- client, fast forward in multiplayer

    Puts the single player speed controls back on screen in multiplayer, in the
    same place, with the same buttons and the same keys (Normal Speed, Fast Forward
    x1/x2/x3). A button here is a vote, not a speed: the server only speeds the
    game up once every living player has picked fast forward, runs it at the
    slowest speed anyone picked, and clears every vote the moment anyone goes back
    to normal speed. See the server file for how the speed itself is changed.

    Two single player rules come along with it:

      - Moving your character stops fast forward (IsoPlayer.updateInternal drops
        SpeedControls to 1 when the player moves). In multiplayer this also
        covers walking to something and driving, which single player allows,
        because at forty times the speed a moving player breaks the anti-cheat's
        speed limit (AntiCheatSpeed, 20) and gets kicked.
      - A zombie close to anyone stops it; the server checks that.
--]]

if not isClient() then return end

require "ISUI/ISUIElement"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)

-- The same spacing as zombie.ui.SpeedControls and its SCButton.
local BORDER = 3
local GAP = 2
local SCREEN_MARGIN = 10

local TEXTURES = {
    [1] = "Play",
    [5] = "FFwd1",
    [20] = "FFwd2",
    [40] = "Wait",
}

-- The last state the server sent. votes maps online IDs, as strings, to speeds.
local state = { speed = 1, total = 0, votes = {} }
-- The multiplier this file last set, so the debug Game Speed slider is left alone
-- whenever fast forward is not running.
local applied = nil
local speedBar = nil

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MultiplayerFastForward == true
end

local function voteOf(player)
    if not player then return 1 end
    return state.votes[tostring(player:getOnlineID())] or 1
end

local function localPlayers()
    local result = {}
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and not player:isDead() then
            table.insert(result, player)
        end
    end
    return result
end

--- How many players have picked this speed or faster.
local function readyFor(speed)
    local count = 0
    for _, vote in pairs(state.votes) do
        if vote >= speed then count = count + 1 end
    end
    return count
end

--- Vote for a speed on behalf of everyone playing on this machine. Split screen
-- players are all counted by the server, so they all have to vote.
local function vote(speed)
    local players = localPlayers()
    if #players == 0 then return end

    if speed == 1 then
        -- Cancelling clears everyone, so once is enough.
        sendClientCommand(players[1], ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FAST_FORWARD_VOTE, { speed = 1 })
        -- Shown straight away rather than after the round trip, which also stops
        -- a moving player sending this again every frame until the reply lands.
        for id in pairs(state.votes) do state.votes[id] = 1 end
        return
    end

    for _, player in ipairs(players) do
        sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FAST_FORWARD_VOTE, { speed = speed })
        state.votes[tostring(player:getOnlineID())] = speed
    end
end

local function applySpeed()
    local gameTime = getGameTime()
    if state.speed > 1 then
        -- Held every tick while running: vanilla dialogs and right clicks call
        -- SpeedControls.SetCurrentGameSpeed(1), which resets the multiplier here.
        if gameTime:getTrueMultiplier() ~= state.speed then
            gameTime:setMultiplier(state.speed)
        end
        applied = state.speed
    elseif applied then
        gameTime:setMultiplier(1)
        applied = nil
    end
end

local function explain(reason, by)
    local player = getSpecificPlayer(0)
    if not player then return end
    local text
    if reason == "cancelled" then
        if by and by ~= player:getUsername() then
            text = getText("IGUI_ZomboidFixesB42_FastForward_CancelledBy", by)
        else
            text = getText("IGUI_ZomboidFixesB42_FastForward_Cancelled")
        end
    elseif reason == "zombie" then
        text = getText("IGUI_ZomboidFixesB42_FastForward_Zombie")
    else
        text = getText("IGUI_ZomboidFixesB42_FastForward_Stopped")
    end
    HaloTextHelper.addText(player, text)
end

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_FAST_FORWARD_STATE then return end
    if type(args) ~= "table" then return end

    local wasInvolved = state.speed > 1 or voteOf(getSpecificPlayer(0)) > 1

    state = {
        speed = tonumber(args.speed) or 1,
        total = tonumber(args.total) or 0,
        votes = {},
    }
    if type(args.votes) == "table" then
        for id, speed in pairs(args.votes) do
            state.votes[tostring(id)] = tonumber(speed) or 1
        end
    end

    applySpeed()

    if args.reason and wasInvolved then
        explain(args.reason, args.by)
    end
end

-- Speed bar ------------------------------------------------------------------

local SpeedBar = ISUIElement:derive("ZomboidFixesB42_SpeedBar")

function SpeedBar:new()
    local o = ISUIElement.new(self, 0, 0, 1, 1)
    o.buttons = {}
    local x, height = 0, 0
    for _, speed in ipairs(ZomboidFixesB42.FAST_FORWARD_SPEEDS) do
        local name = TEXTURES[speed]
        local off = getTexture("media/ui/speedControls/" .. name .. "_Off.png")
        local on = getTexture("media/ui/speedControls/" .. name .. "_On.png")
        local w = off:getWidth() + BORDER * 2
        local h = off:getHeight() + BORDER * 2
        table.insert(o.buttons, { speed = speed, x = x, w = w, h = h, off = off, on = on })
        x = x + w + GAP
        height = math.max(height, h)
    end
    o.buttonHeight = height
    o:setWidth(x - GAP)
    o:setHeight(height)
    o.anchorLeft = false
    o.anchorRight = true
    return o
end

function SpeedBar:buttonAt(x, y)
    if y < 0 or y > self.buttonHeight then return nil end
    for _, button in ipairs(self.buttons) do
        if x >= button.x and x < button.x + button.w then return button end
    end
    return nil
end

--- Where zombie.ui.SpeedControls goes: the right edge, under the clock.
function SpeedBar:reposition()
    self:setX(getCore():getScreenWidth() - self.width - SCREEN_MARGIN)
    local clock = UIManager.getClock()
    if clock and clock:isVisible() then
        self:setY(clock:getY() + clock:getHeight() + SCREEN_MARGIN)
    else
        self:setY(SCREEN_MARGIN)
    end
end

-- getText formats a Lua number as "5.0".
local function int(n)
    return tostring(math.floor(n))
end

local function readyText(speed)
    return getText("IGUI_ZomboidFixesB42_FastForward_Ready", int(speed), int(readyFor(speed)), int(state.total))
end

function SpeedBar:statusText(hovered, myVote)
    if hovered then
        if hovered.speed == 1 then
            return getText("IGUI_ZomboidFixesB42_FastForward_NormalHint")
        end
        return readyText(hovered.speed)
    end
    if state.speed > 1 then
        return getText("IGUI_ZomboidFixesB42_FastForward_Running", int(state.speed))
    end
    if myVote > 1 then
        return readyText(myVote)
    end
    return nil
end

function SpeedBar:prerender()
    self:reposition()
end

function SpeedBar:render()
    local myVote = voteOf(getSpecificPlayer(0))
    local hovered = self:isMouseOver() and self:buttonAt(self:getMouseX(), self:getMouseY()) or nil

    -- Drawn as SpeedControls.SCButton draws them: a black backing, the _On icon
    -- for the chosen or hovered button, and the chosen one nudged down a pixel.
    for _, button in ipairs(self.buttons) do
        local chosen = button.speed == myVote
        local nudge = chosen and 1 or 0
        local dy = BORDER + nudge

        self:drawRect(button.x, nudge, button.w, button.h, 0.75, 0, 0, 0)
        if chosen or button == hovered then
            self:drawTexture(button.on, button.x + BORDER, dy, 1, 1, 1, 1)
        else
            self:drawTexture(button.off, button.x + BORDER, dy, 0.85, 1, 1, 1)
        end
    end

    -- To the left of the buttons, outside the element: nothing clips it, and
    -- keeping it out of the bounds means it never catches a click.
    local text = self:statusText(hovered, myVote)
    if text then
        local textWidth = getTextManager():MeasureStringX(UIFont.Small, text)
        local right = -GAP * 2
        local pad = BORDER * 2
        self:drawRect(right - textWidth - pad * 2, 0, textWidth + pad * 2, self.buttonHeight, 0.75, 0, 0, 0)
        self:drawTextRight(text, right - pad, (self.buttonHeight - FONT_HGT_SMALL) / 2, 1, 1, 1, 0.9, UIFont.Small)
    end
end

function SpeedBar:onMouseDown(x, y)
    local button = self:buttonAt(x, y)
    if button then
        vote(button.speed)
        getSoundManager():playUISound("UIActivateButton")
    end
    return true
end

function SpeedBar:onMouseUp(x, y)
    return true
end

function SpeedBar:update()
    local player = getSpecificPlayer(0)
    self:setVisible(player ~= nil and not player:isDead())
end

-- Events ---------------------------------------------------------------------

local function isMoving(player)
    if player:isPlayerMoving() then return true end
    local vehicle = player:getVehicle()
    return vehicle ~= nil and math.abs(vehicle:getCurrentSpeedKmHour()) > 0.8
end

local function onPlayerUpdate(player)
    if not player or not player:isLocalPlayer() then return end
    if voteOf(player) > 1 and isMoving(player) then
        vote(1)
    end
end

local function onTick()
    applySpeed()
end

local function onKeyPressed(key)
    if not MainScreen.instance or not MainScreen.instance.inGame or MainScreen.instance:getIsVisible() then
        return
    end
    local core = getCore()
    if core:isKey("Normal Speed", key) then
        vote(1)
    elseif core:isKey("Fast Forward x1", key) then
        vote(5)
    elseif core:isKey("Fast Forward x2", key) then
        vote(20)
    elseif core:isKey("Fast Forward x3", key) then
        vote(40)
    end
end

local function onGameStart()
    if not isEnabled() then return end

    speedBar = SpeedBar:new()
    speedBar:initialise()
    speedBar:addToUIManager()

    local player = getSpecificPlayer(0)
    if player then
        sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FAST_FORWARD_HELLO, {})
    end

    Events.OnServerCommand.Add(onServerCommand)
    Events.OnPlayerUpdate.Add(onPlayerUpdate)
    Events.OnTick.Add(onTick)
    Events.OnKeyPressed.Add(onKeyPressed)
end

Events.OnGameStart.Add(onGameStart)
