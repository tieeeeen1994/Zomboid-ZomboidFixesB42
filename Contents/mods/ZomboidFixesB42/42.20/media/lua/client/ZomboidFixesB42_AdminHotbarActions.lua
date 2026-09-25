--[[
    Zomboid Fixes B42.20 -- client, admin hotbar actions

    The catalog of hotbar actions: every admin feature vanilla offers somewhere in
    its UI or chat commands, each run the way vanilla runs it. The inventory it was
    built from (42.20.4):

      - Admin Powers: ISAdminPowerUI.OptionList, the registry the Admin Powers window
        is built from. Flipping one is what that window's Save does: the option's
        setValue on the player, then sendPlayerExtraInfo.
      - The admin panel windows: ISAdminPanelUI.onOptionMouseDown, called with a stub
        panel so the opening code is not copied.
      - The right-click Tools menu (AdminContextMenu) and Debug menu
        (DebugContextMenu, which Java builds for any role with UseDebugContextMenu in
        multiplayer): Teleport, Spawn Vehicle, Horde Manager, Trigger Thunder, Make
        Noise, Remove Item Tool, stories, animals, vehicles and zombies.
      - The chat commands in zombie/commands/serverCommands, with the exact syntax
        they parse: /additem "user" "Module.Type" count, /addvehicle Script x,y,z,
        /createhorde2 -x .. -outfit .., /removezombies -x -y -z -radius,
        /teleportto ["user"] x,y,z, /godmodplayer "user" -true|-false, and so on.
        The server checks each command's capability itself.
      - Climate Control: the ClimateManager admin values and transmit calls its
        Climate and Weather tabs use.

    Four vanilla client commands have no permission check on the server
    (object.addFireOnSquare / addSmokeOnSquare / addExplosionOnSquare, event.thunder,
    vehicle.remove); like vanilla's own UI, the capability gate here is client side.

    Actions that only act on one object under the cursor (door, window, fence,
    generator, a selected zombie, a corpse, one animal, a vehicle's colours) stay in
    the right-click menus. Quitting, reloading Lua, world generation, log levels and
    role changes are left to the Custom command action.

    Single player (debug mode only, see the core file) has no server for the chat
    commands, so each action also has the single player branch vanilla's own window
    uses: the Item List adds the item to the inventory, the Horde Manager calls
    addZombiesInOutfit, Spawn Vehicle calls addVehicle with coordinates, teleports
    call teleportTo, weather calls the ClimateManager directly
    (triggerCustomWeatherStage, stopWeatherAndThunder, the precipitation admin value
    /startrain sets), thunder calls ThunderStorm.triggerThunderEvent, which runs
    locally outside a server, and so on. Where vanilla already has one function for
    both (DebugContextMenu.AddAnimal, OnGetBuildingKey, doRandomizedVehicleStory,
    doRandomizedZoneStory, onAddEnclosure, removeAllVehicles, testHelicopter,
    endHelicopter), it is called for both. The vehicle and fire client commands work
    in single player too: sendClientCommand reaches the server Lua there, and those
    handlers do not check the role. Actions that need a server are greyed out.
--]]

require "ZomboidFixesB42_AdminHotbar"
require "ISUI/AdminPanel/ISAdminPowerUI"
require "ISUI/AdminPanel/ISAdminPanelUI"
require "ISUI/PlayerStats/ISPlayerStatsUI"
require "DebugUIs/AdminContextMenu"
require "DebugUIs/DebugContextMenu"

local Hotbar = ZomboidFixesB42.AdminHotbar
local txt = Hotbar.txt
local cmd = Hotbar.command
local q = Hotbar.quote
local int = Hotbar.int

-- Gates ---------------------------------------------------------------------------------

local function needs(...)
    local names = { ... }
    return function(admin)
        for _, name in ipairs(names) do
            if not Hotbar.hasCapability(admin, name) then
                return false, txt("NeedsCapability", name)
            end
        end
        return true
    end
end

local function needsAny(...)
    local names = { ... }
    return function(admin)
        for _, name in ipairs(names) do
            if Hotbar.hasCapability(admin, name) then return true end
        end
        return false, txt("NeedsCapability", table.concat(names, " / "))
    end
end

local function toolsGate(admin)
    if Hotbar.canUseTools() then return true end
    return false, txt("NeedsTools")
end

local function toolsOr(name)
    return function(admin)
        if Hotbar.canUseTools() or Hotbar.hasCapability(admin, name) then return true end
        return false, txt("NeedsCapability", name)
    end
end

--- For actions that need someone other than you: in single player that means a
-- split screen player.
local function needsOther(check)
    return function(admin)
        if not isClient() and getNumActivePlayers() < 2 then return false, txt("NeedsOtherPlayer") end
        return check(admin)
    end
end

--- For actions that only exist on a server: greyed out in single player, else check.
local function mpOnly(check)
    return function(admin)
        if not isClient() then return false, txt("MultiplayerOnly") end
        if check then return check(admin) end
        return true
    end
end

-- Params --------------------------------------------------------------------------------

--- Actions that make sense on yourself (god mode, add XP, body stats, lightning...)
-- target you by default; the ones that only make sense on someone else (teleport to,
-- bring, kick, ban...) ask. Either can be changed in the slot's settings.
local function playerParam(default, optional)
    return { key = "player", type = "player", title = txt("ParamPlayer"), default = default or "@ask", optional = optional }
end

local function locationParam(default)
    return { key = "location", type = "location", title = txt("ParamLocation"), default = default or "@me" }
end

local function vehicleParam()
    return { key = "vehicle", type = "vehicle", title = txt("ParamVehicle"), default = "@near" }
end

local function numberParam(key, title, default, min, max, integer, hint)
    return { key = key, type = "number", title = title, default = default, min = min, max = max, integer = integer, hint = hint }
end

local function boolParam(key, title, default, tickText)
    return { key = key, type = "bool", title = title, default = default == true, tickText = tickText }
end

local function textParam(key, title, optional, hint)
    return { key = key, type = "text", title = title, optional = optional, hint = hint }
end

-- Helpers -----------------------------------------------------------------------------------

local function loadedPlayer(ctx)
    local player = Hotbar.findPlayer(ctx.values.player)
    if not player then
        Hotbar.say(ctx.admin, txt("PlayerNotLoaded"), true)
    end
    return player
end

local function teleport(player, x, y, z)
    player:teleportTo(x, y, z)
end

local function coordsOf(location)
    return int(location.x) .. "," .. int(location.y) .. "," .. int(location.z)
end

local function squareAt(ctx, location)
    local square = getCell():getGridSquare(location.x, location.y, location.z)
    if not square then
        Hotbar.say(ctx.admin, txt("LocationNotLoaded"), true)
    end
    return square
end

--- Open an admin panel window through the panel's own handler. The stub stands in
-- for the panel: the handler only calls updateButtons on it afterwards.
local function openAdminWindow(internal)
    ISAdminPanelUI.onOptionMouseDown({ updateButtons = function() end }, { internal = internal })
end

local function register(def)
    return Hotbar.registerAction(def)
end

-- Categories -----------------------------------------------------------------------------------

Hotbar.addCategory("powers", txt("CatPowers"))
Hotbar.addCategory("players", txt("CatPlayers"))
Hotbar.addCategory("teleport", txt("CatTeleport"))
Hotbar.addCategory("items", txt("CatItems"))
Hotbar.addCategory("vehicles", txt("CatVehicles"))
Hotbar.addCategory("zombies", txt("CatZombies"))
Hotbar.addCategory("noise", txt("CatNoiseFire"))
Hotbar.addCategory("weather", txt("CatWeather"))
Hotbar.addCategory("meta", txt("CatMetaEvents"))
Hotbar.addCategory("stories", txt("CatStories"))
Hotbar.addCategory("animals", txt("CatAnimals"))
Hotbar.addCategory("server", txt("CatServer"))
Hotbar.addCategory("windows", txt("CatWindows"))
Hotbar.addCategory("debug", txt("CatDebugTools"))
Hotbar.addCategory("custom", txt("CatCustom"))

-- 1. Powers ------------------------------------------------------------------------------------------

local POWER_ICONS = {
    Invisible = "item:Base.Ghillie_Top",
    GodMod = "item:Base.Vest_BulletArmy",
    NoClip = "sym:Door",
    FastMove = "sym:ArrowNorthEast",
    TimedActionInstant = "item:Base.Timer",
    UnlimitedCarry = "item:Base.Bag_ALICEpack",
    UnlimitedEndurance = "sym:Heart",
    UnlimitedAmmo = "sym:Bullets",
    KnowAllRecipes = "sym:Book",
    BuildCheat = "sym:Hammer",
    FarmingCheat = "sym:Leaf",
    FishingCheat = "sym:Fish",
    HealthCheat = "sym:MedCross",
    MechanicsCheat = "sym:Wrench",
    MoveableCheat = "sym:Bed",
    CanSeeAll = "sym:Eye",
    CanHearAll = "item:Base.Headphones",
    ZombiesDontAttack = "sym:Z",
    BrushTool = "item:Base.Paintbrush",
    LootZed = "sym:DollarSign",
    LootLog = "item:Base.Notebook",
    AnimalCheat = "sym:Pawprint",
    AnimalExtraValues = "sym:Cow",
    AlwaysDay = "sym:Sun",
}

for _, option in ipairs(ISAdminPowerUI.OptionList or {}) do
    local power = option
    register({
        id = "power:" .. power.id,
        category = "powers",
        title = power.text,
        tooltip = power.tooltip,
        icon = POWER_ICONS[power.id] or "sym:Star",
        available = function(admin)
            -- Admin Powers' own rule: isDebugEnabled() (single player) or the role.
            if not isClient() then return true end
            local role = admin:getRole()
            if not role or not role:hasAdminPower() then return false, txt("NeedsAdminPower") end
            if power.capability and not role:hasCapability(power.capability) then
                return false, txt("NeedsCapability", power.capability:name())
            end
            return true
        end,
        toggle = {
            isOn = function(ctx)
                power.player = ctx.admin
                return power:getValue() == true
            end,
            set = function(ctx, on)
                power.player = ctx.admin
                if on == nil then on = not power:getValue() end
                power:setValue(on)
                -- Tells the server and every other client; there is no one to tell alone.
                if isClient() then sendPlayerExtraInfo(ctx.admin) end
            end,
        },
    })
end

-- 2. Players --------------------------------------------------------------------------------------------

--- God mode, invisibility and noclip for any player, through the server's own
-- commands: they are the only way these reach every client. In single player the
-- flag is set on the (local) player directly.
local function playerFlag(id, command, capability, getter, setter, icon, key)
    register({
        id = id,
        category = "players",
        title = txt(key),
        tooltip = txt(key .. "Tooltip"),
        icon = icon,
        params = { playerParam("@me") },
        available = needs(capability),
        toggle = {
            isOn = function(ctx)
                local player = Hotbar.findPlayer(ctx.values.player)
                if not player then return nil end
                local method = player[getter]
                return method ~= nil and method(player) == true
            end,
            set = function(ctx, on)
                if not isClient() then
                    local player = loadedPlayer(ctx)
                    if not player then return end
                    if on == nil then on = not player[getter](player) end
                    player[setter](player, on)
                    return
                end
                local suffix = ""
                if on == true then suffix = " -true" elseif on == false then suffix = " -false" end
                cmd(command .. " " .. q(ctx.values.player) .. suffix)
            end,
        },
    })
end

playerFlag("players.godmode", "/godmodplayer", "ToggleGodModEveryone", "isGodMod", "setGodMod", "item:Base.Vest_BulletArmy", "PlayerGodMode")
playerFlag("players.invisible", "/invisibleplayer", "ToggleInvisibleEveryone", "isInvisible", "setInvisible", "item:Base.Hat_BalaclavaFull", "PlayerInvisible")
playerFlag("players.noclip", "/noclip", "ToggleNoclipEveryone", "isNoClip", "setNoClip", "sym:Door", "PlayerNoClip")

register({
    id = "players.teleportTo",
    category = "players",
    title = txt("TeleportToPlayer"),
    tooltip = txt("TeleportToPlayerTooltip"),
    icon = "sym:Target",
    params = { playerParam() },
    available = needsOther(needs("TeleportToPlayer")),
    run = function(ctx)
        if isClient() then return cmd("/teleport " .. q(ctx.values.player)) end
        local player = loadedPlayer(ctx)
        if player then teleport(ctx.admin, player:getX(), player:getY(), player:getZ()) end
    end,
})

register({
    id = "players.bring",
    category = "players",
    title = txt("BringPlayer"),
    tooltip = txt("BringPlayerTooltip"),
    icon = "sym:ArrowSouth",
    params = { playerParam() },
    available = needsOther(needs("TeleportPlayerToAnotherPlayer")),
    run = function(ctx)
        if isClient() then
            return cmd("/teleportplayer " .. q(ctx.values.player) .. " " .. q(ctx.admin:getUsername()))
        end
        local player = loadedPlayer(ctx)
        if player then teleport(player, ctx.admin:getX(), ctx.admin:getY(), ctx.admin:getZ()) end
    end,
})

register({
    id = "players.sendTo",
    category = "players",
    title = txt("SendPlayer"),
    tooltip = txt("SendPlayerTooltip"),
    icon = "sym:ArrowNorthEast",
    params = { playerParam(), locationParam("@pick") },
    available = needs("TeleportToCoordinates"),
    run = function(ctx)
        local l = ctx.values.location
        if isClient() then
            return cmd("/teleportto " .. q(ctx.values.player) .. " " .. coordsOf(l))
        end
        local player = loadedPlayer(ctx)
        if player then teleport(player, l.x + 0.5, l.y + 0.5, l.z) end
    end,
})

register({
    id = "players.bringAll",
    category = "players",
    title = txt("BringEveryone"),
    tooltip = txt("BringEveryoneTooltip"),
    icon = "sym:Columns",
    confirm = true,
    available = mpOnly(needs("TeleportPlayerToAnotherPlayer")),
    run = function(ctx) teleportPlayers(ctx.admin) end,
})

local perkChoices = nil
local function perks()
    if perkChoices then return perkChoices end
    perkChoices = {}
    for i = 1, Perks.getMaxIndex() do
        local perk = PerkFactory.getPerk(Perks.fromIndex(i - 1))
        if perk and perk:getParent() ~= Perks.None then
            table.insert(perkChoices, {
                text = perk:getName() .. " (" .. PerkFactory.getPerkName(perk:getParent()) .. ")",
                data = tostring(perk:getType()),
            })
        end
    end
    table.sort(perkChoices, function(a, b) return a.text < b.text end)
    return perkChoices
end

register({
    id = "players.addXp",
    category = "players",
    title = txt("AddXp"),
    tooltip = txt("AddXpTooltip"),
    icon = "sym:Star",
    params = {
        playerParam("@me"),
        { key = "perk", type = "choice", title = txt("ParamPerk"), options = perks, search = true },
        numberParam("amount", txt("ParamXp"), nil, -100000, 100000, true, txt("XpHint")),
    },
    available = needs("AddXP"),
    run = function(ctx)
        if isClient() then
            return cmd("/addxp " .. q(ctx.values.player) .. " " .. ctx.values.perk .. "=" .. int(ctx.values.amount) .. " -false")
        end
        -- Player Stats' single player path.
        local player = loadedPlayer(ctx)
        local perk = Perks.FromString(ctx.values.perk)
        if player and perk then
            player:getXp():AddXP(perk, ctx.values.amount, false, false, false, false)
        end
    end,
})

register({
    id = "players.stats",
    category = "players",
    title = txt("CheckStats"),
    tooltip = txt("CheckStatsTooltip"),
    icon = "item:Base.Clipboard",
    params = { playerParam("@me") },
    available = needs("CanSeePlayersStats"),
    run = function(ctx)
        local player = loadedPlayer(ctx)
        if not player then return end
        if ISPlayerStatsUI.instance then ISPlayerStatsUI.instance:close() end
        local ui = ISPlayerStatsUI:new(50, 50, 800 + getCore():getOptionFontSizeReal() * 50, 800, player, ctx.admin)
        ui:initialise()
        ui:addToUIManager()
        ui:setVisible(true)
    end,
})

--- Player Stats' own rule for its edit buttons: the capability, and never a player
-- whose role ranks above the admin's.
local function canModify(ctx, player)
    if not Hotbar.hasCapability(ctx.admin, "CanModifyPlayerStatsInThePlayerStatsUI") then return false end
    local theirs, mine = player:getRole(), ctx.admin:getRole()
    return not theirs or not mine or theirs:getPosition() <= mine:getPosition()
end

register({
    id = "players.inventory",
    category = "players",
    title = txt("ManageInventory"),
    tooltip = txt("ManageInventoryTooltip"),
    icon = "item:Base.Bag_ALICEpack",
    params = { playerParam() },
    available = mpOnly(needs("CanModifyPlayerStatsInThePlayerStatsUI")),
    run = function(ctx)
        local player = loadedPlayer(ctx)
        if not player then return end
        if not canModify(ctx, player) then return Hotbar.say(ctx.admin, txt("RankTooHigh"), true) end
        local ui = ISPlayerStatsManageInvUI:new(100, 100, 900, 650, player:getOnlineID(), player:getUsername())
        ui:initialise()
        ui:addToUIManager()
    end,
})

register({
    id = "players.warning",
    category = "players",
    title = txt("WarningPoint"),
    tooltip = txt("WarningPointTooltip"),
    icon = "sym:Exclamation",
    params = { playerParam(), textParam("reason", txt("ParamReason")), numberParam("amount", txt("ParamAmount"), 1, 1, 100, true) },
    available = mpOnly(needs("CanModifyPlayerStatsInThePlayerStatsUI")),
    run = function(ctx)
        addWarningPoint(ctx.values.player, ctx.values.reason, math.floor(ctx.values.amount))
    end,
})

register({
    id = "players.mute",
    category = "players",
    title = txt("MuteChat"),
    tooltip = txt("MuteChatTooltip"),
    icon = "sym:X",
    params = { playerParam() },
    available = mpOnly(needs("CanModifyPlayerStatsInThePlayerStatsUI")),
    toggle = {
        isOn = function(ctx)
            local player = Hotbar.findPlayer(ctx.values.player)
            if not player then return nil end
            return player:isAllChatMuted() == true
        end,
        set = function(ctx, on)
            local player = loadedPlayer(ctx)
            if not player then return end
            if not canModify(ctx, player) then return Hotbar.say(ctx.admin, txt("RankTooHigh"), true) end
            if on == nil then on = not player:isAllChatMuted() end
            player:setAllChatMuted(on)
            sendPlayerStatsChange(player)
        end,
    },
})

register({
    id = "players.kick",
    category = "players",
    title = txt("Kick"),
    tooltip = txt("KickTooltip"),
    icon = "sym:CrossedSwords",
    confirm = true,
    params = { playerParam(), textParam("reason", txt("ParamReason"), true) },
    available = mpOnly(needs("KickUser")),
    run = function(ctx)
        local reason = ctx.values.reason
        cmd("/kick " .. q(ctx.values.player) .. (reason and (" -r " .. q(reason)) or ""))
    end,
})

register({
    id = "players.ban",
    category = "players",
    title = txt("Ban"),
    tooltip = txt("BanTooltip"),
    icon = "sym:Lock",
    confirm = true,
    params = {
        playerParam(),
        textParam("reason", txt("ParamReason"), true),
        boolParam("ip", txt("ParamBanIp"), false, txt("BanIpTick")),
    },
    available = mpOnly(needs("BanUnbanUser")),
    run = function(ctx)
        local reason = ctx.values.reason
        cmd("/banuser " .. q(ctx.values.player) .. (ctx.values.ip and " -ip" or "") .. (reason and (" -r " .. q(reason)) or ""))
    end,
})

register({
    id = "players.voiceban",
    category = "players",
    title = txt("VoiceBan"),
    tooltip = txt("VoiceBanTooltip"),
    icon = "item:Base.Headphones",
    params = { playerParam(), boolParam("ban", txt("ParamVoiceBan"), true, txt("VoiceBanTick")) },
    available = mpOnly(needs("BanUnbanUser")),
    run = function(ctx)
        cmd("/voiceban " .. q(ctx.values.player) .. (ctx.values.ban and " -true" or " -false"))
    end,
})

local function bodyStatsEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.BodyStatsEditor == true
end

register({
    id = "players.body",
    category = "players",
    title = txt("BodyStats"),
    tooltip = txt("BodyStatsTooltip"),
    icon = "sym:MedCross",
    params = {
        playerParam("@me"),
        {
            key = "preset", type = "preset", title = txt("ParamBodyPreset"),
            summary = function(preset)
                local count = 0
                for _ in pairs(preset) do count = count + 1 end
                return txt("BodyPresetSummary", int(count))
            end,
        },
    },
    available = function(admin)
        if not bodyStatsEnabled() then return false, txt("NeedsBodyStats") end
        return needs("CanModifyBodyStats")(admin)
    end,
    run = function(ctx)
        local name = ctx.values.player
        if ctx.values.preset and ZomboidFixesB42.sendBodyStats then
            ZomboidFixesB42.sendBodyStats(ctx.admin, name, ctx.values.preset)
            Hotbar.say(ctx.admin, txt("BodyPresetSent", name))
        elseif ZomboidFixesB42.openBodyStats then
            ZomboidFixesB42.openBodyStats(ctx.admin, name, Hotbar.findPlayer(name))
        end
    end,
})

-- 3. Teleport ------------------------------------------------------------------------------------------

register({
    id = "teleport.location",
    category = "teleport",
    title = txt("TeleportToLocation"),
    tooltip = txt("TeleportToLocationTooltip"),
    icon = "sym:House",
    params = { locationParam("@pick") },
    available = needs("TeleportToCoordinates"),
    run = function(ctx)
        local l = ctx.values.location
        if isClient() then return cmd("/teleportto " .. coordsOf(l)) end
        teleport(ctx.admin, l.x + 0.5, l.y + 0.5, l.z)
    end,
    openUI = function(ctx) AdminContextMenu.onTeleportUI(ctx.admin) end,
})

register({
    id = "teleport.ui",
    category = "teleport",
    title = getText("IGUI_GameStats_Teleport"),
    tooltip = txt("TeleportUiTooltip"),
    icon = "item:Base.Map",
    available = toolsOr("TeleportToCoordinates"),
    run = function(ctx) AdminContextMenu.onTeleportUI(ctx.admin) end,
})

-- 4. Items and keys ---------------------------------------------------------------------------------------

local itemChoices = nil
local function items()
    if itemChoices then return itemChoices end
    itemChoices = {}
    local all = getScriptManager():getAllItems()
    for i = 0, all:size() - 1 do
        local item = all:get(i)
        -- The same filter as Item List.
        if item and not item:getObsolete() and not item:isHidden() then
            table.insert(itemChoices, {
                text = (item:getDisplayName() or item:getFullName()) .. "  (" .. item:getFullName() .. ")",
                data = item:getFullName(),
                scriptItem = item,
            })
        end
    end
    table.sort(itemChoices, function(a, b) return string.lower(a.text) < string.lower(b.text) end)
    return itemChoices
end

local function itemName(fullType)
    local item = getScriptManager():getItem(fullType)
    return item and item:getDisplayName() or fullType
end

register({
    id = "items.spawn",
    category = "items",
    title = txt("SpawnItem"),
    tooltip = txt("SpawnItemTooltip"),
    icon = function(settings) return settings.item and ("item:" .. settings.item) or "item:Base.Toolbox" end,
    params = {
        { key = "item", type = "choice", title = txt("ParamItem"), options = items, search = true, textOf = itemName },
        numberParam("count", txt("ParamCount"), 1, 1, 100, true),
        playerParam("@me"),
    },
    available = needs("AddItem"),
    run = function(ctx)
        local count = math.floor(ctx.values.count or 1)
        if isClient() then
            return cmd("/additem " .. q(ctx.values.player) .. " " .. q(ctx.values.item) .. " " .. int(count))
        end
        -- Item List's single player path.
        local player = loadedPlayer(ctx)
        if not player then return end
        for _ = 1, count do
            local item = instanceItem(ctx.values.item)
            if not item then break end
            if item:getType() == "CorpseAnimal" then item:createAndStoreDefaultDeadBody(nil) end
            player:getInventory():AddItem(item)
        end
    end,
    openUI = function(ctx) openAdminWindow("ITEMLIST") end,
})

register({
    id = "items.buildingKey",
    category = "items",
    title = txt("BuildingKey"),
    tooltip = txt("BuildingKeyTooltip"),
    icon = "sym:Key",
    available = needs("AddItem"),
    run = function(ctx)
        local square = ctx.admin:getCurrentSquare()
        if not square or not square:getBuilding() then
            return Hotbar.say(ctx.admin, txt("NotInBuilding"), true)
        end
        -- The Debug menu's Get Building Key, which covers both.
        DebugContextMenu.OnGetBuildingKey(nil, ctx.admin:getPlayerNum())
    end,
})

register({
    id = "items.key",
    category = "items",
    title = txt("KeyById"),
    tooltip = txt("KeyByIdTooltip"),
    icon = "sym:Key",
    params = { numberParam("keyId", txt("ParamKeyId"), nil, 0, 2147483647, true), playerParam("@me") },
    available = needs("AddItem"),
    run = function(ctx)
        if isClient() then
            return cmd("/addkey " .. q(ctx.values.player) .. " " .. q(int(ctx.values.keyId)))
        end
        -- AdminContextMenu.OnGetDoorKey's single player path.
        local player = loadedPlayer(ctx)
        local key = player and instanceItem("Base.Key1")
        if key then
            key:setKeyId(math.floor(ctx.values.keyId))
            player:getInventory():AddItem(key)
        end
    end,
})

register({
    id = "items.list",
    category = "items",
    title = getText("IGUI_AdminPanel_ItemList"),
    icon = "item:Base.Toolbox",
    available = needs("AddItem"),
    run = function(ctx) openAdminWindow("ITEMLIST") end,
})

register({
    id = "items.removeTool",
    category = "items",
    title = getText("IGUI_DebugContext_RemoveItemTool"),
    icon = "item:Base.Garbagebag",
    available = toolsOr("EditItem"),
    run = function(ctx) AdminContextMenu.onRemoveItemTool(ctx.admin) end,
})

-- 5. Vehicles ------------------------------------------------------------------------------------------------

local vehicleChoices = nil
local function vehicles()
    if vehicleChoices then return vehicleChoices end
    vehicleChoices = {}
    local scripts = getScriptManager():getAllVehicleScripts()
    for i = 0, scripts:size() - 1 do
        local script = scripts:get(i)
        table.insert(vehicleChoices, {
            text = getText("IGUI_VehicleName" .. script:getName()) .. "  (" .. script:getFullName() .. ")",
            data = script:getFullName(),
        })
    end
    table.sort(vehicleChoices, function(a, b) return string.lower(a.text) < string.lower(b.text) end)
    return vehicleChoices
end

local function vehicleName(fullName)
    local script = getScriptManager():getVehicle(fullName)
    return script and getText("IGUI_VehicleName" .. script:getName()) or fullName
end

register({
    id = "vehicles.spawn",
    category = "vehicles",
    title = txt("SpawnVehicle"),
    tooltip = txt("SpawnVehicleTooltip"),
    icon = "item:Base.CarKey",
    params = {
        { key = "vehicle", type = "choice", title = txt("ParamVehicleType"), options = vehicles, search = true, textOf = vehicleName },
        locationParam("@me"),
    },
    available = needs("ManipulateVehicle"),
    run = function(ctx)
        local location = ctx.values.location
        -- AddVehicleCommand refuses anything above the ground floor.
        if location.z ~= 0 then return Hotbar.say(ctx.admin, txt("VehicleGroundOnly"), true) end
        if isClient() then
            return cmd("/addvehicle " .. ctx.values.vehicle .. " " .. coordsOf(location))
        end
        -- Spawn Vehicle's single player path.
        addVehicle(ctx.values.vehicle, location.x, location.y, location.z)
    end,
    openUI = function(ctx) AdminContextMenu.onSpawnVehicle(ctx.admin) end,
})

register({
    id = "vehicles.random",
    category = "vehicles",
    title = txt("RandomVehicle"),
    tooltip = txt("RandomVehicleTooltip"),
    icon = "sym:SteeringWheel",
    available = needs("ManipulateVehicle"),
    -- On a client addVehicle ignores its arguments and sends /addvehicle with a
    -- random script, which the server spawns where the admin stands. In single
    -- player an empty script also means a random one, at the given coordinates.
    run = function(ctx)
        local admin = ctx.admin
        addVehicle("", math.floor(admin:getX()), math.floor(admin:getY()), math.floor(admin:getZ()))
    end,
})

local function vehicleCommand(id, key, icon, command, argsOf)
    register({
        id = id,
        category = "vehicles",
        title = txt(key),
        tooltip = txt(key .. "Tooltip"),
        icon = icon,
        params = { vehicleParam() },
        available = needs("UseMechanicsCheat"),
        run = function(ctx)
            local vehicle = ctx.values.vehicle
            local args = argsOf and argsOf(vehicle) or {}
            args.vehicle = vehicle:getId()
            sendClientCommand(ctx.admin, "vehicle", command, args)
        end,
    })
end

vehicleCommand("vehicles.repair", "RepairVehicle", "sym:Wrench", "repair")
vehicleCommand("vehicles.key", "VehicleKey", "item:Base.CarKey", "getKey")
vehicleCommand("vehicles.hotwire", "HotwireVehicle", "sym:Lightbulb", "cheatHotwire", function(vehicle)
    return { hotwired = not vehicle:isHotwired(), broken = false }
end)
vehicleCommand("vehicles.alarm", "VehicleAlarm", "sym:Police", "setAlarmed", function(vehicle)
    return { alarmed = not vehicle:isAlarmed() }
end)

register({
    id = "vehicles.remove",
    category = "vehicles",
    title = txt("RemoveVehicle"),
    tooltip = txt("RemoveVehicleTooltip"),
    icon = "sym:X",
    confirm = true,
    params = { vehicleParam() },
    available = needs("ManipulateVehicle"),
    run = function(ctx) removeVehicle(ctx.admin, ctx.values.vehicle) end,
})

register({
    id = "vehicles.removeAll",
    category = "vehicles",
    title = txt("RemoveAllVehicles"),
    tooltip = txt("RemoveAllVehiclesTooltip"),
    icon = "sym:Radiation",
    confirm = true,
    -- The /remove command needs AnimalCheats whatever it removes.
    available = needs("AnimalCheats"),
    -- /remove vehicles on a client, VehicleManager.removeVehicles in single player.
    run = function(ctx) removeAllVehicles(ctx.admin) end,
})

register({
    id = "vehicles.ui",
    category = "vehicles",
    title = getText("IGUI_DebugContext_SpawnVehicle"),
    icon = "sym:Tire",
    available = needs("ManipulateVehicle"),
    run = function(ctx) AdminContextMenu.onSpawnVehicle(ctx.admin) end,
})

-- 6. Zombies ----------------------------------------------------------------------------------------------

local outfitChoices = nil
local function outfits()
    if outfitChoices then return outfitChoices end
    outfitChoices = {}
    local male, female = getAllOutfits(false), getAllOutfits(true)
    local seen = {}
    for _, list in ipairs({ male, female }) do
        for i = 0, list:size() - 1 do
            local name = list:get(i)
            if not seen[name] then
                seen[name] = true
                local text = name
                if not female:contains(name) then
                    text = name .. " - " .. getText("IGUI_SpawnHorde_MaleOnly")
                elseif not male:contains(name) then
                    text = name .. " - " .. getText("IGUI_SpawnHorde_FemaleOnly")
                end
                table.insert(outfitChoices, { text = text, data = name })
            end
        end
    end
    table.sort(outfitChoices, function(a, b) return a.text < b.text end)
    return outfitChoices
end

-- How far single player's Remove corpses reaches, around the admin.
local CORPSE_RADIUS = 60

local HORDE_FLAGS = {
    { key = "knockedDown", title = "IGUI_SpawnHorde_KnockedDown", arg = "-knockedDown" },
    { key = "crawler", title = "IGUI_SpawnHorde_Crawler", arg = "-crawler" },
    { key = "fakeDead", title = "IGUI_SpawnHorde_FakeDead", arg = "-isFakeDead" },
    { key = "fallOnFront", title = "IGUI_SpawnHorde_FallOnFront", arg = "-isFallOnFront" },
    { key = "invulnerable", title = "IGUI_SpawnHorde_Invulnerable", arg = "-isInvulnerable" },
    { key = "sitting", title = "IGUI_SpawnHorde_Sitting", arg = "-isSitting" },
    { key = "ragdoll", title = "IGUI_SpawnHorde_Ragdolling", arg = "-isRagdolling" },
    { key = "onFire", title = "IGUI_SpawnHorde_OnFire", arg = "-onFire" },
}
Hotbar.HORDE_FLAGS = HORDE_FLAGS

--- CreateHorde2Command: count is capped at 500 there; radius 0 puts every zombie on
-- the square itself.
local function hordeCommand(location, values)
    local parts = {
        "/createhorde2",
        "-x", int(location.x), "-y", int(location.y), "-z", int(location.z),
        "-count", int(values.count or 1), "-radius", int(values.radius or 0),
        "-health", tostring(values.health or 1),
    }
    for _, flag in ipairs(HORDE_FLAGS) do
        table.insert(parts, flag.arg)
        table.insert(parts, values[flag.key] and "true" or "false")
    end
    if values.outfit and values.outfit ~= "" then
        table.insert(parts, "-outfit")
        table.insert(parts, values.outfit)
    end
    return table.concat(parts, " ")
end

--- ISSpawnHordeUI's single player path: one addZombiesInOutfit per zombie, spread
-- over the radius, with the female chance an outfit for one sex needs.
local function spawnHordeLocally(location, values)
    local outfit = values.outfit
    if outfit == "" then outfit = nil end
    local femaleChance = nil
    if outfit then
        local male, female = getAllOutfits(false), getAllOutfits(true)
        if male:contains(outfit) and not female:contains(outfit) then femaleChance = 0 end
        if female:contains(outfit) and not male:contains(outfit) then femaleChance = 100 end
    end
    local radius = math.floor(values.radius or 0)
    for _ = 1, math.floor(values.count or 1) do
        local x = ZombRand(location.x - radius, location.x + radius + 1)
        local y = ZombRand(location.y - radius, location.y + radius + 1)
        addZombiesInOutfit(x, y, location.z, 1, outfit, femaleChance,
            values.crawler == true, values.fallOnFront == true, values.fakeDead == true, values.knockedDown == true,
            values.invulnerable == true, values.sitting == true, values.health or 1, false, 0,
            values.ragdoll == true, values.onFire == true)
    end
end

local function spawnHorde(location, values)
    if isClient() then
        cmd(hordeCommand(location, values))
    else
        spawnHordeLocally(location, values)
    end
end

local hordeParams = {
    locationParam("@me"),
    numberParam("count", txt("ParamCount"), 10, 1, 500, true),
    numberParam("radius", txt("ParamRadius"), 5, 0, 50, true),
    { key = "outfit", type = "choice", title = getText("IGUI_SpawnHorde_ZombieOutfit"), options = outfits, search = true, optional = true },
    numberParam("health", getText("IGUI_SpawnHorde_Health"), 1, 0, 2, false),
}
for _, flag in ipairs(HORDE_FLAGS) do
    table.insert(hordeParams, boolParam(flag.key, getText(flag.title), false))
end

local function openHordeManager(ctx)
    local square = ctx.admin:getCurrentSquare()
    local location = ctx.values.location
    if location then
        square = getCell():getGridSquare(location.x, location.y, location.z) or square
    end
    if square then AdminContextMenu.onHordeManager(square, ctx.admin) end
end

register({
    id = "zombies.horde",
    category = "zombies",
    title = txt("SpawnHorde"),
    tooltip = txt("SpawnHordeTooltip"),
    icon = "sym:Z",
    params = hordeParams,
    available = needs("CreateHorde"),
    run = function(ctx) spawnHorde(ctx.values.location, ctx.values) end,
    openUI = openHordeManager,
})

register({
    id = "zombies.hordeNear",
    category = "zombies",
    title = txt("HordeNearPlayer"),
    tooltip = txt("HordeNearPlayerTooltip"),
    icon = "sym:Skull",
    params = { playerParam("@me"), numberParam("count", txt("ParamCount"), 10, 1, 500, true) },
    available = needs("CreateHorde"),
    run = function(ctx)
        if isClient() then
            return cmd("/createhorde " .. int(ctx.values.count) .. " " .. q(ctx.values.player))
        end
        -- CreateHordeCommand spreads them within 10 squares of the player.
        local player = loadedPlayer(ctx)
        if not player then return end
        local position = { x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()) }
        spawnHordeLocally(position, { count = ctx.values.count, radius = 10, health = 1 })
    end,
})

