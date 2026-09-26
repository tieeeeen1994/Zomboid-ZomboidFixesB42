--[[
    Zomboid Fixes B42.20 -- server, cooking keeps pace with fast forward

    Raising GameTime's multiplier speeds up the clock and everything read from it
    (rotting, which Food.updateAge works out from getWorldAgeHours), but not what
    items do over time on a server. Two things hold them to real time:

      * IsoCell.update runs ProcessItems -- every InventoryItem.update -- only once
        every 5 real seconds on a server:

            if (!client && !server || server && currentTimeMillis() - lastServerItemsUpdate > 5000)

      * InventoryItem.calculateTimeMultiplier measures each update's step in real
        milliseconds on a server, ignoring the game speed:

            timeMultiplier = getMultiplierFromTimeDelta((nowMs - lastUpdateMs) * 0.001)

    Food.update feeds that step to updateTemperature (heat moves towards the
    container's temperature by temp / 1000 or 0.001 per unit of step / 1.6), and
    cooking adds one step of heat / 1.5 minutes (x 0.05 when the container is at or
    below 1.6) per update in which the clock's minute changed. So on a server food
    heats up and cooks by the same amount every 5 real seconds whatever the speed.
    The same holds for tainted food boiled clean (1 minute per update, x 0.2).

    What the engine skips is added here. The list the engine updates is public
    (IsoCell.getProcessItems), so it is walked a slice per tick, and every Food in it
    gets:

      * heat: the extra real time the speed stands for, (speed - 1) x real seconds,
        through vanilla's own formula and clamps;
      * cooking: the steps vanilla would have made at this speed and did not. At
        normal speed an update adds min(1, a) steps, a being the game minutes one
        update spans (5.1 s of clock); at speed S it should add S x min(1, a) but adds
        min(1, S x a). The difference is added, with the heat vanilla would use.

    Two running totals grow while fast forward is on, and each item remembers how
    far it has been paid, so an item skipped or seen twice while the list shifts is
    squared up on the next pass, and an item seen for the first time only starts
    from then. Everything that follows from the new cooking time -- cooked, burnt,
    replaced by its cooked version, cooking XP, a stove fire, the sync to players --
    is left to the engine's next update, which at fast forward always sees a new
    minute.

    Water is not touched: on a server fluid containers heat and purify with far larger
    constants (InventoryItem.update: 0.06 and temp / 16 instead of 0.001 and
    temp / 1000, 0.6 litres per unit instead of 0.01), so a pot of water is hot and
    clean within an update or two at any speed.
--]]

if not isServer() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- ProcessItems runs on the first 100 ms server tick past 5000 ms.
local ENGINE_UPDATE_S = 5.1
-- Items looked at per tick. The list holds every cookable item in a loaded
-- container, which can be thousands.
local BATCH = 250

-- Running totals: extra real seconds of heating, and extra cooking steps, owed
-- since the server started.
local heatOwed = 0
local stepsOwed = 0
-- item ID -> totals already paid to it, and the sweep that last saw it.
local paidHeat, paidSteps, seenSweep = {}, {}, {}
local sweep = 0
local index = 0
-- The totals when the current sweep began, and when the last finished sweep began:
-- once a whole sweep has paid everything owed, walking stops until fast forward
-- runs again.
local startHeat, startSteps = 0, 0
local paidUpHeat, paidUpSteps = 0, 0
local lastMs = nil

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MultiplayerFastForward == true
end

--- Cooking steps vanilla owes for dt real seconds at this speed.
local function missingSteps(speed, dt)
    local gameTime = getGameTime()
    -- Game minutes per real second at normal speed: a day is getMinutesPerDay real
    -- minutes long.
    local perUpdate = 1440 / (gameTime:getMinutesPerDay() * 60) * ENGINE_UPDATE_S
    local wanted = speed * math.min(1, perUpdate)
    local made = math.min(1, speed * perUpdate)
    return dt / ENGINE_UPDATE_S * math.max(0, wanted - made)
end

local function payFood(food, heatSeconds, steps)
    local container = food:getOutermostContainer()
    if not container then return end
    local temp = container:getTemprature()
    local heat = food:getHeat()

    -- Food.updateTemperature, for the extra time.
    if heatSeconds > 0 and heat ~= temp then
        local accum = getGameTime():getMultiplierFromTimeDelta(heatSeconds) / 1.6
        if heat > temp then
            heat = heat - 0.001 * accum
            if heat < math.max(0.2, temp) then heat = math.max(0.2, temp) end
        end
        if heat < temp then
            heat = heat + temp / 1000 * accum
            if heat > math.min(3, temp) then heat = math.min(3, temp) end
        end
        food:setHeat(heat)
    end

    -- Food.update's cooking, for the missing steps.
    if steps <= 0 or heat <= 1.6 or food:isFrozen() then return end
    if food:isCookable() then
        local dt = heat / 1.5
        if temp <= 1.6 then dt = dt * 0.05 end
        food:setCookingTime(food:getCookingTime() + dt * steps)
    elseif food:isTainted() then
        local dt = 1
        if temp <= 1.6 then dt = dt * 0.2 end
        local cooking = food:getCookingTime() + dt * steps
        food:setCookingTime(cooking)
        if cooking > 10 then food:setTainted(false) end
    end
end

local function visit(item)
    local id = item:getID()
    seenSweep[id] = sweep
    local heatBefore, stepsBefore = paidHeat[id], paidSteps[id]
    paidHeat[id], paidSteps[id] = heatOwed, stepsOwed
    -- First sighting: nothing is owed for the time before it was seen.
    if heatBefore == nil then return end
    if instanceof(item, "Food") then
        payFood(item, heatOwed - heatBefore, stepsOwed - stepsBefore)
    end
end

local function endSweep()
    -- Forget items that were not seen in this sweep or the one before.
    local stale = {}
    for id, seen in pairs(seenSweep) do
        if seen < sweep - 1 then table.insert(stale, id) end
    end
    for _, id in ipairs(stale) do
        seenSweep[id], paidHeat[id], paidSteps[id] = nil, nil, nil
    end
    sweep = sweep + 1
    index = 0
    paidUpHeat, paidUpSteps = startHeat, startSteps
end

local function onTick()
    if not isEnabled() then return end
    local now = getTimestampMs()
    local speed = ZomboidFixesB42.fastForwardSpeed or 1
    if lastMs and speed > 1 then
        local dt = math.min(now - lastMs, 1000) / 1000
        heatOwed = heatOwed + (speed - 1) * dt
        stepsOwed = stepsOwed + missingSteps(speed, dt)
    end
    lastMs = now

    if index == 0 then
        -- The last full sweep paid everything owed: rest.
        if heatOwed == paidUpHeat and stepsOwed == paidUpSteps then return end
        startHeat, startSteps = heatOwed, stepsOwed
    end

    local items = getCell():getProcessItems()
    local size = items:size()
    local last = math.min(size, index + BATCH)
    for i = index, last - 1 do
        local item = items:get(i)
        if item then visit(item) end
    end
    index = last
    if index >= size then endSweep() end
end

Events.OnTick.Add(onTick)
