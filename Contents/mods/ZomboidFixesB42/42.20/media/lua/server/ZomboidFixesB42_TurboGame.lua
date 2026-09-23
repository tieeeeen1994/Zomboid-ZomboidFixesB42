--[[
    Zomboid Fixes B42.20 -- server, Turbo Game

    Turbo Game (workshop 3689877181) keeps everything about its handheld console on
    the client: the battery drains in the client's copy of the item's mod data, Insert
    Battery removes the battery from the client's inventory only, and the games lower
    boredom and unhappiness in the client's copy of the player's stats. On a server
    none of that reaches the server's copy -- stats are server side, and a client may
    only push them with the CanModifyBodyStats capability -- so the charge and the
    battery come back on relog and playing never makes anyone less bored.

    Its insert and eject do go through a server command, but they find their items by
    type rather than by the ones clicked: eject takes the first console in the
    inventory, whichever cartridge that holds. And a cartridge only goes into the
    vanilla Base.VideoGame, so a TurboGame.HandheldConsole spawned from the item list
    -- which has no cartridge yet -- can never be loaded at all.

    This file does all of that on the server instead, addressing each item by ID.
    The client file strips Turbo Game's own options and sends these commands. In
    single player sendClientCommand runs OnClientCommand directly, so the same code
    serves both, and the insert and eject fixes apply there too.

    The battery charge travels with the device: ejecting writes it onto the
    Base.VideoGame that comes back, and inserting reads it from whichever device the
    cartridge goes into. Turbo Game kept it in global mod data under the local player
    number, which is 0 on every client, so every player on a server shared one value.

    Mood effects are measured on the client, where the games run, and replayed here.
    A tampered client could lie about them, so they are only accepted while the
    player carries a loaded, charged console, and are capped at rates somewhat above
    the most any of the fourteen games gives.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.TurboGameMultiplayer == true
end

local CONSOLE_TYPE = "TurboGame.HandheldConsole"
local VANILLA_CONSOLE_TYPE = "Base.VideoGame"
local BATTERY_TYPE = "Base.Battery"

-- Turbo Game's own mod data keys, so its code keeps reading what this file writes.
local CHARGE_KEY = "turboBattery"
local CARTRIDGE_KEY = "insertedCartridge"

local MAX_NAME_LENGTH = 100

-- Mood caps, per second since the player's last report, plus a one-off allowance for
-- the bursts some games give at once (a Minesweeper win takes 0.5 off stress and
-- unhappiness). Boredom and unhappiness run 0-100, stress 0-1. The steadiest
-- drains in the games are 0.1 boredom a second (Flappy Bird, Space Invaders).
local BOREDOM_RATE, BOREDOM_BURST = 1.0, 1.0
local UNHAPPINESS_RATE, UNHAPPINESS_BURST = 0.5, 1.0
local STRESS_DOWN_RATE, STRESS_DOWN_BURST = 0.25, 0.5
local STRESS_UP_RATE, STRESS_UP_BURST = 0.1, 0.1

-- The window a report's caps are worked out over, in seconds. The client reports
-- about once a second; the upper bound stops a long silence banking a large budget.
local MIN_WINDOW, MAX_WINDOW = 0.25, 5

-- When each player last reported, by username.
local lastReport = {}

local function isCartridgeType(fullType)
    return type(fullType) == "string"
        and string.sub(fullType, 1, 10) == "TurboGame."
        and string.sub(fullType, -9) == "Cartridge"
        and getScriptManager():FindItem(fullType) ~= nil
end

--- The charge on a console or a device, 0-100. Nothing recorded means a fresh one.
local function readCharge(item)
    local charge = tonumber(item:getModData()[CHARGE_KEY])
    if not charge or charge ~= charge then return 100 end
    return math.max(0, math.min(100, charge))
end

--- An item by ID, directly in the player's main inventory, where Turbo Game's menu
-- requires it to be.
local function findOwnItem(player, id)
    id = tonumber(id)
    if not id then return nil end
    return player:getInventory():getItemWithID(id)
end

local function removeItem(inventory, item)
    sendRemoveItemFromContainer(inventory, item)
    inventory:Remove(item)
end

--- Create an item with its mod data already set, so the one packet that sends it
-- carries everything.
local function addItem(inventory, fullType, modData, name)
    local item = inventory:AddItem(fullType)
    if not item then return nil end
    local md = item:getModData()
    for key, value in pairs(modData) do
        md[key] = value
    end
    if name then item:setName(name) end
    sendAddItemToContainer(inventory, item)
    return item
end

local function onInsert(player, args)
    local target = findOwnItem(player, args.target)
    local cartridge = findOwnItem(player, args.cartridge)
    if not target or not cartridge then return end

    local cartridgeType = cartridge:getFullType()
    if not isCartridgeType(cartridgeType) then return end

    -- Into the vanilla handheld, or into a Turbo console that has nothing in it.
    local targetType = target:getFullType()
    if targetType == CONSOLE_TYPE then
        if target:getModData()[CARTRIDGE_KEY] then return end
    elseif targetType ~= VANILLA_CONSOLE_TYPE then
        return
    end

    local name = args.name
    if type(name) ~= "string" or name == "" then
        name = nil
    elseif #name > MAX_NAME_LENGTH then
        name = string.sub(name, 1, MAX_NAME_LENGTH)
    end

    local inventory = player:getInventory()
    local charge = readCharge(target)
    removeItem(inventory, target)
    removeItem(inventory, cartridge)
    addItem(inventory, CONSOLE_TYPE, { [CARTRIDGE_KEY] = cartridgeType, [CHARGE_KEY] = charge }, name)
end

local function onEject(player, args)
    local console = findOwnItem(player, args.console)
    if not console or console:getFullType() ~= CONSOLE_TYPE then return end

    local cartridgeType = console:getModData()[CARTRIDGE_KEY]
    if not cartridgeType then return end

    local inventory = player:getInventory()
    local charge = readCharge(console)
    removeItem(inventory, console)
    addItem(inventory, VANILLA_CONSOLE_TYPE, { [CHARGE_KEY] = charge })
    if isCartridgeType(cartridgeType) then
        addItem(inventory, cartridgeType, {})
    end
end

local function onInsertBattery(player, args)
    local console = findOwnItem(player, args.console)
    local battery = findOwnItem(player, args.battery)
    if not console or not battery then return end
    if console:getFullType() ~= CONSOLE_TYPE or battery:getFullType() ~= BATTERY_TYPE then return end
    if battery:getCurrentUsesFloat() <= 0 or readCharge(console) >= 100 then return end

    -- Turbo Game uses up the whole battery whatever is left in it; so does this.
    removeItem(player:getInventory(), battery)
    console:getModData()[CHARGE_KEY] = 100
    syncItemModData(player, console)
end

--- How much of a reported fall to accept. Reports carry the change the client saw,
-- so a fall is negative; anything else is ignored.
local function acceptedDrop(delta, limit)
    delta = tonumber(delta)
    if not delta or delta ~= delta or delta >= 0 then return 0 end
    return math.min(-delta, limit)
end

local statMasks = nil

local function getStatMasks()
    if not statMasks then
        statMasks = {
            boredom = SyncPlayerStatsPacket.getBitMaskForStat(CharacterStat.BOREDOM),
            unhappiness = SyncPlayerStatsPacket.getBitMaskForStat(CharacterStat.UNHAPPINESS),
            stress = SyncPlayerStatsPacket.getBitMaskForStat(CharacterStat.STRESS),
        }
    end
    return statMasks
end

local function applyMood(player, args)
    local now = getTimestampMs()
    local key = player:getUsername()
    local last = lastReport[key]
    lastReport[key] = now

    local seconds = 1
    if last then seconds = (now - last) / 1000 end
    seconds = math.max(MIN_WINDOW, math.min(MAX_WINDOW, seconds))

    local stats = player:getStats()
    local masks = getStatMasks()
    -- The masks are distinct bits, so adding them is the same as OR-ing them.
    local mask = 0

    local boredom = acceptedDrop(args.boredom, BOREDOM_RATE * seconds + BOREDOM_BURST)
    if boredom > 0 then
        stats:remove(CharacterStat.BOREDOM, boredom)
        mask = mask + masks.boredom
    end

    local unhappiness = acceptedDrop(args.unhappiness, UNHAPPINESS_RATE * seconds + UNHAPPINESS_BURST)
    if unhappiness > 0 then
        stats:remove(CharacterStat.UNHAPPINESS, unhappiness)
        mask = mask + masks.unhappiness
    end

    -- Stress goes both ways: games lower it as you play and raise it when you lose.
    local stress = tonumber(args.stress)
    if stress and stress == stress and stress ~= 0 then
        if stress < 0 then
            stats:remove(CharacterStat.STRESS, math.min(-stress, STRESS_DOWN_RATE * seconds + STRESS_DOWN_BURST))
        else
            stats:add(CharacterStat.STRESS, math.min(stress, STRESS_UP_RATE * seconds + STRESS_UP_BURST))
        end
        mask = mask + masks.stress
    end

    if mask > 0 then
        syncPlayerStats(player, mask)
    end
end

local function onReport(player, args)
    local console = findOwnItem(player, args.console)
    if not console or console:getFullType() ~= CONSOLE_TYPE then return end

    local md = console:getModData()
    if not md[CARTRIDGE_KEY] then return end

    -- Checked before this report's charge lands: the mood was earned while it was
    -- still above zero, even if this is the report that empties it.
    local current = readCharge(console)
    if current > 0 then
        applyMood(player, args)
    end

    -- Only ever down. A battery can only go back in through onInsertBattery.
    local charge = tonumber(args.charge)
    if charge and charge == charge and charge < current then
        md[CHARGE_KEY] = math.max(0, charge)
    end
end

local handlers = {
    [ZomboidFixesB42.CMD_TURBO_INSERT] = onInsert,
    [ZomboidFixesB42.CMD_TURBO_EJECT] = onEject,
    [ZomboidFixesB42.CMD_TURBO_BATTERY] = onInsertBattery,
    [ZomboidFixesB42.CMD_TURBO_REPORT] = onReport,
}

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    local handler = handlers[command]
    if not handler or not isEnabled() or not player or player:isDead() then return end
    -- Turbo Game not loaded on this server: none of its items exist.
    if not getScriptManager():FindItem(CONSOLE_TYPE) then return end
    handler(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
