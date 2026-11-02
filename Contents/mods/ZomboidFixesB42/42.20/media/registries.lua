--[[
    Zomboid Fixes B42.20 -- registries

    Run by the game (ModRegistries.init, 42.21) for every active mod, after
    RegistryReset.resetAll has dropped every registration outside the base
    namespace and before the item scripts load, at start-up and on every Lua reset
    (joining a server, leaving a game). Item scripts and DoParam resolve a body
    location name through this registry, so a mod location must exist here first.

    zomboidfixesb42:suspenders and zomboidfixesb42:chestrig: the ALICE belts' and
    the chest rigs' own slots (lua/shared/ZomboidFixesB42_WebbingSlots.lua).
    Registered whatever the sandbox option says, so an item saved as worn there
    still loads as worn when the option is off.
--]]

local function register(id)
    if ItemBodyLocation.get(ResourceLocation.of(id)) then return end
    ItemBodyLocation.register(id)
end

register("zomboidfixesb42:suspenders")
register("zomboidfixesb42:chestrig")