register({
    id = "zombies.add",
    category = "zombies",
    title = txt("AddZombie"),
    tooltip = txt("AddZombieTooltip"),
    icon = "sym:FaceDead",
    params = { locationParam("@pick") },
    available = needs("CreateHorde"),
    run = function(ctx) spawnHorde(ctx.values.location, { count = 1, radius = 0, health = 1 }) end,
})

register({
    id = "zombies.removeRadius",
    category = "zombies",
    title = txt("RemoveZombiesRadius"),
    tooltip = txt("RemoveZombiesRadiusTooltip"),
    icon = "sym:Cross",
    params = { locationParam("@me"), numberParam("radius", txt("ParamRadius"), 10, 1, 100, true) },
    available = needs("ManipulateZombie"),
    run = function(ctx)
        local l = ctx.values.location
        local radius = math.floor(ctx.values.radius or 10)
        if isClient() then
            return cmd(string.format("/removezombies -x %s -y %s -z %s -radius %s", int(l.x), int(l.y), int(l.z), int(radius)))
        end
        -- Horde Manager's single player Remove Zombies.
        local cell = getCell()
        for x = l.x - radius, l.x + radius do
            for y = l.y - radius, l.y + radius do
                local square = cell:getGridSquare(x, y, l.z)
                if square then
                    local movers = square:getMovingObjects()
                    for i = movers:size(), 1, -1 do
                        local zombie = movers:get(i - 1)
                        if instanceof(zombie, "IsoZombie") then
                            zombie:removeFromWorld()
                            zombie:removeFromSquare()
                        end
                    end
                end
            end
        end
    end,
})

