--[[
    Zomboid Fixes B42.20 -- client, fast forward in multiplayer

    Puts the single player speed controls back on screen in multiplayer, in the
    same place, with the same buttons and the same keys (Normal Speed, Fast Forward
    x1/x2/x3). A button here is a vote, not a speed: the server only speeds the
    game up while every living player has picked fast forward, and runs it at the
    slowest speed anyone picked. Normal Speed takes back only your own vote: the
    game drops to normal at once (it needs everyone's), but the other players keep
    theirs, so it speeds up again as soon as you vote again. See the server file for
    how the speed itself is changed.

    Three single player rules come along with it, each taking back only the vote of
    the player concerned:

      - Moving your character stops fast forward (IsoPlayer.updateInternal drops
        SpeedControls to 1 when the player moves). In multiplayer this also
        covers walking to something and driving, which single player allows,
        because at forty times the speed a moving player breaks the anti-cheat's
        speed limit (AntiCheatSpeed, 20) and gets kicked.
      - Finishing a timed action stops it. Single player makes this an option
        each player can turn off; here it always applies.
      - A zombie close to anyone stops it; the server checks that, and this one
        clears everyone's vote.

    Auto fast forward, each player's own choice (allowed by its sandbox option):
    right-clicking a fast forward button turns it yellow instead of the usual red,
    and right-clicking it again turns auto off. While a button is yellow, being busy
    with timed actions for AutoFastForwardDelay seconds (a sandbox option) votes for
    its speed on the player's behalf -- so a quick action is over before it could be
    sped up -- and the actions ending takes the vote back. So the game runs fast while every player is busy with an
    action (or has voted by hand), drops to normal while anyone is idle, and speeds
    up again as soon as they start the next one. Walking or driving also takes the
    vote back (the anti-cheat speed limit), and the player votes again once standing
    still at the action. Pressing Normal Speed holds the auto vote off until the
    player's next action, and so does the server clearing the votes for a zombie, so
    a stop is still a stop. The choice is kept on this computer (AUTO_FILE).
--]]

if not isClient() then return end

require "ISUI/ISUIElement"
require "TimedActions/ISTimedActionQueue"

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

local function isAutoEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MultiplayerFastForward == true and vars.AutoFastForwardActions == true
end

-- The speed this player picked for auto fast forward (a right-clicked button), or
-- nil when it is off. Kept per computer in Zomboid/Lua.
local AUTO_FILE = "ZomboidFixesB42_FastForward.ini"
local autoChoice = nil

local function loadAutoChoice()
    autoChoice = nil
    local reader = getFileReader(AUTO_FILE, false)
    if not reader then return end
    while true do
        local line = reader:readLine()
        if not line then break end
        local speed = tonumber(string.match(line, "^auto=(%d+)"))
        if speed and speed > 1 and ZomboidFixesB42.isFastForwardSpeed(speed) then
            autoChoice = speed
        end
    end
    reader:close()
end

local function saveAutoChoice()
    local writer = getFileWriter(AUTO_FILE, true, false)
    if not writer then return end
    writer:write("auto=" .. string.format("%d", autoChoice or 0) .. "\r\n")
    writer:close()
end

--- The speed auto fast forward votes for, or nil when it is off.
local function autoSpeed()
    if not isAutoEnabled() then return nil end
    return autoChoice
end

-- A broadcast sent before the server had our auto vote can still arrive after it;
-- a cleared vote only counts as a stop once the vote is this old.
local AUTO_GRACE_MS = 1500
-- At most one auto vote a second per player, so stopping and starting to walk
-- between actions does not flood the server.
local AUTO_REVOTE_MS = 1000

-- A break in being busy (idle, or walking to the next action) longer than this
-- starts the AutoFastForwardDelay count again; a queue of actions back to back
-- counts as one long stretch.
local AUTO_BREAK_MS = 1000

--- How long a player must have been busy before auto votes (AutoFastForwardDelay,
-- seconds), so quick actions are over before they are ever sped up.
local function autoDelayMs()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    local seconds = tonumber(vars and vars.AutoFastForwardDelay) or 5
    return math.max(0, seconds) * 1000
end

-- Local player index -> { voted, votedAt, heldFor, busySince, idleSince }: voted =
-- this player's vote is an auto vote; heldFor = the action during which auto voting
-- is held off after a stop; busySince / idleSince time the current busy stretch.
local auto = {}

local function autoOf(index)
    if not auto[index] then auto[index] = { voted = false, votedAt = 0, heldFor = nil } end
    return auto[index]
end

--- What the player is busy with: the timed action at the head of their queue, or
-- true for a busy state without one (ISTimedActionQueue.isPlayerDoingAction), or nil.
local function currentAction(player)
    if not ISTimedActionQueue.isPlayerDoingAction(player) then return nil end
    local queue = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player]
    return (queue and queue.queue and queue.queue[1]) or true
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

--- One player's own vote; speed 1 takes it back. Only that player's vote changes.
local function sendVote(player, speed)
    sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FAST_FORWARD_VOTE, { speed = speed })
    -- Shown straight away rather than after the round trip, which also stops a
    -- moving player sending this again every frame until the reply lands.
    state.votes[tostring(player:getOnlineID())] = speed
    if speed == 1 then
        -- The game needs everyone's vote, so it is back to normal speed now; this
        -- client slows down at once instead of waiting for the server to say so
        -- (a moving player at fast forward speed trips the anti-cheat).
        state.speed = 1
    end
