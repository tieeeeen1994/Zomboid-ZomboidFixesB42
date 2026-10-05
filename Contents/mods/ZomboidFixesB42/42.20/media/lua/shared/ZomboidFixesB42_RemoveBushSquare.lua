--[[
    Zomboid Fixes B42.20 -- shared, removing a bush clears every bush on the square
    without an error

    ISRemoveBush:complete (shared/TimedActions/ISRemoveBush.lua, 42.21; the same
    code as the old server command object.removeBush, which nothing sends any more)
    walks the square's objects forwards and removes each one that has the canBeCut
    flag:

        for i=0,sq:getObjects():size()-1 do
            ... sq:transmitRemoveItemFromSquare(object) ...
            i = i - 1; -- FIXME: illegal in Lua

    The removal is immediate (IsoGridSquare.transmitRemoveItemFromSquare:
    RemoveTileObject, or GameServer.RemoveItemFromMap on a server), and assigning to
    a numeric for's variable changes nothing, so the object that slides into the
    freed slot is skipped, and the loop's end was fixed before the removal: when the
    bush is not the last object on its square, getObjects():get(i) runs past the end
    and throws. The bush is gone by then, but complete() errors (a server sends a
    Reject for it), and a second bush on the same square stays.

    So the bush branch is done here walking backwards, with vanilla's own drops
    unchanged: a branch half the time, and twigs every time (ZombRand(1) is always 0;
    left as it is, since nothing says what was meant). The bare-handed back strain at
    the top of vanilla's complete is repeated here, and wall vines go to vanilla.
--]]

require "TimedActions/ISRemoveBush"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.RemoveBushWholeSquare == true
end

local vanillaComplete = ISRemoveBush.complete

function ISRemoveBush:complete()
    local sq = self.square
    if not isEnabled() or self.wallVine or not sq then
        return vanillaComplete(self)
    end

    if not self.weapon then
        local skill = self.character:getPerkLevel(Perks.Farming)
        self.character:addBackMuscleStrain(1 - (skill * 0.05))
    end

    local objects = sq:getObjects()
    for i = objects:size() - 1, 0, -1 do
        -- A multi-square object can take more than one entry with it.
        if i < objects:size() then
            local object = objects:get(i)
            if object and object:getProperties():has(IsoFlagType.canBeCut) then
                sq:transmitRemoveItemFromSquare(object)
                if ZombRand(2) == 0 then
                    sq:AddWorldInventoryItem("Base.TreeBranch2", 0, 0, 0)
                end
                if ZombRand(1) == 0 then
                    sq:AddWorldInventoryItem("Base.Twigs", 0, 0, 0)
                end
            end
        end
    end

    return true
end