register({
    id = "zombies.removeAll",
    category = "zombies",
    title = getText("IGUI_SpawnHorde_RemoveAllZombies"),
    tooltip = txt("RemoveAllZombiesTooltip"),
    icon = "sym:Radiation",
    confirm = true,
    available = needs("ManipulateZombie"),
    run = function(ctx)
        if isClient() then return cmd("/removezombies -remove true") end
        DebugContextMenu.OnRemoveAllZombies()
    end,
})

register({
    id = "zombies.removeCorpses",
    category = "zombies",
    title = txt("RemoveCorpses"),
    tooltip = txt("RemoveCorpsesTooltip"),
    icon = "sym:Garbage",
    confirm = true,
    available = needs("AnimalCheats"),
    run = function(ctx)
        if isClient() then return cmd("/remove corpses") end
        -- Horde Manager's single player Remove Bodies, over the loaded area around you.
        local admin = ctx.admin
        local cx, cy, z = math.floor(admin:getX()), math.floor(admin:getY()), math.floor(admin:getZ())
        local cell = getCell()
        for x = cx - CORPSE_RADIUS, cx + CORPSE_RADIUS do
            for y = cy - CORPSE_RADIUS, cy + CORPSE_RADIUS do
                local square = cell:getGridSquare(x, y, z)
                if square then
                    local bodies = {}
                    local objects = square:getStaticMovingObjects()
                    for i = 0, objects:size() - 1 do
                        if instanceof(objects:get(i), "IsoDeadBody") then table.insert(bodies, objects:get(i)) end
                    end
                    for _, body in ipairs(bodies) do square:removeCorpse(body, false) end
                end
            end
        end
    end,
})

