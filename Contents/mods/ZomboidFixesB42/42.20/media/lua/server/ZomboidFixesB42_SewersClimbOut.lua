--[[
    Zomboid Fixes B42.20 -- server, climbing out of the Sewers mod in multiplayer

    Sewers Under Every Town (Workshop 3810188405, mod id Sewars) takes a player down a
    manhole and back up a ladder by moving them a whole level on the spot. The server
    grants the climb (SEWClimb:complete -> SEW.Server.grant) and answers "go"; the
    player's own client then moves its character (SEW_Client.arrive, setX/Y/Z), and
    the server learns the new position from the next player update. Down works, up
    does not: the player shows on the street for a moment, the screen stays black, and
    they are back in the sewer.

    What puts them back is the server's no-clip check. Every PlayerPacket goes through
    AntiCheat.NoClip (PlayerPacketReliable / Unreliable @PacketSetting, run in
    PacketTypes.onServerPacket ~761) whenever the server option AntiCheatNoClip is not
    4 ("disabled", the 42.21 default; 3 "log" still checks). AntiCheatNoClip.validate
    compares the last accepted position (connection.releventPos) with the new one:

      * the "basement" branch, which lets a player step up out of a hole, needs a
        3D distance over 1.0, and straight up on the same square is exactly 1.0;
      * checkPathClamp then finds no path between the two levels (no stairs), and
        checkUnreachablePath lets a move to a higher level through only at stairs,
        a sheet rope or a burnt-out square ("targetSquare.z < sourceSquare.z"
        passes the way down, which is why climbing down works);
      * from a square next to the ladder it is the same, and diagonally next to it
        the "diagonal" branch fails instead. The Sewers mod lets a player climb from
        up to 2.6 squares away, and past 2.5 the move is "Long blocked".

    So the check fails ("Unreachable blocked"), and AntiCheatNoClip.react runs before
    the policy is even looked at: GameServer.sendTeleport back to releventPos, the
    sewer. The packet is dropped, so the server never saw the player up. Admins can't
    be kicked by anti-cheat (Capability.CantBeKickedByAnticheat), so AntiCheat.act
    returns before logging and nothing shows in any log; other players are logged,
    and kicked or banned with "kick" or "ban". A server teleport (/teleportto, the
    admin panel) gets through because GameServer.sendTeleport also calls
    AntiCheatNoClip.teleport, which exempts that player for 500 ms. Single player
    has no anti-cheat, so the climb always worked there.

    That exemption is the clean way out, but nothing reachable from Lua calls
    sendTeleport (only chat commands, teleport packets and safehouse kicks do), and
    the square flags the check accepts (haveSheetRope) have no setter. So for each
    climb that brings a player up from below, from the moment the server grants it
    until the server has taken the player's position on the street, this turns
    AntiCheatNoClip off (setValue(4): AntiCheat.isEnabled reads the option live, and
    it is the same option object, ServerOptions.instance never changes) and puts the
    previous value back. That is normally a fraction of a second, at most HOLD_MS if
    the player never arrives. During it nobody's no-clip is checked. The value is
    only changed in memory; an admin saving server options in that moment would
    write 4 to the ini, and a /reloadoptions in it is left alone (the value is only
    restored while it is still the 4 set here).

    Hooked at SEW.Net.toClient, which every "go" passes through (SEW_Net.lua, shared):
    a "go" to street level (z 0) for a player the server has below ground is a climb
    up a ladder, through a hatch or out of an outfall, or a rescue to the street.
--]]

if not isServer() then return end

local DISABLED = 4        -- AntiCheat option value meaning "disabled"
local HOLD_MS = 15000     -- the client waits up to ~10 s for the street to load before moving
local GRACE_MS = 500      -- after the server has the player up, for packets still in flight

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return not vars or vars.SewersClimbOut ~= false
end

local function noClipOption()
    local options = getServerOptions()
    return options and options:getOptionByName("AntiCheatNoClip")
end

-- username -> { player, since, deadline, arrivedAt }
local climbing = {}
local anyClimbing = false
-- The option's value before it was turned off here; nil while it is untouched.
local savedValue = nil

local function release()
    local option = noClipOption()
    if option and savedValue ~= nil and option:getValue() == DISABLED then
        option:setValue(savedValue)
    end
    savedValue = nil
end

local function watch(player, args)
    if not player or type(args) ~= "table" then return end
    local z = tonumber(args.z)
    if not z or z < 0 or player:getZ() >= -0.5 then return end
    local option = noClipOption()
    if not option then return end
    if savedValue == nil then
        local value = option:getValue()
        if value == DISABLED then return end
        savedValue = value
        option:setValue(DISABLED)
    end
    local now = getTimestampMs()
    climbing[player:getUsername()] = { player = player, since = now, deadline = now + HOLD_MS }
    anyClimbing = true
end

local function update()
    if not anyClimbing then return end
    local now = getTimestampMs()
    local done = {}
    for name, c in pairs(climbing) do
        local up = c.player:getZ() >= -0.5
        if up and not c.arrivedAt then c.arrivedAt = now end
        if c.arrivedAt and now - c.arrivedAt >= GRACE_MS then
            print(string.format("[ZomboidFixesB42] Sewers: %s climbed out with AntiCheatNoClip held off for %d ms",
                name, c.arrivedAt - c.since))
            done[#done + 1] = name
        elseif now > c.deadline then
            print("[ZomboidFixesB42] Sewers: " .. name .. " never arrived on the street; AntiCheatNoClip back on")
            done[#done + 1] = name
        end
    end
    for _, name in ipairs(done) do climbing[name] = nil end
    local left = false
    for _ in pairs(climbing) do left = true break end
    if not left then
        anyClimbing = false
        release()
    end
end

local function hook()
    local Net = SEW and SEW.Net
    if not Net or Net.zfixClimbOut or type(Net.toClient) ~= "function" then return end
    local original = Net.toClient
    Net.toClient = function(player, cmd, args)
        if cmd == "go" and isEnabled() then
            local ok, err = pcall(watch, player, args)
            if not ok then print("[ZomboidFixesB42] Sewers climb out: " .. tostring(err)) end
        end
        return original(player, cmd, args)
    end
    Net.zfixClimbOut = true
end

-- Every mod's shared files load before any server file, so SEW.Net is there now if
-- the Sewers mod is on; the second call covers a load order that differs.
hook()
Events.OnServerStarted.Add(hook)

Events.OnTick.Add(function()
    local ok, err = pcall(update)
    if not ok then
        print("[ZomboidFixesB42] Sewers climb out: " .. tostring(err))
        climbing = {}
        anyClimbing = false
        release()
    end
end)
