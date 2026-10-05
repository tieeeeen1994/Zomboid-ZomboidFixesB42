--[[
    Zomboid Fixes B42.20 -- shared, adding fuel to a generator takes as long as the
    fuel that goes in

    ISAddFuel (shared/TimedActions, 42.21) times the action from the whole can:
    getDuration = 70 + fluidCont:getAmount() * 50. But complete() only pours what
    fits, min(can, generator:getMaxFuel() - getFuel()), and leaves the rest in the
    can. So topping up a nearly full generator from a full can takes as long as
    filling an empty one. (The callers' maxTime argument, 70 + amount * 40 in
    ISWorldObjectContextMenu, is ignored by new().) This times it from the amount
    that actually goes in, with the same 70 + litres * 50.

    getDuration runs on the client (new) and again on the server, where NetTimedAction
    takes adjustMaxTime(getDuration()) * 20 ms as the action's real length; the
    server's table is ISAddFuel.new(character, generator, petrol), so both sides have
    the generator and the can's fluid container.

    The other half of the old report, a generator picked up giving no item
    (ISTakeGenerator:complete, instanceItem nil), cannot happen in 42.21:
    IsoGenerator.getGeneratorItemType maps the sprite to a generator-tagged item and
    falls back to Base.Generator, which exists.
--]]

require "TimedActions/ISAddFuel"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.GeneratorRefuelTime == true
end

local vanillaGetDuration = ISAddFuel.getDuration

function ISAddFuel:getDuration()
    if not isEnabled() or self.character:isTimedActionInstant() then
        return vanillaGetDuration(self)
    end
    local can = self.fluidCont and self.fluidCont:getAmount() or 0
    local room = 0
    if self.generator then
        room = math.max(0, self.generator:getMaxFuel() - self.generator:getFuel())
    end
    return 70 + math.min(can, room) * 50
end