register({
    id = "zombies.manager",
    category = "zombies",
    title = getText("IGUI_DebugContext_HordeManager"),
    icon = "sym:Target",
    available = needs("CreateHorde"),
    run = function(ctx) openHordeManager(ctx) end,
})

-- 7. Noise, fire and explosions ------------------------------------------------------------------------------

local NOISE_RADII = { 10, 20, 50, 100, 200, 500 }
local noiseChoices = {}
for _, radius in ipairs(NOISE_RADII) do
    table.insert(noiseChoices, { text = getText("IGUI_DebugContext_Radius") .. ": " .. radius, data = radius })
end

register({
    id = "noise.make",
    category = "noise",
    title = getText("IGUI_DebugContext_MakeNoise"),
    tooltip = txt("MakeNoiseTooltip"),
    icon = "item:Base.NoiseTrap",
    params = {
        locationParam("@me"),
        { key = "radius", type = "choice", title = txt("ParamRadius"), options = noiseChoices, default = 50, noAsk = true },
        numberParam("volume", txt("ParamVolume"), 100, 1, 100, true),
    },
    available = toolsOr("UseDebugContextMenu"),
    -- WorldSoundManager sends a client's sound to the server.
    run = function(ctx)
        local l = ctx.values.location
        addSound(ctx.admin, l.x, l.y, l.z, ctx.values.radius or 50, ctx.values.volume or 100)
    end,
})

