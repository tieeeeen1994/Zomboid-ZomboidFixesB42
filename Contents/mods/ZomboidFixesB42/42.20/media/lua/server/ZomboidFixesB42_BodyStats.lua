--[[
    Zomboid Fixes B42.20 -- server, body stats editor

    Reads and changes a player's body stats for an admin's editor window. See the
    shared file for why this cannot be done on the client.

        bodyStatsRequest { target }                     -> bodyStatsState
        bodyStatsSet     { target, session, values }    -> bodyStatsState

    values maps a field key to { v = value, seq = n }. Every reply carries the
    target's current values, so the window always shows the server's copy, never the
    admin's own out-of-date copy of another player.

    Client commands are reliable but not ordered, so while a slider is dragged a
    late packet could carry an older value than one already applied. Each change is
    numbered by the client, and one older than the newest already applied to that
    field is dropped. The numbers start again when the client reconnects, which it
    marks with a new session.

    Only roles with CanModifyBodyStats (admin and moderator by default) may use
    this, and never on a player whose role ranks above their own. Every change is
    written to the admin log, like the server's own admin commands.
--]]

if not isServer() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local BodyStats = ZomboidFixesB42.BodyStats

-- A set command never carries more fields than the editor has; this only stops a
-- tampered client from handing us an unbounded table to walk.
local MAX_FIELDS_PER_COMMAND = 64

-- Per admin username: { session = s, seqs = { ["target|key"] = seq }, replies = n }
local admins = {}

local function stateFor(admin, session)
    local name = admin:getUsername()
    local state = admins[name]
    if not state then
        state = { session = session, seqs = {}, replies = 0 }
        admins[name] = state
    elseif session ~= nil and state.session ~= session then
        state.session = session
        state.seqs = {}
    end
    return state
end

local function findOnlinePlayer(username)
    if type(username) ~= "string" then return nil end
    local list = getOnlinePlayers()
    if not list then return nil end
    for i = 0, list:size() - 1 do
        local player = list:get(i)
        if player and player:getUsername() == username then return player end
    end
    return nil
end

--- Answer the admin. status is "ok", "offline", "dead" or "denied"; values and
-- acks only come with "ok".
local function reply(admin, username, status, target, acks)
    local state = stateFor(admin, nil)
    state.replies = state.replies + 1

    local args = {
        target = username,
        status = status,
        n = state.replies,
    }
    if target then
        args.values = BodyStats.read(target)
        args.acks = acks
    end
    sendServerCommand(admin, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_BODY_STATS_STATE, args)
end

--- The target, or nil after telling the admin why not.
local function resolveTarget(admin, username)
    if type(username) ~= "string" then return nil end

    local target = findOnlinePlayer(username)
    if not target then
        reply(admin, username, "offline")
        return nil
    end
    if not BodyStats.canEdit(admin, target) then
        reply(admin, username, "denied")
        return nil
    end
    if target:isDead() then
        reply(admin, username, "dead")
        return nil
    end
    return target
end

local function onRequest(admin, args)
    local username = args.target
    local target = resolveTarget(admin, username)
    if not target then return end
    reply(admin, username, "ok", target)
end

local function formatValue(value)
    if type(value) == "boolean" then return tostring(value) end
    return string.format("%.3f", value)
end

local function onSet(admin, args)
    local username = args.target
    local target = resolveTarget(admin, username)
    if not target then return end
    if type(args.values) ~= "table" then return end

    local state = stateFor(admin, args.session)
    local changed = {}
    local acks = {}
    local logged = {}
    local count = 0

    for key, change in pairs(args.values) do
        count = count + 1
        if count > MAX_FIELDS_PER_COMMAND then break end

        local field = BodyStats.getField(key)
        local seq = type(change) == "table" and tonumber(change.seq) or nil
        -- God mode and invisibility go through the server's own commands instead
        -- (see the shared file), so they are refused here.
        if field and not field.command and seq then
            local seqKey = username .. "|" .. key
            local last = state.seqs[seqKey]
            if not last or seq > last then
                local applied = BodyStats.apply(target, key, change.v)
                if applied then
                    state.seqs[seqKey] = seq
                    acks[key] = seq
                    if applied.sync then changed[applied.sync] = true end
                    table.insert(logged, key .. "=" .. formatValue(applied.get(target)))
                end
            end
        end
    end

    if #logged == 0 then
        -- Still answered, so the window stops showing a value the server refused.
        return reply(admin, username, "ok", target, acks)
    end

    BodyStats.sync(target, changed)

    table.sort(logged)
    writeLog("admin", tostring(admin:getUsername()) .. " set body stats of " .. username .. ": " .. table.concat(logged, ", "))

    reply(admin, username, "ok", target, acks)
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_BODY_STATS_REQUEST and command ~= ZomboidFixesB42.CMD_BODY_STATS_SET then return end

    if not player or type(args) ~= "table" then return end

    local role = player:getRole()
    if not role or not role:hasCapability(Capability.CanModifyBodyStats) then
        print("ZomboidFixesB42.bodyStats The player's access level is not sufficient to perform this action")
        -- Answered, so the window says so instead of waiting forever.
        if type(args.target) == "string" then reply(player, args.target, "denied") end
        return
    end

    if command == ZomboidFixesB42.CMD_BODY_STATS_REQUEST then
        onRequest(player, args)
    else
        onSet(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)
