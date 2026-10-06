--[[
    Zomboid Fixes B42.20 -- server, debug "Remove Egg" on a hutch nest box

    Takes a random egg out of a nest box and gives it to the admin, like vanilla's
    Commands.animal.removeEggFromNestBox, but sends the egg to the admin's client
    (sendAddItemToContainer, as ISHutchGrabEgg does) and checks the hutch, the nest
    box and its eggs first. See the client file for what vanilla's command misses.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.HutchRemoveEggCheat == true
end

local function onRemoveEgg(player, args)
    if not player or not isEnabled() then return end

    -- The capability vanilla puts on every Commands.animal.* handler.
    local role = player:getRole()
    if not role or not role:hasCapability(Capability.AnimalCheats) then
        print("ZomboidFixesB42.hutchRemoveEgg The player's access level is not sufficient to perform this action")
        return
    end

    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    local index = tonumber(args.nestIdx)
    if not x or not y or not z or not index then return end

    local hutch = getHutch(x, y, z)
    if not hutch then return end

    -- Nest boxes are numbered 0 to getMaxNestBox(), both ends included.
    index = math.floor(index)
    if index < 0 or index > hutch:getMaxNestBox() then return end

    local nestBox = hutch:getNestBox(index)
    local count = nestBox and nestBox:getEggsNb() or 0
    if count <= 0 then return end

    local egg = nestBox:removeEgg(ZombRand(count))
    hutch:sync()
    if not egg then return end

    local inventory = player:getInventory()
    inventory:AddItem(egg)
    sendAddItemToContainer(inventory, egg)

    print("[ZomboidFixesB42] " .. tostring(player:getUsername()) .. " took an egg (" .. tostring(egg:getFullType())
        .. ") from nest box " .. string.format("%d", index) .. " of the hutch at "
        .. string.format("%d,%d,%d", x, y, z) .. " with the Remove Egg cheat")
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_HUTCH_REMOVE_EGG then return end
    onRemoveEgg(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