local function fireCommand(id, key, icon, command, confirm)
    register({
        id = id,
        category = "noise",
        title = txt(key),
        tooltip = txt(key .. "Tooltip"),
        icon = icon,
        confirm = confirm,
        params = { locationParam("@pick") },
        available = needs("UseBrushToolManager"),
        run = function(ctx)
            local l = ctx.values.location
            sendClientCommand(ctx.admin, "object", command, { x = l.x, y = l.y, z = l.z })
        end,
    })
end

fireCommand("noise.fire", "StartFire", "sym:Fire", "addFireOnSquare", false)
fireCommand("noise.smoke", "MakeSmoke", "item:Base.SmokeBomb", "addSmokeOnSquare", false)
fireCommand("noise.explosion", "Explosion", "sym:Bomb", "addExplosionOnSquare", true)

register({
    id = "noise.brushTool",
    category = "noise",
    title = txt("BrushTool"),
    tooltip = txt("BrushToolTooltip"),
    icon = "item:Base.Paintbrush",
    available = needs("UseBrushToolManager"),
    run = function(ctx) BrushToolManager.openPanel(ctx.admin) end,
})

-- 8. Weather and climate ----------------------------------------------------------------------------------

-- ClimateManager's precipitation, the float /startrain drives (index 3).
local FLOAT_PRECIPITATION = 3

--- What /startrain and /stoprain do on the server, for single player.
local function setRainLocally(on, intensity)
    local precipitation = getClimateManager():getClimateFloat(FLOAT_PRECIPITATION)
    if on then
        precipitation:setAdminValue(math.max(0, math.min(1, intensity / 100)))
    end
    precipitation:setEnableAdmin(on)
end

register({
    id = "weather.rain",
    category = "weather",
    title = txt("Rain"),
    tooltip = txt("RainTooltip"),
    icon = "item:Base.UmbrellaBlack",
    params = { numberParam("intensity", txt("ParamIntensity"), 50, 1, 100, true) },
    available = needs("StartStopRain"),
    toggle = {
        isOn = function(ctx) return getClimateManager():isRaining() == true end,
        set = function(ctx, on)
            if on == nil then on = not getClimateManager():isRaining() end
            if not isClient() then return setRainLocally(on, ctx.values.intensity or 50) end
            if on then
                cmd("/startrain " .. int(ctx.values.intensity or 50))
            else
                cmd("/stoprain")
            end
        end,
    },
})

register({
    id = "weather.storm",
    category = "weather",
    title = txt("Thunderstorm"),
    tooltip = txt("ThunderstormTooltip"),
    icon = "sym:Lightning",
    params = { numberParam("hours", txt("ParamHours"), 24, 1, 240, true) },
    available = needs("StartStopRain"),
    run = function(ctx)
        if isClient() then return cmd("/startstorm " .. int(ctx.values.hours or 24)) end
        getClimateManager():triggerCustomWeatherStage(WeatherPeriod.STAGE_STORM, ctx.values.hours or 24)
    end,
})

register({
    id = "weather.stop",
    category = "weather",
    title = getText("IGUI_climate_StopWeather"),
    tooltip = txt("StopWeatherTooltip"),
    icon = "sym:Sun",
    available = needs("StartStopRain"),
    run = function(ctx)
        if isClient() then return cmd("/stopweather") end
        getClimateManager():stopWeatherAndThunder()
    end,
})

local WEATHER_KINDS = {
    { text = getText("IGUI_climate_TriggerStorm"), data = "storm", icon = "sym:Lightning" },
    { text = getText("IGUI_climate_TriggerTropical"), data = "tropical", icon = "sym:Waves" },
    { text = getText("IGUI_climate_TriggerBlizzard"), data = "blizzard", icon = "sym:Snowflake" },
    { text = getText("IGUI_climate_Generate"), data = "generate", icon = "sym:Sun" },
}

