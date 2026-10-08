--[[
    Zomboid Fixes B42.20 -- shared, admin powers kept by the server

    The Admin Powers window (ISAdminPowerUI) lists vanilla's per-admin cheats. Those
    are flags on the player (the cheat set, sent with sendPlayerExtraInfo) or plain
    client globals (ISVehicleMechanics.cheat). The powers this mod adds that the
    server has to act on (God Vehicle, No Wear) are kept on the server instead: one
    entry per username in the global mod data (DATA_KEY, saved with the world), so
    they survive relogs and restarts with nothing stored on the client.

    Each power is a def (ServerPowers.define) made in the feature's shared file, so
    both sides know its id, sandbox option and capability. The client adds it to the
    Admin Powers window with ServerPowers.addOption, which also puts it on the admin
    hotbar (ZomboidFixesB42_AdminHotbarActions.lua makes a toggle of every option,
    whenever it is added).

    Protocol: the client sends CMD_SERVER_POWER { power = id, on = true|false } to
    change it, or { power = id } to ask (at game start); the server answers every
    one with CMD_SERVER_POWER_STATE { power = id, on = ... } plus whatever the power
    adds (def.replyExtra). The option shows what the server last said (def.active).
    Single player: the server Lua runs in the same Lua state, sendClientCommand
    reaches its OnClientCommand, and the answer comes back through
    triggerEvent("OnServerCommand") (sendServerCommand does nothing there).

    Gate: an admin power role (hasAdminPower, as the window itself) with the
    power's capability; single player: -debug. The server checks it on every
    change and every time it uses a power (ServerPowers.isOn), so a role that loses
    the capability loses the power. Turning a power off needs no permission. Each
    change is written to the server's admin log.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local ServerPowers = { byId = {} }
ZomboidFixesB42.ServerPowers = ServerPowers

local DATA_KEY = "ZomboidFixesB42_AdminPowers"

--- def = {
--     id = option id; its text and tooltip are IGUI_CheatPanel_<id>(_tooltip),
--     option = the sandbox option that switches it off (SandboxVars.ZomboidFixesB42),
--     capability = Capability.X,
--     side = "left" or "right" (window column, default "right"),
--     logName = name in the admin log,
-- }
function ServerPowers.define(def)
    ServerPowers.byId[def.id] = def
    return def
end

function ServerPowers.isEnabled(def)
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars[def.option] == true
end

function ServerPowers.isAllowed(def, player)
    if not player or player:isDead() then return false end
    if not isClient() and not isServer() then return isDebugEnabled() end
    local role = player:getRole()
    return role ~= nil and role:hasAdminPower() and role:hasCapability(def.capability)
end

-- How deep bags inside bags are followed.
local MAX_BAG_DEPTH = 5

local function eachInContainer(container, fn, depth)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        fn(item)
        if depth < MAX_BAG_DEPTH and instanceof(item, "InventoryContainer") then
            eachInContainer(item:getInventory(), fn, depth + 1)
        end
    end
end

--- Every item the player carries: the main inventory (worn, held and attached
-- items included) and what is in their bags.
function ServerPowers.eachCarriedItem(player, fn)
    eachInContainer(player:getInventory(), fn, 1)
end

-- Server and single player ---------------------------------------------------------

--- [username] = true for everyone who turned the power on.
local function holders(def)
    local all = ModData.getOrCreate(DATA_KEY)
    local names = all[def.id]
    if type(names) ~= "table" then
        names = {}
        all[def.id] = names
    end
    return names
end

function ServerPowers.isOn(def, player)
    return player ~= nil and ServerPowers.isEnabled(def)
        and holders(def)[player:getUsername()] == true
        and ServerPowers.isAllowed(def, player)
end

function ServerPowers.eachPlayer(fn)
    if isServer() then
        local players = getOnlinePlayers()
        for i = 0, players:size() - 1 do
            fn(players:get(i))
        end
    else
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            if player then fn(player) end
        end
    end
end

--- Every player here with the power on, now.
function ServerPowers.activePlayers(def)
    local list = {}
    if not ServerPowers.isEnabled(def) then return list end
    local names = holders(def)
    ServerPowers.eachPlayer(function(player)
        if names[player:getUsername()] and ServerPowers.isAllowed(def, player) then
            list[#list + 1] = player
        end
    end)
    return list
end

--- Sends a server command to one player or, without one, to every client. In
-- single player the local OnServerCommand handlers get one meant for a player.
function ServerPowers.send(player, command, args)
    if isServer() then
        if player then
            sendServerCommand(player, ZomboidFixesB42.MODULE, command, args)
        else
            sendServerCommand(ZomboidFixesB42.MODULE, command, args)
        end
    elseif not isClient() and player then
        triggerEvent("OnServerCommand", ZomboidFixesB42.MODULE, command, args)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_SERVER_POWER then return end
    if not player or type(args) ~= "table" then return end
    local def = ServerPowers.byId[args.power]
    if not def then return end
    local names = holders(def)
    local username = player:getUsername()

    if args.on == true then
        if not ServerPowers.isEnabled(def) or not ServerPowers.isAllowed(def, player) then
            print("ZomboidFixesB42.serverPower The player's access level is not sufficient to perform this action")
        elseif not names[username] then
            names[username] = true
            if isServer() then writeLog("admin", tostring(username) .. " turned " .. def.logName .. " on") end
        end
    elseif args.on == false then
        if names[username] then
            names[username] = nil
            if isServer() then writeLog("admin", tostring(username) .. " turned " .. def.logName .. " off") end
        end
    end

    local reply = { power = def.id, on = ServerPowers.isOn(def, player) }
    if def.replyExtra then
        for key, value in pairs(def.replyExtra(player)) do
            reply[key] = value
        end
    end
    ServerPowers.send(player, ZomboidFixesB42.CMD_SERVER_POWER_STATE, reply)
end

if not isClient() then
    Events.OnClientCommand.Add(onClientCommand)
end

-- Client and single player -----------------------------------------------------------

local function ask(def, args)
    local player = getPlayer()
    if not player then return end
    args = args or {}
    args.power = def.id
    sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_SERVER_POWER, args)
end

--- Adds the power to the Admin Powers window. def.active is what the server last
-- said; def.onState(args), if set, also gets every answer. Returns the option.
function ServerPowers.addOption(def)
    def.active = false
    def.hasOption = true
    local option = ISAdminPowerUI.AddOption(def.id, def.side or "right", def.capability,
        function(self)
            return def.active
        end,
        function(self, selected)
            local player = self.player or getPlayer()
            selected = selected == true
            -- The window's Save sets every option, changed or not.
            if selected == def.active then return end
            if selected and not (ServerPowers.isEnabled(def) and ServerPowers.isAllowed(def, player)) then return end
            -- Shown at once; the server's answer corrects it if it refuses.
            def.active = selected
            ask(def, { on = selected })
        end
    )
    if not option then return nil end

    -- The admin hotbar greys the toggle out with the sandbox option off.
    option.zfixEnabled = function() return ServerPowers.isEnabled(def) end

    -- The window is built from OptionList whenever it opens; the sandbox option is
    -- only known in game, so it is left out there rather than never registered.
    for _, name in ipairs({ "addOptionLeft", "addOptionRight" }) do
        local vanilla = ISAdminPowerUI[name]
        ISAdminPowerUI[name] = function(self, opt, ...)
            if opt == option and not ServerPowers.isEnabled(def) then return end
            return vanilla(self, opt, ...)
        end
    end
    return option
end

if not isServer() then
    Events.OnServerCommand.Add(function(module, command, args)
        if module ~= ZomboidFixesB42.MODULE or command ~= ZomboidFixesB42.CMD_SERVER_POWER_STATE then return end
        if type(args) ~= "table" then return end
        local def = ServerPowers.byId[args.power]
        if not def or not def.hasOption then return end
        def.active = args.on == true
        if def.onState then def.onState(args) end
    end)

    -- Leaving a game and loading another keeps this file's state.
    Events.OnInitWorld.Add(function()
        for _, def in pairs(ServerPowers.byId) do
            def.active = false
        end
    end)

    Events.OnGameStart.Add(function()
        for _, def in pairs(ServerPowers.byId) do
            if def.hasOption then ask(def) end
        end
    end)
end
