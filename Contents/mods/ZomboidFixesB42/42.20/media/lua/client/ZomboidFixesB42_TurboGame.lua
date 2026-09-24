--[[
    Zomboid Fixes B42.20 -- client, Turbo Game

    Replaces the parts of Turbo Game (workshop 3689877181) that only ever change the
    client's copy of things. See the server file for what goes wrong on a server.

    Context menu. Turbo Game's Insert Cartridge, Remove Cartridge and Insert Battery
    options are taken out and put back as options that ask the server to do the work
    on the exact items clicked. Insert Cartridge also offers a Turbo console that has
    no cartridge in it, which is what the item list spawns. Its Play and No Battery
    options are left alone, except that Play also records which console is being
    played. Turbo Game's handler is a local function, so it cannot be removed; this
    one is added from OnGameStart, after every file has loaded, so it runs second and
    sees the options the first one added.

    Battery. Turbo Game drains the charge on whatever TurboGameConsole.getConsoleItem
    returns, which is the first console in the inventory rather than the one being
    played. That function is a public field on a global table, so it is wrapped to
    prefer the console Play was chosen on. The drain itself still happens on the
    client, and the charge is reported to the server, which only lets it go down.

    Mood. Every stat change in the games happens inside a method of the game's window
    class (applyMoodles, tick, die and so on). Each class's own methods are wrapped
    to read boredom, unhappiness and stress before and after the call, and whatever
    changed in between is added up and reported. Nothing else touches the stats in
    the middle of one Lua call, so the difference is exactly what the game did. Only
    the outermost wrapped call measures, so nothing is counted twice when methods
    call each other. The client keeps its own change, and the server's copy replaces
    it once the server has applied the same change and synced it back.

    The battery and mood reports are only needed with a server: in single player the
    client's copy is the only copy, and replaying the change would count it twice.

    Movement. The games read WASD and the arrow keys straight from the keyboard, so
    the character walked around while the player played. While any game window is
    open the player's movement is blocked, the same flag the game sets while climbing
    through a window, and it is set again every update because timed actions and
    stagger states clear it when they end. Closing the window clears it, unless the
    player is knocked down or on the floor, whose states clear it themselves.

    Interruptions. A game cannot be played with a zombie near, by the same rule as
    multiplayer fast forward, or when it is too dark to read, by the same check as
    books, so a flashlight in hand or a lit car dashboard is enough light. Play is
    greyed out with the reason while either is true, and an open game window is
    closed with the reason shown over the player's head when either becomes true.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.TurboGameMultiplayer == true
end

local CONSOLE_TYPE = "TurboGame.HandheldConsole"
local VANILLA_CONSOLE_TYPE = "Base.VideoGame"
local CARTRIDGE_KEY = "insertedCartridge"

local REPORT_INTERVAL_MS = 1000

-- The console Play was last chosen on.
local activeConsole = nil

-- Stat changes measured inside the games and not yet reported.
local pending = { boredom = 0, unhappiness = 0, stress = 0 }

-- The charge last reported for each console, by item ID.
local reportedCharge = {}

local lastReportTime = 0

local function send(player, command, args)
    sendClientCommand(player, ZomboidFixesB42.MODULE, command, args)
end

local function findCartridgeConfig(fullType)
    for _, cfg in ipairs(TurboGame_Cartridges) do
        if cfg.cartridge == fullType then return cfg end
    end
    return nil
end

local function closePanel(cfg)
    local panel = cfg and cfg.panel and _G[cfg.panel]
    if panel and panel:isVisible() then panel:close() end
end

--[[ Mood measuring ----------------------------------------------------------- ]]

local wrappedClasses = {}

-- How many wrapped calls are running. Reset every tick, so a method that throws
-- cannot leave it stuck above zero.
local depth = 0

local function isMeasuring()
    return isClient() and isEnabled()
end

local function wrapMethod(class, key, original)
    class[key] = function(self, ...)
        if depth > 0 or not isMeasuring() then
            return original(self, ...)
        end
        local player = getSpecificPlayer(0)
        local stats = player and player:getStats()
        if not stats then
            return original(self, ...)
        end

        local boredom = stats:get(CharacterStat.BOREDOM)
        local unhappiness = stats:get(CharacterStat.UNHAPPINESS)
        local stress = stats:get(CharacterStat.STRESS)

        depth = depth + 1
        local r1, r2, r3 = original(self, ...)
        depth = depth - 1

        pending.boredom = pending.boredom + stats:get(CharacterStat.BOREDOM) - boredom
        pending.unhappiness = pending.unhappiness + stats:get(CharacterStat.UNHAPPINESS) - unhappiness
        pending.stress = pending.stress + stats:get(CharacterStat.STRESS) - stress
        return r1, r2, r3
    end
end

--- Wrap a game window class's own methods, once. Inherited ones are left alone.
local function wrapClass(class)
    if type(class) ~= "table" or wrappedClasses[class] then return end
    wrappedClasses[class] = true

    local methods = {}
    for key, value in pairs(class) do
        if type(key) == "string" and type(value) == "function" and string.sub(key, 1, 2) ~= "__" then
            methods[key] = value
        end
    end
    for key, original in pairs(methods) do
        wrapMethod(class, key, original)
    end
end

--- Wrap the class behind every game window that exists. A window's metatable is
-- its class, the same thing TurboGameBattery.hookPanel relies on.
local function wrapOpenPanels()
    for _, cfg in ipairs(TurboGame_Cartridges) do
        local panel = cfg.panel and _G[cfg.panel]
        if type(panel) == "table" then
            wrapClass(getmetatable(panel))
        end
    end
end

--[[ Reporting ---------------------------------------------------------------- ]]

local function report()
    lastReportTime = getTimestampMs()

    local player = getSpecificPlayer(0)
    if not player then return end
    local console = TurboGameConsole.getConsoleItem(player)
    if not console then
        pending.boredom, pending.unhappiness, pending.stress = 0, 0, 0
        return
    end

    local id = console:getID()
    local charge = TurboGameBattery.getCharge(console)
    local moodChanged = pending.boredom ~= 0 or pending.unhappiness ~= 0 or pending.stress ~= 0
    if not moodChanged and reportedCharge[id] == charge then return end

    send(player, ZomboidFixesB42.CMD_TURBO_REPORT, {
        console = tostring(id),
        charge = charge,
        boredom = pending.boredom,
        unhappiness = pending.unhappiness,
        stress = pending.stress,
    })
    reportedCharge[id] = charge
    pending.boredom, pending.unhappiness, pending.stress = 0, 0, 0
end

local function onTick()
    depth = 0
    if not isMeasuring() then return end
    if getTimestampMs() - lastReportTime < REPORT_INTERVAL_MS then return end
    wrapOpenPanels()
    report()
end

--[[ Movement and interruptions ---------------------------------------------- ]]

local INTERRUPT_CHECK_MS = 500

-- Whether this file is the one blocking the player's movement.
local blockingMovement = false

local lastInterruptCheck = 0

local function isGameOpen()
    for _, cfg in ipairs(TurboGame_Cartridges) do
        local panel = cfg.panel and _G[cfg.panel]
        if type(panel) == "table" and panel:isVisible() then return true end
    end
    return false
end

--- Why the player cannot play right now, as a translation key, or nil if they can.
local function cannotPlayReason(player)
    if ZomboidFixesB42.isZombieNear(player) then return "IGUI_ZomboidFixesB42_TurboGame_ZombieNear" end
    if player:tooDarkToRead() then return "ContextMenu_TooDarkToSee" end
    return nil
end

--- Close every open game window if the player can no longer play. Returns whether
-- it did.
local function interrupt(player)
    local now = getTimestampMs()
    if now - lastInterruptCheck < INTERRUPT_CHECK_MS then return false end
    lastInterruptCheck = now

    local reason = cannotPlayReason(player)
    if not reason then return false end
    for _, cfg in ipairs(TurboGame_Cartridges) do
        closePanel(cfg)
    end
    HaloTextHelper.addBadText(player, getText(reason))
    return true
end

--- Runs before the player's input is read, so a blocked key press never moves them.
local function onPlayerUpdate(player)
    if player ~= getSpecificPlayer(0) then return end
    local playing = isEnabled() and isGameOpen()
    if playing and interrupt(player) then playing = false end
    if playing then
        player:setBlockMovement(true)
        blockingMovement = true
    elseif blockingMovement then
        blockingMovement = false
        if not player:isOnFloor() and not player:isKnockedDown() then
            player:setBlockMovement(false)
        end
    end
end

--[[ Context menu ------------------------------------------------------------- ]]

local function removeOptions(context, name)
    while context:getOptionFromName(name) do
        context:removeOptionByName(name)
    end
end

--- Where a cartridge would go: an empty Turbo console first, else the vanilla one.
local function findInsertTarget(inventory)
    local items = inventory:getItems()
    local vanilla = nil
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local fullType = item:getFullType()
        if fullType == CONSOLE_TYPE and not item:getModData()[CARTRIDGE_KEY] then
            return item
        end
        if not vanilla and fullType == VANILLA_CONSOLE_TYPE then
            vanilla = item
        end
    end
    return vanilla
end

local function insertCartridge(player, target, cartridge, cfg)
    local name = nil
    if cfg.consoleName then name = getItemNameFromFullType(cfg.consoleName) end
    send(player, ZomboidFixesB42.CMD_TURBO_INSERT, {
        target = tostring(target:getID()),
        cartridge = tostring(cartridge:getID()),
        name = name,
    })
end

local function ejectCartridge(player, console, cfg)
    closePanel(cfg)
    if isClient() then report() end
    send(player, ZomboidFixesB42.CMD_TURBO_EJECT, { console = tostring(console:getID()) })
end

local function insertBattery(player, console, battery)
    if isClient() then report() end
    send(player, ZomboidFixesB42.CMD_TURBO_BATTERY, {
        console = tostring(console:getID()),
        battery = tostring(battery:getID()),
    })
end

local function onFillInventoryObjectContextMenu(playerNum, context, items)
    if not isEnabled() then return end

    local player = getSpecificPlayer(playerNum)
    if not player then return end
    local inventory = player:getInventory()

    local stack = {}
    for _, entry in ipairs(items) do
        if instanceof(entry, "InventoryItem") then
            table.insert(stack, entry)
        elseif type(entry) == "table" and entry.items then
            for _, item in ipairs(entry.items) do table.insert(stack, item) end
        end
    end

    -- Turbo Game's own options, which act on the client's copy only.
    removeOptions(context, getText("ContextMenu_InsertCartridge"))
    removeOptions(context, getText("ContextMenu_EjectCartridge"))
    removeOptions(context, getText("ContextMenu_TurboGame_InsertBattery"))
    for _, cfg in ipairs(TurboGame_Cartridges) do
        if cfg.ejectKey then removeOptions(context, getText(cfg.ejectKey)) end
    end

    -- A cartridge clicked: one option per kind, as Turbo Game does.
    local target = findInsertTarget(inventory)
    if target then
        for _, cfg in ipairs(TurboGame_Cartridges) do
            for _, item in ipairs(stack) do
                if item:getFullType() == cfg.cartridge and item:getContainer() == inventory then
                    context:addOption(getText("ContextMenu_InsertCartridge"), player, insertCartridge, target, item, cfg)
                    break
                end
            end
        end
    end

    -- A console clicked: the first one, as Turbo Game does.
    for _, item in ipairs(stack) do
        if item:getFullType() == CONSOLE_TYPE and item:getContainer() == inventory then
            local console = item
            local cartridgeType = console:getModData()[CARTRIDGE_KEY]
            local cfg = cartridgeType and findCartridgeConfig(cartridgeType)

            if cfg then
                local play = context:getOptionFromName(getText(cfg.playKey))
                local reason = play and cannotPlayReason(player)
                if reason then
                    play.notAvailable = true
                    play.toolTip = ISInventoryPaneContextMenu.addToolTip()
                    play.toolTip.description = getText(reason)
                end
                if play and play.onSelect then
                    local openGame = play.onSelect
                    play.onSelect = function(...)
                        activeConsole = console
                        openGame(...)
                        wrapOpenPanels()
                    end
                end
            end

            if TurboGameBattery.getCharge(console) <= 0 then
                local battery = TurboGameBattery.findChargedBattery(player)
                if battery then
                    context:addOption(getText("ContextMenu_TurboGame_InsertBattery"), player, insertBattery, console, battery)
                end
            end

            if cartridgeType then
                local label = getText("ContextMenu_EjectCartridge")
                if cfg and cfg.ejectKey then label = getText(cfg.ejectKey) end
                context:addOption(label, player, ejectCartridge, console, cfg)
            end
            break
        end
    end
end

--[[ Install ------------------------------------------------------------------ ]]

local function install()
    -- Turbo Game defines all three from its client files; nothing else does.
    if TurboGame_Cartridges == nil or TurboGameConsole == nil or TurboGameBattery == nil then return end

    local getConsoleItem = TurboGameConsole.getConsoleItem
    TurboGameConsole.getConsoleItem = function(player)
        if isEnabled() and activeConsole and player
            and activeConsole:getContainer() == player:getInventory() then
            return activeConsole
        end
        return getConsoleItem(player)
    end

    Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
    Events.OnTick.Add(onTick)
    Events.OnPlayerUpdate.Add(onPlayerUpdate)
end

Events.OnGameStart.Add(install)
