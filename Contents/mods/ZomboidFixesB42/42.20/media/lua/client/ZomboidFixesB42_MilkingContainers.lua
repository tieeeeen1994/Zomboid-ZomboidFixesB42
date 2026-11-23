--[[
    Zomboid Fixes B42.20 -- client, the animal's Milk submenu lists only containers with
    room, with readable litres

    AnimalContextMenu.doMenu (client/ISUI/Animal/ISAnimalContextMenu.lua, 42.22.2 ~202)
    fills the Milk submenu from playerInv:getAvailableFluidContainer(milkType), one entry
    per container type and amount. That Java test (InventoryItem.isAvailableFluidContainer)
    also passes containers already full of that milk and ones whose whitelist refuses it,
    so "Sheep's Milk (Carton) (1/1L)" is offered and milking into it stops at once. Each
    entry's text is `round(amount, 2) .. "/" .. fc:getCapacity() .. "L"`: the capacity is a
    Java float concatenated as a double, so a 0.2 L bottle reads "0.20000000298023224L"
    (the item tooltip formats it itself, which is why it looks right there).

    After doMenu this walks the menu it filled and, in every submenu, for each option that
    runs AnimalContextMenu.onMilkAnimal with a container (param2): removes it when the
    container is full or refuses this animal's milk, else rewrites its text with both
    numbers rounded to two decimals. The "All" entry (no container) is removed when one or
    no container is left (vanilla shows it only for two or more), and the Milk option
    itself when none is left (vanilla shows none without a container). The milking step
    that moves on to the next container is shared/ZomboidFixesB42_MilkingContainers.lua.
    Option MilkingContainers.
--]]

require "ISUI/Animal/ISAnimalContextMenu"

-- Set by the shared file of the same name (shared Lua loads before client Lua).
local MilkingContainers = ZomboidFixesB42 and ZomboidFixesB42.MilkingContainers

if not MilkingContainers or not AnimalContextMenu or not AnimalContextMenu.doMenu then
    print("[ZomboidFixesB42] MilkingContainers: AnimalContextMenu.doMenu not found, menu fix not applied")
    return
end

local function litres(v)
    local s = string.format("%.2f", v)
    s = string.gsub(s, "0+$", "")
    s = string.gsub(s, "%.$", "")
    return s
end

local function containerText(bucket)
    local fc = bucket:getFluidContainer()
    local text = bucket:getDisplayName()
    if fc:getPrimaryFluid() then
        text = fc:getUiName()
    end
    if not fc:isEmpty() then
        text = text .. " (" .. litres(fc:getAmount()) .. "/" .. litres(fc:getCapacity()) .. "L)"
    end
    return text
end

local function removeAt(menu, index)
    table.insert(menu.optionPool, menu.options[index])
    for i = index + 1, #menu.options do
        menu.options[i - 1] = menu.options[i]
        menu.options[i - 1].id = i - 1
    end
    menu.options[#menu.options] = nil
    menu.numOptions = menu.numOptions - 1
end

local function relayout(menu)
    menu:calcHeight()
    menu:setWidth(menu:calcWidth())
end

--- Cleans one Milk submenu. Returns how many container entries are left.
local function cleanMilkMenu(sub, onMilk, animal)
    local data = animal and animal:getData()
    local breed = data and data:getBreed()
    local milkType = breed and breed:getMilkType()
    if not milkType then return nil end

    local left = 0
    local allIndex = nil
    local i = 1
    while i <= #sub.options do
        local opt = sub.options[i]
        local removed = false
        if opt.onSelect == onMilk then
            local bucket = opt.param2
            if bucket ~= nil then
                if MilkingContainers.usable(bucket, milkType) then
                    opt.name = containerText(bucket)
                    left = left + 1
                else
                    removeAt(sub, i)
                    removed = true
                end
            else
                allIndex = i
            end
        end
        if not removed then i = i + 1 end
    end
    if allIndex and left <= 1 then
        removeAt(sub, allIndex)
    end
    relayout(sub)
    return left
end

local function walk(menu, onMilk, seen)
    if not menu or seen[menu] then return end
    seen[menu] = true
    local i = 1
    while i <= #menu.options do
        local opt = menu.options[i]
        local removed = false
        if opt.subOption then
            local sub = menu:getSubMenu(opt.subOption)
            if sub and not seen[sub] then
                local first = sub.options[1]
                if first and first.onSelect == onMilk then
                    seen[sub] = true
                    local left = cleanMilkMenu(sub, onMilk, first.target)
                    if left == 0 then
                        removeAt(menu, i)
                        relayout(menu)
                        removed = true
                    end
                else
                    walk(sub, onMilk, seen)
                end
            end
        end
        if not removed then i = i + 1 end
    end
end

local vanillaDoMenu = AnimalContextMenu.doMenu

AnimalContextMenu.doMenu = function(player, context, animal, test, ...)
    local onMilk = AnimalContextMenu.onMilkAnimal
    local result = vanillaDoMenu(player, context, animal, test, ...)
    if MilkingContainers.isEnabled() and not test and context and context.options then
        local ok, err = pcall(walk, context, onMilk, {})
        if not ok then
            print("[ZomboidFixesB42] MilkingContainers: menu clean-up failed: " .. tostring(err))
        end
    end
    return result
end