end

--- Vote for a speed on behalf of everyone playing on this machine. Split screen
-- players are all counted by the server, so they all have to vote.
local function vote(speed)
    for _, player in ipairs(localPlayers()) do
        if speed == 1 then
            -- Normal Speed pressed: a stop holds auto voting off until this
            -- player's next action.
            local a = autoOf(player:getPlayerNum())
            a.voted = false
            a.heldFor = currentAction(player)
        end
        sendVote(player, speed)
    end
end

--- Right-clicking a fast forward button: auto at that speed, or off when it is the
-- speed already picked. A vote auto fast forward already made follows at once.
local function toggleAuto(speed)
    if autoChoice == speed then
        autoChoice = nil
    else
        autoChoice = speed
    end
    saveAutoChoice()
    for _, player in ipairs(localPlayers()) do
        local a = autoOf(player:getPlayerNum())
        -- Turning auto on is a clear wish to go faster, even during an action
        -- Normal Speed stopped.
        a.heldFor = nil
        if a.voted then
            if autoChoice then
                a.votedAt = getTimestampMs()
                sendVote(player, autoChoice)
            else
                a.voted = false
                sendVote(player, 1)
            end
        end
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

local function onServerCommand(module, command, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_FAST_FORWARD_STATE then return end
    if type(args) ~= "table" then return end

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
        if not isAutoEnabled() then
            return readyText(hovered.speed)
        end
        if hovered.speed == autoChoice then
            return getText("IGUI_ZomboidFixesB42_FastForward_AutoOn", int(hovered.speed))
        end
        return readyText(hovered.speed) .. getText("IGUI_ZomboidFixesB42_FastForward_AutoHint")
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

    local auto = autoSpeed()

    -- Drawn as SpeedControls.SCButton draws them: a black backing, the _On icon
    -- (red) for the chosen or hovered button, and the chosen one nudged down a pixel.
    -- The auto speed is yellow instead: the grey _Off icon tinted.
    for _, button in ipairs(self.buttons) do
        local chosen = button.speed == myVote
        local nudge = chosen and 1 or 0
        local dy = BORDER + nudge

        self:drawRect(button.x, nudge, button.w, button.h, 0.75, 0, 0, 0)
        if button.speed == auto then
            local lift = button == hovered and 1 or 0.9
            self:drawTexture(button.off, button.x + BORDER, dy, 1, lift, lift * 0.85, 0.1)
        elseif chosen or button == hovered then
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

--- Right-click a fast forward button: auto fast forward at that speed, on or off.
function SpeedBar:onRightMouseDown(x, y)
    local button = self:buttonAt(x, y)
    if button and button.speed > 1 and isAutoEnabled() then
        toggleAuto(button.speed)
        getSoundManager():playUISound("UIActivateButton")
    end
    return true
end

function SpeedBar:onRightMouseUp(x, y)
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
        -- Only this player's vote. An auto vote comes again once standing still.
        autoOf(player:getPlayerNum()).voted = false
        sendVote(player, 1)
    end
end

-- Local players, by index, who were busy with a timed action last tick.
local wasDoingAction = {}

--- Finishing an action stops fast forward, as ISTimedActionQueue.onTick does in
-- single player -- except that there it is the player's own choice (the "return
-- to normal speed when timed actions finish" option), and here it always applies.
local function checkActionsFinished()
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        local doing = player ~= nil and not player:isDead() and ISTimedActionQueue.isPlayerDoingAction(player)
        -- An auto vote is taken back by updateAutoVotes instead.
        if wasDoingAction[i] and not doing and voteOf(player) > 1 and not autoOf(i).voted then
            sendVote(player, 1)
        end
        wasDoingAction[i] = doing
    end
end

--- Auto fast forward: vote for each local player busy with an action, take the vote
-- back when the action is over or the player moves.
local function updateAutoVotes()
    local speed = autoSpeed()
    local enabled = speed ~= nil
    local delayMs = autoDelayMs()
    local now = getTimestampMs()
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        local a = autoOf(i)
        if not player or player:isDead() then
            a.voted = false
            a.heldFor = nil
            a.busySince, a.idleSince = nil, nil
        else
            local current = currentAction(player)
            if a.heldFor ~= nil and a.heldFor ~= current then a.heldFor = nil end
            local busy = enabled and current ~= nil and not isMoving(player)
            if busy then
                a.busySince = a.busySince or now
                a.idleSince = nil
            elseif a.busySince then
                a.idleSince = a.idleSince or now
                if now - a.idleSince > AUTO_BREAK_MS then a.busySince, a.idleSince = nil, nil end
            end
            local myVote = voteOf(player)
            if a.voted then
                if not busy then
                    a.voted = false
                    if myVote > 1 then sendVote(player, 1) end
                elseif myVote <= 1 and now - a.votedAt > AUTO_GRACE_MS then
                    -- Cleared by the server (a zombie close to someone): a stop
                    -- holds until the next action.
                    a.voted = false
                    a.heldFor = current
                end
            elseif busy and a.heldFor == nil and myVote <= 1 and now - a.votedAt > AUTO_REVOTE_MS
                    and now - a.busySince >= delayMs then
                a.voted = true
                a.votedAt = now
                sendVote(player, speed)
            end
        end
    end
end

local function onTick()
    checkActionsFinished()
    updateAutoVotes()
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

    loadAutoChoice()
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
