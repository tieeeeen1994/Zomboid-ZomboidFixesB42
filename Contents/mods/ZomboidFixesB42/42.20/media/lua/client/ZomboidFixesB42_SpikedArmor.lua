--[[
    Zomboid Fixes B42.20 -- client, spiked armor hurts the zombies that attack it

    Spiked clothing (item tag base:spiked, base:spikedbehind for the back of some
    pieces) is meant to punish whoever grabs or bites it. For players it works: a
    player who shoves or knifes someone wearing spikes on the part hit takes an ice
    pick wound in the hand or foot (CombatManager.resolveSpikedArmorDamage ->
    IsoGameCharacter.spikePartIndex -> BodyDamage.DamageFromWeapon(IcePick)).

    For zombies it does nothing. BodyDamage.AddRandomDamageFromZombie (42.21 ~1424)
    checks the part the zombie went for (bodyPartIsSpiked, or bodyPartIsSpikedBehind
    when it attacks from behind or the victim lies on its front: a worn Clothing item
    with that tag covering the part, with no hole there) and calls
    zombie.spikePart(Hand_L or Hand_R) on every scratch or laceration, before the
    defense roll, and zombie.spikePart(Head) on a bite the clothing stops. A zombie
    has no BodyDamage, so spikePartIndex (IsoGameCharacter ~15748) takes the other
    branch: blood on the floor, the ice pick's hit sound and

        this.Hit(IcePick, cell.getFakeZombieForHit(), 0.0F, false, 0.0F)

    a hit for 0 damage (processHitDamage = damageSplit * modDelta). Only a bite that
    gets through a spiked part kills the zombie (zombie.Kill right after).

    IsoZombie.Hit fires OnHitZombie(zombie, wielder, bodyPart, weapon) before
    IsoGameCharacter.Hit runs, so here that hit is recognised (the wielder is the
    cell's fake zombie and the weapon an ice pick; trap explosions also hit with the
    fake zombie, but with the trap as weapon) and the zombie loses what the ice pick
    deals, a random amount between its MinDamage and MaxDamage (0.6 to 0.9; a
    zombie has 1.8 to 2.1 health with normal toughness, 3.5 to 3.8 tough, 0.5 to 0.8
    fragile). Lowered before Hit goes on, so its hitConsequences sees a zombie at 0
    as dead: single player then kills it the vanilla way (Kill with the ice pick).

    Multiplayer: AddRandomDamageFromZombie runs on the client that owns the zombie
    (AttackState's AttackCollisionCheck), victim local or remote, and that client's
    zombie health is the one that counts: it goes to the server in ZombiePacket
    (NetworkZombiePacker.applyZombie), and at 0 the server's parseZombie calls die()
    and tells everyone. So the damage is applied there and only on zombies this
    client owns. The server's own re-roll of a wound that got through (Bite.process
    -> AddRandomDamageFromZombie) spikes its copy too; that copy is overwritten by
    the owner's next packet, and the server does not load this folder anyway.

    Left as they are: a bite that gets through on the owner sends ZombieHitPlayer and
    returns before the spike, so in multiplayer only the server's re-roll can spike
    (and kill) it; and when another client takes the zombie over, it may not have
    the lowered health (other clients ignore ZombiePacket health for a zombie they
    already have).
--]]

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.SpikedArmorHurtsZombies == true
end

--- Whether this hit is vanilla's spike hit (IsoGameCharacter.spikePartIndex).
local function isSpikeHit(wielder, weapon)
    if not wielder or not weapon then return false end
    if weapon:getFullType() ~= "Base.IcePick" then return false end
    local cell = getCell()
    return cell ~= nil and wielder == cell:getFakeZombieForHit()
end

local function onHitZombie(zombie, wielder, bodyPart, weapon)
    if not isEnabled() or isServer() then return end
    if not zombie or zombie:isDead() then return end
    if isClient() and zombie:isRemoteZombie() then return end
    if not isSpikeHit(wielder, weapon) then return end

    local damage = ZombRandFloat(weapon:getMinDamage(), weapon:getMaxDamage())
    zombie:setHealth(math.max(0, zombie:getHealth() - damage))
end

Events.OnHitZombie.Add(onHitZombie)
