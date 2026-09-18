--[[
    Zomboid Fixes B42.20 -- server, hutch dirt speed

    Hutches get filthy fast, and the nest boxes far faster than the hutch itself.
    Both counters are rolled per hutch update, and IsoHutch.update() is driven by
    HutchManager.updateAll() from IsoWorld.updateInternal() -- once a frame.

    The hutch floor, in IsoHutch.update():

        int prob = 8000 - this.animalInside.size() * 100;
        if (prob < 4500) { prob = 4500; }
        if (!this.animalInside.isEmpty() && Rand.NextBool(prob)) {
            this.hutchDirt = Math.min(this.hutchDirt + 1.0F, 100.0F);

    Rand.NextBool takes an inverse probability, so that is one point per `prob`
    frames: 1 in 6000 with twenty birds, or a point every hundred seconds at sixty
    frames a second. Slow enough.

    The nest boxes, in updateAnimalInside(), for a hen who is sitting in one:

        if (Rand.NextBool(300)) {
            this.nestBoxDirt = Math.min(this.nestBoxDirt + 1.0F, 100.0F);
        }

    One in three hundred frames -- a point every five seconds -- and it is rolled
    once per laying hen, so a hutch with all four boxes busy earns a point better
    than once a second. Clean to filthy in about two minutes of real time with the
    coop loaded. That is the number that makes hutches feel like a treadmill, and
    it is roughly eighty times the rate of the floor beside it.

    Away from the coop, IsoHutch.doMeta(hours) rolls once an hour for each counter:

        int prob = 25 - (this.animalInside.size() + this.animalOutside.size());
        if (prob > 10) { prob = 10; }

    which is a fifth of a point an hour with twenty birds -- the offscreen rate is
    nothing like the loaded one, so the mess really does track time spent nearby.

    None of those rolls can be reached from Lua. What can be reached is the result:
    getHutchDirt/setHutchDirt and getNestBoxDirt/setNestBoxDirt are public, so this
    watches the two counters and hands back a share of every rise. Working from the
    rise rather than the rate is what keeps it honest: it never needs to know which
    roll produced a point, and it cannot drift away from whatever vanilla did.

    What it does not brake is doMeta. A chunk reload builds a new IsoHutch, so the
    baseline resets to whatever dirt came back out of the save and the hours away
    are charged in full. That is deliberate -- a fifth of a point an hour is not
    what anyone is complaining about, and guessing at a baseline across a reload
    risks scrubbing dirt the player never earned.

    A fall is never touched, so cleaning the hutch out by hand still works and
    ISHutchCleanNest is left alone. Fractions are carried between passes, so a
    setting of 0.25 really is a quarter of the mess over time and not a rounding
    error repeated forever.

    Sampling is on EveryOneMinute rather than a tick, because a difference does not
    care how often it is read: a rise of twelve points seen once is braked exactly
    like twelve rises of one. Between two samples the counter can sit a point or
    two above where the setting wants it, which is well inside the thresholds that
    matter (20 for health loss, 40 to stop regen).

    Hutches are found through DesignationZoneAnimal.getAllZones(), because
    HutchManager is not on the Lua exposer's list. A hutch outside every animal zone
    is not braked.

    Runs on the server in multiplayer and on the game itself in single player, which
    is where hutch state is authoritative. Vanilla syncs the hutch every time it
    bumps dirt, so this does the same after every change it makes.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

-- hutch key -> { hutch, hutchDirt, nestBoxDirt, hutchDebt, nestBoxDebt }
local watched = {}

--- 1.0 is vanilla, 0.25 a quarter of the mess, 0 never dirty at all. Anything at
-- or above 1 means there is nothing to do, which is also what an absent option
-- gives, so the fix ships inert.
local function dirtSpeed()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    local speed = vars and vars.HutchDirtSpeed
    if type(speed) ~= "number" then return 1.0 end
    if speed < 0 then return 0.0 end
    return speed
end

local function hutchKey(hutch)
    return math.floor(hutch:getX()) .. "," .. math.floor(hutch:getY()) .. "," .. math.floor(hutch:getZ())
end

--- Brake one counter. Returns the value it should now hold, and the carried
-- fraction, or nil when nothing needs changing.
local function brake(current, last, debt, keep)
    if current < last then
        -- Cleaned. Follow it down and drop the fraction: handing back part of a
        -- scrub would be taking away work the player just did.
        return nil, 0
    end

    -- Only a rise adds to the debt, but an unchanged reading must not clear it.
    -- Dropping the fraction whenever a sample happens to show no change would mean
    -- a counter that climbs slower than the sampling never gives anything back --
    -- at 0.25 speed each single point would bank 0.75 and lose it on the next quiet
    -- pass, forever.
    debt = debt + (current - last) * keep

    local giveBack = math.floor(debt)
    if giveBack < 1 then return nil, debt end

    local wanted = current - giveBack
    if wanted < 0 then
        giveBack = giveBack + wanted
        wanted = 0
    end

    return wanted, debt - giveBack
end

local function checkHutch(key, hutch, keep)
    local entry = watched[key]

    -- A rebuilt or reloaded hutch is a different object carrying its own saved
    -- dirt. Take that as the new baseline rather than braking it as if the whole
    -- value had just accumulated.
    if not entry or entry.hutch ~= hutch then
        watched[key] = {
            hutch = hutch,
            hutchDirt = hutch:getHutchDirt(),
            nestBoxDirt = hutch:getNestBoxDirt(),
            hutchDebt = 0,
            nestBoxDebt = 0,
        }
        return
    end

    local changed = false

    local hutchDirt = hutch:getHutchDirt()
    local wanted, debt = brake(hutchDirt, entry.hutchDirt, entry.hutchDebt, keep)
    entry.hutchDebt = debt
    if wanted then
        hutch:setHutchDirt(wanted)
        hutchDirt = wanted
        changed = true
    end
    entry.hutchDirt = hutchDirt

    local nestBoxDirt = hutch:getNestBoxDirt()
    wanted, debt = brake(nestBoxDirt, entry.nestBoxDirt, entry.nestBoxDebt, keep)
    entry.nestBoxDebt = debt
    if wanted then
        hutch:setNestBoxDirt(wanted)
        nestBoxDirt = wanted
        changed = true
    end
    entry.nestBoxDirt = nestBoxDirt

    -- IsoObject.syncIsoObject logs an error on a square-less object, and a hutch
    -- out of the world has nobody to tell anyway.
    if changed and hutch:isExistInTheWorld() then
        hutch:sync()
    end
end

local function pass()
    local speed = dirtSpeed()
    if speed >= 1.0 then
        -- Nothing to do at vanilla speed, and nothing worth remembering either: a
        -- stale baseline would brake a whole session's worth of dirt in one go if
        -- the setting were turned down mid-game.
        if next(watched) then watched = {} end
        return
    end

    local zones = DesignationZoneAnimal.getAllZones()
    if not zones then return end

    local keep = 1.0 - speed
    local seen = {}

    for z = 0, zones:size() - 1 do
        local zone = zones:get(z)
        local hutches = zone and zone:getHutchs()
        if hutches then
            for h = 0, hutches:size() - 1 do
                local hutch = hutches:get(h)
                if hutch then
                    local key = hutchKey(hutch)
                    if not seen[key] then
                        seen[key] = true
                        checkHutch(key, hutch, keep)
                    end
                end
            end
        end
    end

    -- A zone rebuilds its hutch list from loaded squares, so one drops out whenever
    -- its chunk is away. Forget it rather than hold a baseline that will be stale
    -- by the time it comes back -- doMeta will have moved the counters on, and that
    -- rise belongs to hours spent away, which vanilla already charges lightly.
    for key in pairs(watched) do
        if not seen[key] then watched[key] = nil end
    end
end

Events.EveryOneMinute.Add(pass)
