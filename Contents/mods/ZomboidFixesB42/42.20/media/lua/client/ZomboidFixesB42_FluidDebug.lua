--[[
    Zomboid Fixes B42.20 -- client, debug "Add Fluid" on world objects

    Right-clicking a world object that holds fluid -- a rain collector, a water
    barrel, anything with a FluidContainer component -- gives a debug "Add Fluid"
    submenu. That menu is built in Java (ISWorldObjectContextMenuLogic
    .doFluidContainerMenu) and calls ISWorldObjectContextMenu.addFluidDebug, which
    in multiplayer only does this:

        sendClientCommandV(playerObj, "object", "addFluidDebug", ..., "fluidTypeStr", ...)

    and the server side of it (ClientCommands.lua, Commands.object.addFluidDebug)
    is broken three ways:

        o:getFluidContainer():removeFluid()
        o:getFluidContainer():addFluid(args.fluidTypeStr)

      - FluidContainer has no one-argument addFluid. The overloads are
        (String, float), (FluidType, float) and (Fluid, float), so the fill never
        happens -- the container is emptied and left that way.
      - Nothing is sent back. A fluid container does not replicate itself; vanilla's
        own feeding trough debug commands end with isoObject:sendSyncEntity(nil),
        and this one does not, so clients keep whatever they last saw until the
        chunk reloads.
      - There is no access check at all.

    So route the request to our own server command instead, which fills the
    container properly and syncs it. Feeding troughs are left alone: vanilla sends
    them down a separate path (ISFeedingTroughMenu.onAddWaterDebug) that already
    works. Single player is left alone too, where vanilla fills the container
    directly.

    Fluid containers on items (a bucket in a crate, a bottle in a bag) come through
    ISFluidContainerMenu.addDebugFluid instead, which fills the client's copy and
    sends it with syncItemFields. SyncItemFieldsPacket carries the fluid container
    and the server loads it, so that path already works.
--]]

if not isClient() then return end

require "ISUI/ISWorldObjectContextMenu"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local vanillaAddFluidDebug = ISWorldObjectContextMenu.addFluidDebug

function ISWorldObjectContextMenu.addFluidDebug(playerObj, fluidContainer, fluid)
    local isoObject = fluidContainer and fluidContainer:getGameEntity()

    if not isClient()
            or not fluid
            or not instanceof(isoObject, "IsoObject")
            or instanceof(isoObject, "IsoFeedingTrough") then
        return vanillaAddFluidDebug(playerObj, fluidContainer, fluid)
    end

    local square = isoObject:getSquare()
    local index = isoObject:getObjectIndex()
    if not square or index < 0 then
        return vanillaAddFluidDebug(playerObj, fluidContainer, fluid)
    end

    -- The client's copy is not touched. The server's sync arrives straight after
    -- and is the only version that counts, so filling it here as well would only
    -- show water that the server may still refuse to add.
    sendClientCommand(playerObj, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_FLUID_DEBUG, {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        index = index,
        fluid = fluid:getFluidTypeString(),
    })
end
