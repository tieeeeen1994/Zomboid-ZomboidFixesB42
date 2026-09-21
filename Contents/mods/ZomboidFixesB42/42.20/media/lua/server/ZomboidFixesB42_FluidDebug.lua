--[[
    Zomboid Fixes B42.20 -- server, debug "Add Fluid" on world objects

    Fills a world object's fluid container to capacity and replicates it. See the
    client file for why vanilla's own command for this empties the container and
    never tells anyone.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function onAddFluidDebug(player, args)
    local role = player and player:getRole()
    if not role or not role:hasCapability(Capability.UseDebugContextMenu) then
        print("ZomboidFixesB42.addFluidDebug The player's access level is not sufficient to perform this action")
        return
    end

    local square = getCell():getGridSquare(tonumber(args.x), tonumber(args.y), tonumber(args.z))
    if not square then return end

    local objects = square:getObjects()
    local index = tonumber(args.index) or -1
    if index < 0 or index >= objects:size() then return end

    local isoObject = objects:get(index)
    if not isoObject or instanceof(isoObject, "IsoFeedingTrough") then return end

    local fluidContainer = isoObject:getFluidContainer()
    if not fluidContainer then return end

    -- Resolved here rather than handed to addFluid(String, float), which quietly
    -- does nothing for an unknown name -- after the container has been emptied.
    local fluid = type(args.fluid) == "string" and Fluid.Get(args.fluid) or nil
    if not fluid then return end

    -- Same as vanilla's single player branch.
    fluidContainer:removeFluid()
    fluidContainer:addFluid(fluid, fluidContainer:getCapacity())

    isoObject:sendSyncEntity(nil)
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_FLUID_DEBUG then return end
    onAddFluidDebug(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
