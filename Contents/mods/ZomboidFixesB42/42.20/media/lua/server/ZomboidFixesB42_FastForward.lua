--[[
    Zomboid Fixes B42.20 -- server, fast forward in multiplayer

    Multiplayer has no speed controls. UIManager only puts zombie.ui.SpeedControls
    on screen when !GameClient.client, SpeedControlsHandler.onKeyPressed returns
    straight away on a client, and SpeedControls.getCurrentGameSpeed() always
    answers 1 in multiplayer.

    The engine can still run faster, though. The debug /setTimeSpeed command
    (SetTimeSpeedCommand) does it in two lines:

        GameTime.getInstance().setMultiplier(newSpeed);
        INetworkPacket.sendToAll(PacketType.SetMultiplier);   -- clients setMultiplier too

    and that is what this does, with a vote in front of it. Every living player
    picks one of the single player speeds; the game only runs faster when all of
    them have picked it, and then at the slowest speed anyone picked. If anyone
    goes back to normal speed, every vote is cleared and everyone has to pick
    again -- one player stopping stops it for good, not just until the others
    notice.

    Deliberately not GameServer.fastForward, the flag vanilla raises when every
    player is asleep. That path is built for nobody watching: clients delete every
    zombie they can see (IsoZombie.update, GameClient.fastForward) and the packet
    anti-cheat is switched off (PacketValidator.update).

    Single player keeps its own speed controls, so none of this runs there.
--]]

if not isServer() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- A zombie this close to anyone, on the same floor, stops fast forward for
-- everyone -- as happens in single player, where IsoPlayer's line of sight update
-- drops the speed to 1 for a zombie within 4 tiles (7 with a crowd in view).
local NEAR_ZOMBIE = 4
-- A zombie this close that is already coming for someone stops it too.
local HUNTING_ZOMBIE = 7

-- onlineID -> chosen speed. Only speeds above 1 are kept: no entry is normal speed.
local votes = {}
-- The multiplier this file last gave GameTime.
local applied = 1
local started = false
-- What the clients were last told, so they are only told again when it changes.
local lastSignature = nil

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MultiplayerFastForward == true
end

local function livingPlayers()
    local result = {}
    local online = getOnlinePlayers()
    if not online then return result end
    for i = 0, online:size() - 1 do
        local player = online:get(i)
        if player and not player:isDead() then
            table.insert(result, player)
        end
    end
    return result
end

--- Count the votes. Returns the speed the game should run at, and the state the
-- clients need to draw the speed controls.
local function tally()
    local players = livingPlayers()
    local state = { total = #players, votes = {} }
    local speed = nil
    local asleep = 0
    -- Only the living keep a vote. Online IDs are reused, so a vote left behind by
    -- someone who logged out would otherwise be handed to whoever joins next.
    local kept = {}

    for _, player in ipairs(players) do
        local id = player:getOnlineID()
        local vote = votes[id] or 1
        if vote > 1 then kept[id] = vote end
        state.votes[tostring(id)] = vote
        if not speed or vote < speed then speed = vote end
        if player:isAsleep() then asleep = asleep + 1 end
    end
    votes = kept

    -- Everyone asleep is vanilla's own fast forward, and GameTime.getMultiplier()
    -- multiplies the two together. Stand aside rather than run sleep at forty times
    -- its own speed; the votes stay for when they wake.
    if not speed or asleep == #players then speed = 1 end

    state.speed = speed
    return speed, state
end

local function signatureOf(state)
    local parts = { state.speed, state.total }
    for id, vote in pairs(state.votes) do
        table.insert(parts, id .. "=" .. vote)
    end
    table.sort(parts, function(a, b) return tostring(a) < tostring(b) end)
    return table.concat(parts, ",")
end

local function broadcast(state)
    lastSignature = signatureOf(state)
    sendServerCommand(ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FAST_FORWARD_STATE, state)
end

local function apply(speed)
    getGameTime():setMultiplier(speed)
    applied = speed
end

--- Clear every vote and bring the game back to normal speed at once.
local function stopAll()
    votes = {}
    apply(1)
    local _, state = tally()
    broadcast(state)
end

local function zombieNear(player)
    if player:isGhostMode() then return false end
    local cell = getCell()
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for x = px - HUNTING_ZOMBIE, px + HUNTING_ZOMBIE do
        for y = py - HUNTING_ZOMBIE, py + HUNTING_ZOMBIE do
            local square = cell:getGridSquare(x, y, pz)
            if square then
                local movers = square:getMovingObjects()
                for i = 0, movers:size() - 1 do
                    local zombie = movers:get(i)
                    if instanceof(zombie, "IsoZombie") and not zombie:isDead() then
                        local distance = player:DistTo(zombie)
                        if distance <= NEAR_ZOMBIE or zombie:getTarget() == player then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

local function anyZombieNear()
    for _, player in ipairs(livingPlayers()) do
        if zombieNear(player) then return true end
    end
    return false
end

local function onTick()
    if not isEnabled() then return end

    if not started then
        -- GameTime saves its multiplier into the world, so a server stopped while
        -- fast forwarding would come back up still fast forwarding.
        started = true
        apply(1)
    end

    if applied > 1 then
        -- Anything in vanilla that drops the speed back to normal -- IsoPlayer's own
        -- zombie check also runs on the server -- counts as stopping it for everyone.
        if anyZombieNear() or getGameTime():getTrueMultiplier() < applied - 0.01 then
            stopAll()
            return
        end
    end

    local speed, state = tally()
    if speed ~= applied then
        apply(speed)
    end
    if signatureOf(state) ~= lastSignature then
        broadcast(state)
    end
end

local function onVote(player, args)
    if player:isDead() then return end
    local speed = tonumber(args.speed)
    if not ZomboidFixesB42.isFastForwardSpeed(speed) then return end

    if speed == 1 then
        stopAll()
        return
    end

    votes[player:getOnlineID()] = speed
    onTick()
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or not player then return end
    if not isEnabled() then return end

    if command == ZomboidFixesB42.CMD_FAST_FORWARD_VOTE then
        onVote(player, args or {})
    elseif command == ZomboidFixesB42.CMD_FAST_FORWARD_HELLO then
        -- A player who has just joined has no vote, which is normal speed, so the
        -- tally will already have changed; this makes sure they hear it regardless.
        local _, state = tally()
        sendServerCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FAST_FORWARD_STATE, state)
    end
end

Events.OnTick.Add(onTick)
Events.OnClientCommand.Add(onClientCommand)