register({
    id = "weather.event",
    category = "weather",
    title = txt("WeatherEvent"),
    tooltip = txt("WeatherEventTooltip"),
    icon = function(settings)
        for _, kind in ipairs(WEATHER_KINDS) do
            if kind.data == settings.kind then return kind.icon end
        end
        return "sym:Lightning"
    end,
    params = {
        { key = "kind", type = "choice", title = txt("ParamWeatherKind"), options = WEATHER_KINDS, default = "storm", noAsk = true },
        numberParam("hours", txt("ParamHours"), 24, 4, 240, true),
        numberParam("strength", txt("ParamStrength"), 0.8, 0.1, 1, false, txt("StrengthHint")),
        {
            key = "front", type = "choice", title = txt("ParamFront"), default = "warm", noAsk = true,
            options = {
                { text = getText("IGUI_climate_WarmFront"), data = "warm" },
                { text = getText("IGUI_climate_ColdFront"), data = "cold" },
            },
        },
    },
    available = needs("ClimateManager"),
    run = function(ctx)
        local clim = getClimateManager()
        local v = ctx.values
        -- The Weather tab's two paths: transmit on a client, trigger directly in single player.
        if not isClient() then
            if v.kind == "tropical" then
                clim:triggerCustomWeatherStage(WeatherPeriod.STAGE_TROPICAL_STORM, v.hours)
            elseif v.kind == "blizzard" then
                clim:triggerCustomWeatherStage(WeatherPeriod.STAGE_BLIZZARD, v.hours)
            elseif v.kind == "generate" then
                clim:triggerCustomWeather(v.strength, v.front ~= "cold")
            else
                clim:triggerCustomWeatherStage(WeatherPeriod.STAGE_STORM, v.hours)
            end
            return
        end
        if v.kind == "tropical" then
            clim:transmitTriggerTropical(v.hours)
        elseif v.kind == "blizzard" then
            clim:transmitTriggerBlizzard(v.hours)
        elseif v.kind == "generate" then
            clim:transmitGenerateWeather(v.strength, v.front == "cold" and 1 or 0)
        else
            clim:transmitTriggerStorm(v.hours)
        end
    end,
    openUI = function(ctx) openAdminWindow("CLIMATE") end,
})

-- Climate preset: ISAdmPanelClimate's own indexes (file locals there).
local FLOAT_COUNT = 13
local BOOL_IS_SNOW = 0
local COLOR_GLOBAL_LIGHT = 0

local function close(a, b) return math.abs((a or 0) - (b or 0)) < 0.01 end

local function colorMatches(color, saved)
    return saved == nil or (close(color:getRedFloat(), saved.r) and close(color:getGreenFloat(), saved.g)
        and close(color:getBlueFloat(), saved.b) and close(color:getAlphaFloat(), saved.a))
end

--- A preset is on while every value it holds is the active admin value.
local function presetIsOn(preset)
    local clim = getClimateManager()
    for index, value in pairs(preset.floats or {}) do
        local var = clim:getClimateFloat(index)
        if not var or not var:isEnableAdmin() or not close(var:getAdminValue(), value) then return false end
    end
    if preset.snow ~= nil then
        local var = clim:getClimateBool(BOOL_IS_SNOW)
        if not var or not var:isEnableAdmin() or var:getAdminValue() ~= preset.snow then return false end
    end
    if preset.light then
        local var = clim:getClimateColor(COLOR_GLOBAL_LIGHT)
        if not var or not var:isEnableAdmin() then return false end
        local info = var:getAdminValue()
        if not colorMatches(info:getExterior(), preset.light.ext) or not colorMatches(info:getInterior(), preset.light.int) then
            return false
        end
    end
    return true
end

local function applyPreset(preset, on)
    local clim = getClimateManager()
    for index, value in pairs(preset.floats or {}) do
        local var = clim:getClimateFloat(index)
        if var then
            var:setEnableAdmin(on)
            if on then var:setAdminValue(value) end
        end
    end
    if preset.snow ~= nil then
        local var = clim:getClimateBool(BOOL_IS_SNOW)
        if var then
            var:setEnableAdmin(on)
            if on then var:setAdminValue(preset.snow) end
        end
    end
    if preset.light then
        local var = clim:getClimateColor(COLOR_GLOBAL_LIGHT)
        if var then
            var:setEnableAdmin(on)
            if on then
                local ext, inside = preset.light.ext, preset.light.int
                if ext then var:setAdminValueExterior(ext.r, ext.g, ext.b, ext.a) end
                if inside then var:setAdminValueInterior(inside.r, inside.g, inside.b, inside.a) end
            end
        end
    end
    clim:transmitClientChangeAdminVars()
end

--- The overrides ticked in Climate Control right now, as a preset. nil if none.
function Hotbar.captureClimate()
    local clim = getClimateManager()
    local preset = { floats = {} }
    local count = 0
    for index = 0, FLOAT_COUNT - 1 do
        local var = clim:getClimateFloat(index)
        if var and var:isEnableAdmin() then
            preset.floats[index] = var:getAdminValue()
            count = count + 1
        end
    end
    local snow = clim:getClimateBool(BOOL_IS_SNOW)
    if snow and snow:isEnableAdmin() then
        preset.snow = snow:getAdminValue() == true
        count = count + 1
    end
    local light = clim:getClimateColor(COLOR_GLOBAL_LIGHT)
    if light and light:isEnableAdmin() then
        local info = light:getAdminValue()
        local ext, inside = info:getExterior(), info:getInterior()
        preset.light = {
            ext = { r = ext:getRedFloat(), g = ext:getGreenFloat(), b = ext:getBlueFloat(), a = ext:getAlphaFloat() },
            int = { r = inside:getRedFloat(), g = inside:getGreenFloat(), b = inside:getBlueFloat(), a = inside:getAlphaFloat() },
        }
        count = count + 1
    end
    if count == 0 then return nil end
    return preset
end

local function presetSize(preset)
    local count = 0
    for _ in pairs(preset.floats or {}) do count = count + 1 end
    if preset.snow ~= nil then count = count + 1 end
    if preset.light then count = count + 1 end
    return count
end

register({
    id = "weather.preset",
    category = "weather",
    title = txt("ClimatePreset"),
    tooltip = txt("ClimatePresetTooltip"),
    icon = "sym:Moon",
    climate = true,
    params = {
        {
            key = "preset", type = "preset", title = txt("ParamClimatePreset"),
            summary = function(preset) return txt("ClimatePresetSummary", int(presetSize(preset))) end,
        },
    },
    available = needs("ClimateManager"),
    toggle = {
        applies = function(ctx) return ctx.values.preset ~= nil end,
        isOn = function(ctx) return presetIsOn(ctx.values.preset) end,
        set = function(ctx, on)
            if on == nil then on = not presetIsOn(ctx.values.preset) end
            applyPreset(ctx.values.preset, on)
        end,
    },
    run = function(ctx)
        -- No preset yet: the way to make one is Climate Control's Add to Hotbar.
        Hotbar.say(ctx.admin, txt("ClimatePresetEmpty"), true)
        openAdminWindow("CLIMATE")
    end,
    openUI = function(ctx) openAdminWindow("CLIMATE") end,
})

--- LightningCommand / ThunderCommand / event.thunder, for single player: outside a
-- server ThunderStorm.triggerThunderEvent queues the event locally.
local function thunderAt(player, strike, light, rumble)
    getClimateManager():getThunderStorm():triggerThunderEvent(math.floor(player:getX()), math.floor(player:getY()), strike, light, rumble)
end

register({
    id = "weather.lightning",
    category = "weather",
    title = txt("LightningOnPlayer"),
    tooltip = txt("LightningOnPlayerTooltip"),
    icon = "sym:Lightning",
    params = { playerParam("@me") },
    available = needs("MakeEventsAlarmGunshot"),
    run = function(ctx)
        if isClient() then return cmd("/lightning " .. q(ctx.values.player)) end
        local player = loadedPlayer(ctx)
        if player then thunderAt(player, false, true, true) end
    end,
})

register({
    id = "weather.thunder",
    category = "weather",
    title = txt("ThunderOnPlayer"),
    tooltip = txt("ThunderOnPlayerTooltip"),
    icon = "sym:Asterisk",
    params = { playerParam("@me") },
    available = needs("StartStopRain"),
    run = function(ctx)
        if isClient() then return cmd("/thunder " .. q(ctx.values.player)) end
        local player = loadedPlayer(ctx)
        if player then thunderAt(player, false, false, true) end
    end,
})

register({
    id = "weather.thunderAll",
    category = "weather",
    title = txt("ThunderEveryone"),
    tooltip = txt("ThunderEveryoneTooltip"),
    icon = "sym:Lightning",
    available = toolsGate,
    run = function(ctx)
        if isClient() then return sendClientCommand(ctx.admin, "event", "thunder", { isAll = true }) end
        -- The server handler walks getOnlinePlayers(), which is empty in single player.
        for i = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(i)
            if player then thunderAt(player, true, true, true) end
        end
    end,
})

register({
    id = "weather.thunderUI",
    category = "weather",
    title = txt("TriggerThunderWindow"),
    icon = "sym:Asterisk",
    -- Its player list is getOnlinePlayers(), empty in single player.
    available = mpOnly(toolsGate),
    run = function(ctx) AdminContextMenu.onTriggerThunderUI(ctx.admin) end,
})

register({
    id = "weather.climate",
    category = "weather",
    title = getText("IGUI_Adm_Weather_ClimateControl"),
    icon = "sym:Sun",
    available = needs("ClimateManager"),
    run = function(ctx) openAdminWindow("CLIMATE") end,
})

-- 9. Meta events ---------------------------------------------------------------------------------------------

register({
    id = "meta.gunshot",
    category = "meta",
    title = txt("Gunshot"),
    tooltip = txt("GunshotTooltip"),
    icon = "item:Base.Pistol",
    available = needs("MakeEventsAlarmGunshot"),
    run = function(ctx)
        if isClient() then return cmd("/gunshot") end
        getAmbientStreamManager():doGunEvent()
    end,
})

register({
    id = "meta.alarm",
    category = "meta",
    title = txt("BuildingAlarm"),
    tooltip = txt("BuildingAlarmTooltip"),
    icon = "sym:Police",
    available = needs("MakeEventsAlarmGunshot"),
    run = function(ctx)
        local square = ctx.admin:getCurrentSquare()
        if not square or not square:getRoom() then return Hotbar.say(ctx.admin, txt("NotInBuilding"), true) end
        if isClient() then return cmd("/alarm") end
        -- What AlarmCommand does on the server.
        square:getBuilding():getDef():setAlarmed(true)
        getAmbientStreamManager():doAlarm(square:getRoom():getRoomDef())
    end,
})

