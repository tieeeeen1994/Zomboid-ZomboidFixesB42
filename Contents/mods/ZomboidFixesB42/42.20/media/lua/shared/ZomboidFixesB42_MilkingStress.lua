--[[
    Zomboid Fixes B42.20 -- shared, a stressed animal breaks off milking only as often
    as its stress, your Animal Care and its acceptance of you say

    ISMilkAnimal:stress (shared/TimedActions/Animals, 42.22.2 ~14) runs once per litre
    milked (ISMilkAnimal:milk, from `update` in single player and from the emulated
    "update" anim event on a server, every timePerLiter x 20 ms). For an animal above
    40 stress, milked by someone at Animal Care 7 or below, it computes
        chance = stress - Animal Care x 5 - acceptance level x 5
    and then overwrites it with `chance = 120;` (a leftover), so `ZombRand(100) < chance`
    always passes: the animal always flees, the bucket's milk is spilt and the bucket is
    put on the ground, whatever the skill and acceptance. ISShearAnimal:stress has the
    same computation without the override, which is how it was meant to work. This is
    vanilla's stress() with that one line left out; everything else (the extra stress,
    the flee, the spilt bucket on the ground, the sound) is unchanged.

    It runs where vanilla's runs: on the server in multiplayer (the client's update skips
    milk()), locally in single player. Option MilkingStressFix, off by default (user,
    2026-11-20). Tien's Skill Mastery carries the same fix always on; with both loaded,
    either order gives the fixed roll (this one, when off, calls whatever it replaced).
--]]

require "TimedActions/Animals/ISMilkAnimal"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.MilkingStressFix == true
end

local vanillaStress = ISMilkAnimal.stress

function ISMilkAnimal:stress()
    if not isEnabled() then
        return vanillaStress(self)
    end

    -- stress can make the animal break from the milking
    if self.animal:getStress() > 40 and self.character:getPerkLevel(Perks.Husbandry) <= 7 then
        local chance = self.animal:getStress()
        chance = chance - (self.character:getPerkLevel(Perks.Husbandry) * 5)
        chance = chance - (self.animal:getAcceptanceLevel(self.character) * 5)

        if ZombRand(100) < chance then
            self.animal:changeStress((ZombRand(3, 8) / 5))

            local sq
            if self.animal:getDZone() then
                sq = self.animal:getRandomSquareInZone()
            end
            if not sq then
                local asq = self.animal:getSquare()
                sq = getSquare(ZombRand(asq:getX() - 5, asq:getX() + 5), ZombRand(asq:getY() - 5, asq:getY() + 5),
                    asq:getZ())
            end
            self.animal:fleeTo(sq)

            self.bucket:getFluidContainer():removeFluid()

            self.character:getInventory():Remove(self.bucket)
            sendRemoveItemFromContainer(self.character:getInventory(), self.bucket)
            self.animal:getSquare():AddWorldInventoryItem(self.bucket, 0, 0, 0)
            self.character:getInventory():setDrawDirty(true)

            self.animal:playStressedSound()
            return true
        end
    end

    return false
end
