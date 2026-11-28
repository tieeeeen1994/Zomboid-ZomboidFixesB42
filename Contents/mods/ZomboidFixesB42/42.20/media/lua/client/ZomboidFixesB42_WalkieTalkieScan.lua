--[[
    Zomboid Fixes B42.20 -- client, Better Walkie Talkies stops checking the whole inventory every tick

    Better Walkie Talkies (workshop 3779480293, BetterWalkieTalkies/InventoryRadioReception.lua) keeps carried two-way
    radios receiving: a radio found in the main inventory gets its power state applied again (which makes vanilla
    register its roaming channel), and a radio that vanilla switches off on unequip is switched back on if it was on in
    the hand. To notice those moments it walks every item of every local player's main inventory on every OnTick and
    asks each one instanceof(item, "Radio"), plus its device data for radios. With a few thousand items carried that is
    12% of the game thread (pzopt profile, 2026-11-28), all of it spent finding the same few radios again.

    Here the same per-radio steps run every tick for the radios already found, and the whole inventory is only walked
    when its item count changes (a radio coming in always changes it) and once a second (an item swapped for a radio
    within one tick). A tracked radio that is no longer in the main inventory is dropped on that tick, as the original's
    walk does. The module's own OnTick handler is taken out at OnGameStart and called instead while the option is off;
    each keeps its own state. Does nothing without Better Walkie Talkies.
--]]

local RESCAN_MS = 1000
local UNEQUIP_RESTORE_GUARD_MS = 1000

local module = nil
local trackedByPlayer = {}
local scanByPlayer = {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.BetterWalkieTalkiesScan == true
end

local function isPortableRadio(item)
    if not item or not instanceof(item, "Radio") then return false end
    local device = item:getDeviceData()
    return device and device:getIsPortable() and device:getIsTwoWay()
end

local function refreshReception(device)
    if device and device:getIsTurnedOn() then
        device:setIsTurnedOn(true)
    end
end

-- The original's per-radio step, unchanged but for its debug lines.
local function updateRadio(tracked, radio, equippedRadio)
    local device = radio:getDeviceData()
    local state = tracked[radio]
    if not state then
        state = {
            equipped = radio == equippedRadio,
            poweredWhileEquipped = radio == equippedRadio and device:getIsTurnedOn() or false,
            lastObservedOn = device:getIsTurnedOn(),
            restoreUntilMs = 0,
        }
        tracked[radio] = state
        if radio ~= equippedRadio then
            refreshReception(device)
        end
    end
    if radio == equippedRadio then
        state.equipped = true
        state.poweredWhileEquipped = device:getIsTurnedOn()
        state.restoreUntilMs = 0
    elseif state.equipped then
        state.equipped = false
        state.restoreUntilMs = state.poweredWhileEquipped and (getTimeInMillis() + UNEQUIP_RESTORE_GUARD_MS) or 0
        if state.poweredWhileEquipped and not device:getIsTurnedOn() then
            device:setIsTurnedOn(true)
        end
        refreshReception(device)
    elseif state.poweredWhileEquipped
        and state.restoreUntilMs > 0
        and getTimeInMillis() <= state.restoreUntilMs
        and not device:getIsTurnedOn()
        and device:getPower() > 0
    then
        device:setIsTurnedOn(true)
        refreshReception(device)
    end
    state.lastObservedOn = device:getIsTurnedOn()
end

local function updatePlayer(playerIndex, player)
    local tracked = trackedByPlayer[playerIndex] or {}
    trackedByPlayer[playerIndex] = tracked
    local scan = scanByPlayer[playerIndex] or { size = -1, at = 0 }
    scanByPlayer[playerIndex] = scan

    local equippedRadio = player:getEquipedRadio()
    local inventory = player:getInventory()
    local items = inventory:getItems()
    local size = items:size()
    local now = getTimestampMs()

    if size ~= scan.size or now - scan.at >= RESCAN_MS then
        scan.size, scan.at = size, now
        local present = {}
        for index = 0, size - 1 do
            local radio = items:get(index)
            if isPortableRadio(radio) then
                present[radio] = true
                updateRadio(tracked, radio, equippedRadio)
            end
        end
        for radio in pairs(tracked) do
            if not present[radio] then tracked[radio] = nil end
        end
        return
    end

    for radio in pairs(tracked) do
        if radio:getContainer() == inventory then
            updateRadio(tracked, radio, equippedRadio)
        else
            tracked[radio] = nil
        end
    end
end

local function onTick()
    if not isEnabled() then return module.onTick() end
    for playerIndex = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(playerIndex)
        if player then updatePlayer(playerIndex, player) end
    end
end

local function reset()
    trackedByPlayer = {}
    scanByPlayer = {}
end

local function onGameStart()
    local ok, found = pcall(require, "BetterWalkieTalkies/InventoryRadioReception")
    if not ok or type(found) ~= "table" or type(found.onTick) ~= "function" then return end
    module = found
    Events.OnTick.Remove(module.onTick)
    Events.OnTick.Remove(onTick)
    Events.OnTick.Add(onTick)
end

Events.OnGameStart.Add(onGameStart)
Events.OnDisconnect.Add(reset)
Events.OnMainMenuEnter.Add(reset)