--- Our broadcast stop on a server with Chopper Controls on; otherwise the debug
-- panel's own calls, which send /chopper on a client and act directly in single player.
local function chopper(action)
    local Chopper = ZomboidFixesB42.Chopper
    if isClient() and Chopper and Chopper.isEnabled() then
        Chopper.send(getPlayer(), action)
    elseif action == "start" then
        testHelicopter()
    else
        endHelicopter()
    end
end

register({
    id = "meta.chopperSend",
    category = "meta",
    title = txt("SendChopper"),
    tooltip = txt("SendChopperTooltip"),
    icon = "item:Base.WalkieTalkie1",
    available = needs("MakeEventsAlarmGunshot"),
    run = function(ctx) chopper("start") end,
})

register({
    id = "meta.chopperStop",
    category = "meta",
    title = txt("StopChopper"),
    tooltip = txt("StopChopperTooltip"),
    icon = "sym:X",
    available = needs("MakeEventsAlarmGunshot"),
    run = function(ctx) chopper("stop") end,
})

-- 10. Stories -------------------------------------------------------------------------------------------------

local function findStory(list, name)
    for i = 0, list:size() - 1 do
        local story = list:get(i)
        if story:getName() == name then return story end
    end
    return nil
end

local function storyChoices(list)
    local choices = {}
    for i = 0, list:size() - 1 do
        local story = list:get(i)
        table.insert(choices, { text = story:getName(), data = story:getName() })
    end
    table.sort(choices, function(a, b) return a.text < b.text end)
    return choices
end

register({
    id = "stories.road",
    category = "stories",
    title = getText("IGUI_DebugContext_RandomizedRoadStory"),
    tooltip = txt("RoadStoryTooltip"),
    icon = "sym:Tire",
    params = {
        { key = "story", type = "choice", title = txt("ParamStory"), search = true,
          options = function() return storyChoices(getWorld():getRandomizedVehicleStoryList()) end },
        locationParam("@pick"),
    },
    available = needs("CreateStory"),
    run = function(ctx)
        local square = squareAt(ctx, ctx.values.location)
        local story = square and findStory(getWorld():getRandomizedVehicleStoryList(), ctx.values.story)
        -- The Debug menu's own call: sendDebugStory on a client, the story itself in single player.
        if story then DebugContextMenu.doRandomizedVehicleStory(square, story) end
    end,
})

register({
    id = "stories.zone",
    category = "stories",
    title = getText("IGUI_DebugContext_RandomizedZoneStory"),
    tooltip = txt("ZoneStoryTooltip"),
    icon = "sym:Tent",
    params = {
        { key = "story", type = "choice", title = txt("ParamStory"), search = true,
          options = function() return storyChoices(getWorld():getRandomizedZoneList()) end },
        locationParam("@pick"),
    },
    available = needs("CreateStory"),
    run = function(ctx)
        local square = squareAt(ctx, ctx.values.location)
        if not square then return end
        -- DebugContextMenu refuses a zone story next to a fence, which it cannot place.
        if square:hasFenceInVicinity() then
            return Hotbar.say(ctx.admin, getText("IGUI_DebugContext_RandomizedZoneStoryFenceVicinity"), true)
        end
        local story = findStory(getWorld():getRandomizedZoneList(), ctx.values.story)
        if story then DebugContextMenu.doRandomizedZoneStory(square, story) end
    end,
})

-- 11. Animals --------------------------------------------------------------------------------------------------

local GROUP_ICONS = {
    chicken = "sym:Chicken", cow = "sym:Cow", pig = "sym:Pig", sheep = "sym:Sheep", rabbit = "sym:Rabbit",
    deer = "sym:Deer", turkey = "sym:Turkey", raccoon = "sym:Raccoon", rat = "sym:Rodent", mouse = "sym:Rodent",
}

local animalChoices = nil
local function animals()
    if animalChoices then return animalChoices end
    animalChoices = {}
    local defs = getAllAnimalsDefinitions()
    for i = 0, defs:size() - 1 do
        local def = defs:get(i)
        local breeds = def:getBreeds()
        for j = 0, breeds:size() - 1 do
            local breed = breeds:get(j)
            table.insert(animalChoices, {
                text = getText("IGUI_AnimalType_" .. def:getAnimalType()) .. " - " .. getText("IGUI_Breed_" .. breed:getName()),
                data = def:getAnimalType() .. "|" .. breed:getName(),
            })
        end
    end
    table.sort(animalChoices, function(a, b) return a.text < b.text end)
    return animalChoices
end

local function splitAnimal(data)
    return string.match(data or "", "^([^|]+)|(.+)$")
end

register({
    id = "animals.add",
    category = "animals",
    title = txt("AddAnimal"),
    tooltip = txt("AddAnimalTooltip"),
    icon = function(settings)
        local animalType = splitAnimal(settings.animal)
        local def = animalType and AnimalDefinitions.getDef(animalType)
        local group = def and def:getGroup()
        return group and GROUP_ICONS[string.lower(group)] or "sym:Pawprint"
    end,
    params = {
        { key = "animal", type = "choice", title = txt("ParamAnimal"), options = animals, search = true },
        boolParam("skeleton", txt("ParamSkeleton"), false),
        locationParam("@pick"),
    },
    available = needs("AnimalCheats"),
    run = function(ctx)
        local animalType, breedName = splitAnimal(ctx.values.animal)
        local def = animalType and AnimalDefinitions.getDef(animalType)
        local breed = def and def:getBreedByName(breedName)
        local square = breed and squareAt(ctx, ctx.values.location)
        -- The Debug menu's Add Animal: animal.add on a client, addAnimal in single player.
        if square then
            DebugContextMenu.AddAnimal(animalType, breed, square, ctx.values.skeleton == true, ctx.admin)
        end
    end,
})

register({
    id = "animals.enclosure",
    category = "animals",
    title = getText("IGUI_DebugContext_AddEnclosure"),
    tooltip = txt("AddEnclosureTooltip"),
    icon = "sym:Columns",
    available = needs("UseDebugContextMenu"),
    run = function(ctx) DebugContextMenu.onAddEnclosure(ctx.admin) end,
})

register({
    id = "animals.removeAll",
    category = "animals",
    title = txt("RemoveAllAnimals"),
    tooltip = txt("RemoveAllAnimalsTooltip"),
    icon = "sym:Pawprint",
    confirm = true,
    available = needs("AnimalCheats"),
    run = function(ctx)
        if isClient() then return cmd("/remove animals") end
        DebugContextMenu.OnRemoveAllAnimals()
    end,
})

-- 12. Server ----------------------------------------------------------------------------------------------------

register({
    id = "server.message",
    category = "server",
    title = txt("ServerMessage"),
    tooltip = txt("ServerMessageTooltip"),
    icon = "item:Base.Bullhorn",
    params = { textParam("text", txt("ParamMessage")) },
    available = mpOnly(needs("DisplayServerMessage")),
    run = function(ctx) cmd("/servermsg " .. q(ctx.values.text)) end,
})

register({
    id = "server.save",
    category = "server",
    title = txt("SaveWorld"),
    tooltip = txt("SaveWorldTooltip"),
    icon = "item:Base.Disc_Retail",
    available = mpOnly(needs("SaveWorld")),
    run = function(ctx) cmd("/save") end,
})

local function serverOptionChoices()
    local choices = {}
    local names = ServerOptions.getInstance():getPublicOptions()
    for i = 0, names:size() - 1 do
        local name = names:get(i)
        table.insert(choices, { text = name, data = name })
    end
    table.sort(choices, function(a, b) return a.text < b.text end)
    return choices
end

local function serverOption(name)
    return name and ServerOptions.getInstance():getOptionByName(name) or nil
end

local function isBooleanOption(name)
    local option = serverOption(name)
    return option ~= nil and instanceof(option, "BooleanConfigOption")
end

--- /changeoption then /reloadoptions, as the server options window does, and the
-- same local update it makes so the window and the toggle show the new value.
local function changeOption(name, value)
    cmd("/changeoption " .. name .. " " .. q(value))
    cmd("/reloadoptions")
    local option = serverOption(name)
    if option then
        pcall(function() option:asConfigOption():setValueFromObject(value) end)
    end
end

register({
    id = "server.option",
    category = "server",
    title = function(slot)
        local name = slot and slot.settings and slot.settings.option
        return name and txt("ServerOptionNamed", name) or txt("ServerOption")
    end,
    tooltip = txt("ServerOptionTooltip"),
    icon = "sym:Gears",
    params = {
        { key = "option", type = "choice", title = txt("ParamServerOption"), options = serverOptionChoices, search = true },
        textParam("value", txt("ParamValue"), true, txt("ValueHint")),
    },
    available = mpOnly(needs("ChangeAndReloadServerOptions")),
    toggle = {
        applies = function(ctx) return isBooleanOption(ctx.values.option) end,
        isOn = function(ctx) return serverOption(ctx.values.option):getValue() == true end,
        set = function(ctx, on)
            if on == nil then on = not serverOption(ctx.values.option):getValue() end
            changeOption(ctx.values.option, on and "true" or "false")
        end,
    },
    run = function(ctx)
        if ctx.values.value == nil then
            return Hotbar.prompt(ctx.values.option, serverOption(ctx.values.option) and serverOption(ctx.values.option):getValueAsString() or "", false,
                function(text) changeOption(ctx.values.option, text) end)
        end
        changeOption(ctx.values.option, ctx.values.value)
    end,
})

