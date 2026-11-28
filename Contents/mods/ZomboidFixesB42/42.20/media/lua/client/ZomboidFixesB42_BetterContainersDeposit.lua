--[[
    Zomboid Fixes B42.20 -- client, Better Containers' Smart Deposit no longer freezes the game

    Better Containers (workshop 3586216562, mod id EURY_CONTAINERS, BetterContainers/Proximity/Proximity_SmartDeposit.lua)
    lets items be dropped on its Proximity view (container type "proximityInv", or its corpse view in corpse mode): each
    item goes to a nearby container that already holds that type, else one that holds that category, else any with room.
    It works the plan out in getSmartDepositPlan, and for every dropped item it scans every item of every nearby
    container, twice over (containerHasFullType, then containerHasCategory, which calls InventoryCategory.get per item):

        for each dragged item, for each container: for each item in it: compare full type   (then category)

    That is dragged items x nearby items of Lua work. It runs on the drop (transferItemsByWeight), in both canPutIn, and
    in its ISInventoryPaneDraggedItems:update wrapper, which runs on every frame of a drag over the Proximity view
    (ISInventoryPane renderdetails calls draggedItems:update each frame while dragging; vanilla's own update returns early
    when nothing changed, the wrapper's plan does not). With a big stack dragged next to full crates one plan took 13 to
    22 seconds (pzopt profile, 2026-11-28: 95% of the game thread inside getSmartDepositPlan, single frames of 22 s).

    The plan here is the same one, step for step, with each nearby container's full types and categories indexed once per
    plan (the items being moved left out, as theirs are), so each dragged item costs one lookup per container. The drag's
    answer is kept for the rest of that drag over that view. Better Containers' locals cannot be reached, so its four
    wrappers are wrapped again at OnGameStart: for a Smart Deposit target they run this instead, anything else goes to
    them as before. Its dragged-items wrapper calls vanilla's update first and only then plans; ISMouseDrag.dragging is
    cleared for that call (vanilla's update only reads it to fill self.items, filled here first), which makes the plan
    return at its first line, and the same clearing of itemNotOK follows here. Does nothing without Better Containers.
--]]

local Proximity, Options, InventoryCategory = nil, nil, nil
local installed = false

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.BetterContainersSmartDeposit == true
end

-- Better Containers' own rules, copied: what counts as a target and as a real storage container.
local SKIP_CONTAINER_TYPES = {
    floor = true, ["local"] = true, localContainer = true, localInventory = true,
    stove = true, microwave = true, oven = true, washingmachine = true, dryer = true,
    clothingwasher = true, clothingdryer = true, combinationwasherdryer = true,
}

local function getContainerType(container)
    if not (container and container.getType) then return nil end
    local value = container:getType()
    if value then return tostring(value) end
    return nil
end

local function isCorpseContainerType(containerType)
    return containerType == "inventorymale" or containerType == "inventoryfemale"
end

local function isCorpseMode()
    local eff = Options.getEffectivePermissions() or {}
    return eff.corpseOnly == true
end

local function isTarget(container)
    local containerType = getContainerType(container)
    return containerType == Proximity.invName
        or (containerType == Proximity.invName_corpses and isCorpseMode())
end

local function getItemFullType(item)
    if not (item and item.getFullType) then return nil end
    local value = item:getFullType()
    if value and value ~= "" then return tostring(value) end
    return nil
end

local function getItemCategory(item)
    if not item then return nil end
    local value = InventoryCategory.get(item)
    if value and value ~= "" then return tostring(value) end
    return nil
end

local function getItemWeight(item)
    if not item then return 0 end
    if item.getUnequippedWeight then
        local value = item:getUnequippedWeight()
        if type(value) == "number" then return value end
    end
    if item.getActualWeight then
        local value = item:getActualWeight()
        if type(value) == "number" then return value end
    end
    return 0
end

local function isLockedForPlayer(container, playerObj)
    local parent = container and container.getParent and container:getParent() or nil
    if not (parent and playerObj) then return false end
    if instanceof(parent, "IsoThumpable") and parent.isLockedToCharacter then
        return parent:isLockedToCharacter(playerObj) == true
    end
    return false
end

local function isRealStorage(container, playerObj)
    local containerType = getContainerType(container)
    if not containerType then return false end
    if containerType == Proximity.invName or containerType == Proximity.invName_corpses then return false end
    if SKIP_CONTAINER_TYPES[containerType] then return false end
    if isCorpseContainerType(containerType) and not isCorpseMode() then return false end
    if isLockedForPlayer(container, playerObj) then return false end
    return true
end

local function collectNearbyStorage(playerNum, playerObj)
    local containers, known = {}, {}
    local page = getPlayerLoot and getPlayerLoot(playerNum) or nil
    if not (page and page.backpacks) then return containers end
    for i = 1, #page.backpacks do
        local container = page.backpacks[i] and page.backpacks[i].inventory or nil
        if container and not known[container] and isRealStorage(container, playerObj) then
            known[container] = true
            containers[#containers + 1] = container
        end
    end
    return containers
end

--- The full types and categories a container holds, the items being moved left out. Built once per plan.
local function indexOf(container, movingItems, indexes)
    local index = indexes[container]
    if index then return index end
    index = { types = {}, categories = {} }
    local items = container:getItems()
    if items then
        for i = 0, items:size() - 1 do
            local other = items:get(i)
            if other and not movingItems[other] then
                local fullType = getItemFullType(other)
                if fullType then index.types[fullType] = true end
                local category = getItemCategory(other)
                if category then index.categories[category] = true end
            end
        end
    end
    indexes[container] = index
    return index
end

local function hasRoomForPlannedItem(container, playerObj, item, reservedWeight)
    if not (container and item) then return false end
    if not container.isItemAllowed or not container:isItemAllowed(item) then return false end
    if container.isInside and container:isInside(item) then return false end
    reservedWeight = reservedWeight or 0
    if reservedWeight <= 0 then
        return container:hasRoomFor(playerObj, item) == true
    end
    local plannedWeight = reservedWeight + getItemWeight(item)
    return container:hasRoomFor(playerObj, plannedWeight, plannedWeight) == true
end

local function isMovableDepositItem(item, targetContainer, playerObj)
    if not (item and targetContainer and playerObj and item.getContainer and item:getContainer()) then return false end
    if item.isFavorite and item:isFavorite() and not targetContainer:isInCharacterInventory(playerObj) then return false end
    if targetContainer.isInside and targetContainer:isInside(item) then return false end
    if item.getContainer and item:getContainer() == targetContainer then return false end
    return true
end

local function findDestination(item, containers, playerObj, movingItems, reservedWeights, indexes)
    local fullType = getItemFullType(item)
    local category = getItemCategory(item)
    if fullType then
        for _, container in ipairs(containers) do
            if hasRoomForPlannedItem(container, playerObj, item, reservedWeights[container])
                and indexOf(container, movingItems, indexes).types[fullType]
            then
                return container
            end
        end
    end
    if category then
        for _, container in ipairs(containers) do
            if hasRoomForPlannedItem(container, playerObj, item, reservedWeights[container])
                and indexOf(container, movingItems, indexes).categories[category]
            then
                return container
            end
        end
    end
    for _, container in ipairs(containers) do
        if hasRoomForPlannedItem(container, playerObj, item, reservedWeights[container]) then
            return container
        end
    end
    return nil
end

local function getSmartDepositPlan(playerNum, playerObj, items, targetContainer)
    local containers = collectNearbyStorage(playerNum, playerObj)
    if #containers == 0 then return nil end
    local movingItems = {}
    for _, item in ipairs(items or {}) do
        if item then movingItems[item] = true end
    end
    local reservedWeights, destinationOrder, groupedItems, indexes = {}, {}, {}, {}
    for _, item in ipairs(items or {}) do
        if isMovableDepositItem(item, targetContainer, playerObj) then
            local origin = item:getContainer()
            local destination = findDestination(item, containers, playerObj, movingItems, reservedWeights, indexes)
            if destination and destination ~= origin then
                if not groupedItems[destination] then
                    groupedItems[destination] = {}
                    destinationOrder[#destinationOrder + 1] = destination
                end
                local group = groupedItems[destination]
                group[#group + 1] = item
                reservedWeights[destination] = (reservedWeights[destination] or 0) + getItemWeight(item)
            end
        end
    end
    if #destinationOrder == 0 then return nil end
    return { destinationOrder = destinationOrder, groupedItems = groupedItems }
end

-- The answer for the drag under way: same dragged list, same target, same player.
local memo = { items = nil, target = nil, playerNum = nil, result = false }

local function hasDestination(playerNum, playerObj, targetContainer, draggedList)
    if not (ISMouseDrag and ISMouseDrag.dragging) then return false end
    if draggedList and memo.items == draggedList and memo.target == targetContainer and memo.playerNum == playerNum then
        return memo.result
    end
    local dragging = draggedList or ISInventoryPane.getActualItems(ISMouseDrag.dragging)
    local result = getSmartDepositPlan(playerNum, playerObj, dragging, targetContainer) ~= nil
    if draggedList then
        memo.items, memo.target, memo.playerNum, memo.result = draggedList, targetContainer, playerNum, result
    end
    return result
end

local function queueWalkNearContainer(container, playerObj)
    if not (container and playerObj) then return false end
    if container:getType() == "floor" then return true end
    if container.isInCharacterInventory and container:isInCharacterInventory(playerObj) then return true end
    local parent = container.getParent and container:getParent() or nil
    if not (parent and parent.getSquare and parent:getSquare()) then return true end
    local playerSquare = playerObj:getCurrentSquare()
    if not playerSquare then return false end
    if instanceof(parent, "IsoDeadBody") then return true end
    if instanceof(parent, "BaseVehicle") then
        if playerObj:getVehicle() == parent then return true end
        local part = container.getVehiclePart and container:getVehiclePart() or nil
        if part and part.getArea and part:getArea() then
            if part:getVehicle():canAccessContainer(part:getIndex(), playerObj) then return true end
            if ISPathFindAction and ISPathFindAction.pathToVehicleArea then
                ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(playerObj, part:getVehicle(), part:getArea()))
                return true
            end
        end
        return false
    end
    if parent:getSquare():DistToProper(playerSquare) < 2 then return true end
    local adjacent = AdjacentFreeTileFinder and AdjacentFreeTileFinder.Find(parent:getSquare(), playerObj) or nil
    if not adjacent then return false end
    if adjacent ~= playerSquare then
        ISTimedActionQueue.add(ISWalkToTimedAction:new(playerObj, adjacent))
    end
    return true
end

local function runSmartDeposit(pane, items, targetContainer)
    if not (pane and items and targetContainer) then return end
    local playerNum = pane.player or 0
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    if pane.sortItemsByTypeAndWeight then pane:sortItemsByTypeAndWeight(items) end
    local plan = getSmartDepositPlan(playerNum, playerObj, items, targetContainer)
    if not plan then return end
    for _, destination in ipairs(plan.destinationOrder) do
        if queueWalkNearContainer(destination, playerObj) then
            for _, item in ipairs(plan.groupedItems[destination]) do
                local origin = item and item.getContainer and item:getContainer() or nil
                if origin and origin ~= destination then
                    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(playerObj, item, origin, destination))
                end
            end
        end
    end
end

local function install()
    local Pane, Page, Dragged = ISInventoryPane, ISInventoryPage, ISInventoryPaneDraggedItems

    local prevTransfer = Pane.transferItemsByWeight
    function Pane:transferItemsByWeight(items, container, ...)
        if isEnabled() and isTarget(container) then
            runSmartDeposit(self, items, container)
            return
        end
        return prevTransfer(self, items, container, ...)
    end

    local prevPaneCanPutIn = Pane.canPutIn
    function Pane:canPutIn(...)
        if isEnabled() and isTarget(self.inventory) then
            return hasDestination(self.player, getSpecificPlayer(self.player), self.inventory, nil)
        end
        return prevPaneCanPutIn(self, ...)
    end

    local prevPageCanPutIn = Page.canPutIn
    function Page:canPutIn(...)
        local target = self.mouseOverButton and self.mouseOverButton.inventory or nil
        if isEnabled() and isTarget(target) then
            return hasDestination(self.player, getSpecificPlayer(self.player), target, nil)
        end
        return prevPageCanPutIn(self, ...)
    end

    local prevUpdate = Dragged and Dragged.update
    if type(prevUpdate) ~= "function" then return end
    function Dragged:update(...)
        if not isEnabled() then return prevUpdate(self, ...) end
        self.playerNum = self.inventoryPane.player
        if not isTarget(self:getDropContainer()) or not ISMouseDrag.dragging then return prevUpdate(self, ...) end
        if not self.items then
            self.items = ISInventoryPane.getActualItems(ISMouseDrag.dragging)
            self.inventoryPane:sortItemsByTypeAndWeight(self.items)
        end
        local dragging = ISMouseDrag.dragging
        ISMouseDrag.dragging = nil
        local ok, err = pcall(prevUpdate, self, ...)
        ISMouseDrag.dragging = dragging
        if not ok then error(err) end

        local target = self.mouseOverContainer
        if not (isTarget(target) and self.items and self.itemNotOK) then return end
        local playerNum = self.inventoryPane and self.inventoryPane.player or self.playerNum or 0
        local playerObj = getSpecificPlayer(playerNum)
        if not hasDestination(playerNum, playerObj, target, self.items) then return end
        for _, item in ipairs(self.items) do
            if item and isMovableDepositItem(item, target, playerObj) then
                self.itemNotOK[item] = nil
            end
        end
    end
end

local function onGameStart()
    if installed then return end
    local ok, deposit = pcall(require, "BetterContainers/Proximity/Proximity_SmartDeposit")
    if not ok or type(deposit) ~= "table" or not deposit._installed then return end
    local okP, prox = pcall(require, "BetterContainers/Proximity")
    local okO, opts = pcall(require, "BetterContainers/_Options")
    local okC, cats = pcall(require, "BetterContainers/Categorize/InventoryCategory")
    if not (okP and okO and okC and type(prox) == "table" and type(opts) == "table" and type(cats) == "table") then return end
    if not (prox.invName and type(opts.getEffectivePermissions) == "function" and type(cats.get) == "function") then return end
    Proximity, Options, InventoryCategory = prox, opts, cats
    installed = true
    install()
end

Events.OnGameStart.Add(onGameStart)