register({
    id = "server.reloadOptions",
    category = "server",
    title = getText("IGUI_PlayerStats_ReloadOptions"),
    tooltip = txt("ReloadOptionsTooltip"),
    icon = "sym:ArrowEast",
    available = mpOnly(needs("ChangeAndReloadServerOptions")),
    run = function(ctx) cmd("/reloadoptions") end,
})

register({
    id = "server.checkMods",
    category = "server",
    title = txt("CheckMods"),
    tooltip = txt("CheckModsTooltip"),
    icon = "sym:Question",
    available = mpOnly(needs("ManipulateMods")),
    run = function(ctx) cmd("/checkModsNeedUpdate") end,
})

-- 13. Windows -------------------------------------------------------------------------------------------------------

register({
    id = "window:ADMINPANEL",
    category = "windows",
    title = getText("IGUI_AdminPanel_AdminPanel"),
    icon = "tex:media/ui/Admin_Icon.png",
    -- Every button of the panel is decided by the role, so single player gets an
    -- empty panel that closes itself.
    available = mpOnly(),
    run = function(ctx)
        if ISAdminPanelUI.instance then
            ISAdminPanelUI.instance:close()
        else
            local panel = ISAdminPanelUI:new(200, 200, 350, 400)
            panel:initialise()
            panel:addToUIManager()
        end
    end,
})

register({
    id = "window:ADMINPOWER",
    category = "windows",
    title = getText("IGUI_AdminPanel_AdminPower"),
    icon = "sym:Star",
    available = function(admin)
        if not isClient() then return true end
        local role = admin:getRole()
        if role and role:hasAdminPower() then return true end
        return false, txt("NeedsAdminPower")
    end,
    run = function(ctx) ISAdminPowerUI.OnOpenPanel() end,
})

-- The windows about the server, its users and zones only exist in multiplayer.
local WINDOWS = {
    { "CHECKSTATS", "IGUI_AdminPanel_CheckYourStats", "item:Base.Clipboard", needs("CanSeePlayersStats") },
    { "ITEMLIST", "IGUI_AdminPanel_ItemList", "item:Base.Toolbox", needs("AddItem") },
    { "SEEOPTIONS", "IGUI_AdminPanel_SeeServerOptions", "sym:Gears", mpOnly(needs("SeePublicServerOptions")) },
    { "NONPVPZONE", "IGUI_AdminPanel_NonPvpZone", "sym:CrossedSwords", mpOnly(needs("CanSetupNonPVPZone")) },
    { "SEEFACTIONS", "IGUI_AdminPanel_SeeFaction", "sym:Club", mpOnly(needs("FactionCheat")) },
    { "SEEROLES", "IGUI_AdminPanel_SeeRoles", "sym:Armor", mpOnly(needs("RolesRead")) },
    { "SEEUSERS", "IGUI_AdminPanel_SeeUsers", "sym:FaceHappy", mpOnly(needs("SeeNetworkUsers")) },
    { "SEESAFEHOUSES", "IGUI_AdminPanel_SeeSafehouses", "sym:House", mpOnly(needs("CanSetupSafehouses")) },
    { "SAFEZONE", "IGUI_AdminPanel_Safezone", "sym:Lock", mpOnly(needs("CanSetupSafehouses")) },
    { "SEETICKETS", "IGUI_AdminPanel_SeeTickets", "sym:Exclamation", mpOnly(needs("AnswerTickets")) },
    { "MINISCOREBOARD", "IGUI_AdminPanel_MiniScoreboard", "sym:Columns", mpOnly(needs("SeePlayersConnected")) },
    { "SANDBOX", "IGUI_AdminPanel_SandboxOptions", "sym:Gears", mpOnly(needs("SandboxOptions")) },
    { "CLIMATE", "IGUI_Adm_Weather_ClimateControl", "sym:Sun", needs("ClimateManager") },
    { "STATISTICS", "IGUI_AdminPanel_ShowStatistics", "sym:Diamond", mpOnly(needs("GetStatistic")) },
    { "PVPLOGTOOL", "IGUI_AdminPanel_PVPLogTool", "sym:Gun", mpOnly(needs("PVPLogTool")) },
    { "ZONE_EDITOR", "IGUI_AdminPanel_ZoneEditor", "item:Base.Map", mpOnly(needsAny("CanSetupSafehouses", "CanSetupNonPVPZone")) },
}

for _, window in ipairs(WINDOWS) do
    local internal = window[1]
    register({
        id = "window:" .. internal,
        category = "windows",
        title = getText(window[2]),
        icon = window[3],
        available = window[4],
        run = function(ctx) openAdminWindow(internal) end,
    })
end

register({
    id = "window:DEBUG",
    category = "windows",
    title = getText("IGUI_DebugMenu"),
    icon = "tex:media/ui/Debug_Icon_Off.png",
    available = function(admin)
        if getCore():getDebug() then return true end
        return false, txt("NeedsDebug")
    end,
    run = function(ctx)
        if ISDebugMenu.instance then
            ISDebugMenu.instance:close()
        else
            ISDebugMenu.OnOpenPanel()
        end
    end,
})

-- 14. Debug-menu tools ------------------------------------------------------------------------------------------------

register({
    id = "debug.playerModel",
    category = "debug",
    title = txt("HideMyCharacter"),
    tooltip = txt("HideMyCharacterTooltip"),
    icon = "sym:FaceSad",
    available = needs("UseDebugContextMenu"),
    toggle = {
        isOn = function(ctx) return not getCore():isDisplayPlayerModel() end,
        set = function(ctx, on)
            if on == nil then on = getCore():isDisplayPlayerModel() end
            getCore():setDisplayPlayerModel(not on)
        end,
    },
})

register({
    id = "debug.cursor",
    category = "debug",
    title = txt("HideCursor"),
    tooltip = txt("HideCursorTooltip"),
    icon = "sym:Triangle",
    available = needs("UseDebugContextMenu"),
    toggle = {
        isOn = function(ctx) return not getCore():isDisplayCursor() end,
        set = function(ctx, on)
            if on == nil then on = getCore():isDisplayCursor() end
            getCore():setDisplayCursor(not on)
            Mouse.setCursorVisible(getCore():isDisplayCursor())
        end,
    },
})

register({
    id = "debug.spawnPoints",
    category = "debug",
    title = getText("IGUI_DebugContext_SpawnPoints"),
    icon = "sym:Target",
    available = needs("UseDebugContextMenu"),
    run = function(ctx) DebugContextMenu.onSpawnPoints(ctx.admin:getCurrentSquare(), ctx.admin) end,
})

register({
    id = "debug.tilePicker",
    category = "debug",
    title = getText("IGUI_DebugContext_TilePicker"),
    icon = "sym:Skyscraper",
    available = needs("UseDebugContextMenu"),
    run = function(ctx) DebugContextMenu.onTilesPicker(ctx.admin) end,
})

register({
    id = "debug.filming",
    category = "debug",
    title = getText("IGUI_DebugContext_FilmingTools"),
    icon = "sym:VHS",
    available = needs("UseDebugContextMenu"),
    run = function(ctx) DebugContextMenu.onFilmingToolsUI(ctx.admin) end,
})

-- 15. Custom command -----------------------------------------------------------------------------------------------------

--- Fill {me}, {player}, {x}, {y}, {z}; ask for a player or a square only when the
-- text uses them.
local function runCustom(ctx)
    local text = ctx.values.command or ""
    if string.sub(text, 1, 1) ~= "/" then text = "/" .. text end

    -- A replacement string treats "%" as special.
    local function plain(value)
        return (string.gsub(tostring(value), "%%", "%%%%"))
    end

    local function finish(player, location)
        local out = string.gsub(text, "{me}", plain(ctx.admin:getUsername()))
        if player then out = string.gsub(out, "{player}", plain(player)) end
        if location then
            out = string.gsub(out, "{x}", int(location.x))
            out = string.gsub(out, "{y}", int(location.y))
            out = string.gsub(out, "{z}", int(location.z))
        end
        cmd(out)
    end

    local function withLocation(player)
        if string.find(text, "{x}", 1, true) or string.find(text, "{y}", 1, true) or string.find(text, "{z}", 1, true) then
            Hotbar.pickSquare(ctx.admin, function(square)
                finish(player, { x = square:getX(), y = square:getY(), z = square:getZ() })
            end)
        else
            finish(player, nil)
        end
    end

    if string.find(text, "{player}", 1, true) and not ctx.values.player then
        Hotbar.pickPlayer(ctx.admin, withLocation)
    else
        withLocation(ctx.values.player)
    end
end

register({
    id = "custom.command",
    category = "custom",
    title = function(slot)
        local text = slot and slot.settings and slot.settings.command
        return text or txt("CustomCommand")
    end,
    tooltip = txt("CustomCommandTooltip"),
    icon = "sym:Asterisk",
    params = {
        textParam("command", txt("ParamCommand"), false, txt("CommandHint")),
        playerParam("@ask", true),
    },
    available = mpOnly(),
    run = runCustom,
})
