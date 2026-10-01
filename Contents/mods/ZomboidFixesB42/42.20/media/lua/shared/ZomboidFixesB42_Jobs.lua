--[[
    Zomboid Fixes B42.20 -- shared, time-sliced jobs

    Not a fix of its own: the scheduler that spreads long Lua work over several
    ticks so it never stalls a frame (client) or a server update (everyone).

    There are no threads for mods: all Lua runs in one KahluaThread on the game's
    main thread (LuaManager.thread). Kahlua does register the coroutine library
    (J2SEPlatform.newEnvironment -> CoroutineLib.register), vanilla just never
    uses it, so a long loop runs as a coroutine that calls Jobs.Step() as it
    goes; once the tick's budget is spent, Step yields and OnTick resumes the job
    on the next tick. Every job shares one budget per tick, so more jobs only
    means slower results, never more load.

    A coroutine cannot yield from inside a Lua function that Java called (a
    table.sort comparator, an event handler), so long sorts use Jobs.Sort, and a
    job must not keep a pairs() walk going across yields over a table that may get
    new keys meanwhile.

    The budget follows the game's health: OnTick intervals are averaged, and while
    jobs run on a slow server (ticks over 130 ms; a healthy dedicated server runs
    ten updates a second) or a slow client (frames over 50 ms) it is halved once a
    second, down to 1 ms, then raised by 1 ms after three healthy seconds. A
    server logs each slowdown.
--]]

ZomboidFixesB42 = ZomboidFixesB42 or {}

local Jobs = {}
ZomboidFixesB42.Jobs = Jobs

Jobs.CHECK_EVERY = 25
Jobs.SERVER = { max = 8, min = 1, healthyMs = 110, strainedMs = 130 }
Jobs.CLIENT = { max = 3, min = 1, healthyMs = 34, strainedMs = 50 }
Jobs.ADAPT_MS = 1000
Jobs.RECOVER_AFTER = 3

local jobs = {}
local order = {}
local sliceEndMs = 0
local counter = 0
local current = nil

local lastTickMs = nil
local avgIntervalMs = nil
local budgetMs = nil
local lastAdaptMs = 0
local healthyRuns = 0

local function profile()
    if isServer() then return Jobs.SERVER end
    return Jobs.CLIENT
end

local function currentBudget()
    if not budgetMs then budgetMs = profile().max end
    return budgetMs
end

local function remove(name)
    jobs[name] = nil
    for i = #order, 1, -1 do
        if order[i] == name then table.remove(order, i) end
    end
end

local function fail(name, err)
    print("[ZomboidFixesB42] job " .. tostring(name) .. " failed: " .. tostring(err))
end

--- Starts fn as a job, replacing a running job of the same name.
function Jobs.Start(name, fn)
    Jobs.Cancel(name)
    local job = { name = name, startedMs = getTimestampMs() }
    if coroutine then
        job.co = coroutine.create(fn)
    else
        job.run = fn
    end
    jobs[name] = job
    order[#order + 1] = name
    return job
end

function Jobs.Cancel(name)
    if jobs[name] then remove(name) end
end

function Jobs.IsRunning(name)
    return jobs[name] ~= nil
end

function Jobs.IsStrained()
    return currentBudget() < profile().max
end

--- Runs a job to its end right now, without yielding (for a caller that cannot wait).
function Jobs.Finish(name)
    local job = jobs[name]
    if not job then return end
    remove(name)
    if not job.co then
        job.run()
        return
    end
    local saved = current
    current = nil
    while coroutine.status(job.co) ~= "dead" do
        local ok, err = coroutine.resume(job.co)
        if not ok then
            fail(name, err)
            break
        end
    end
    current = saved
end

--- Call inside a job's loops: yields once the tick's budget is spent. Outside a job
-- (or while Finish runs one) it does nothing.
function Jobs.Step()
    if not current or not current.co then return end
    counter = counter + 1
    if counter < Jobs.CHECK_EVERY then return end
    counter = 0
    if getTimestampMs() >= sliceEndMs then
        coroutine.yield()
    end
end

--- Inside a job, yields until fn() is false. Outside a job it returns at once.
function Jobs.WaitWhile(fn)
    if not current or not current.co then return end
    while fn() do
        coroutine.yield()
    end
end

--- Sorts list in place with less(a, b), stepping as it goes (bottom-up merge sort,
-- stable). table.sort cannot be sliced: its comparator is called from Java.
function Jobs.Sort(list, less)
    local n = #list
    if n < 2 then return list end
    local src, dst = list, {}
    local width = 1
    while width < n do
        local i = 1
        while i <= n do
            local mid = math.min(i + width, n + 1)
            local hi = math.min(i + width * 2, n + 1)
            local a, b, k = i, mid, i
            while a < mid and b < hi do
                if less(src[b], src[a]) then
                    dst[k] = src[b]
                    b = b + 1
                else
                    dst[k] = src[a]
                    a = a + 1
                end
                k = k + 1
                Jobs.Step()
            end
            while a < mid do
                dst[k] = src[a]
                a = a + 1
                k = k + 1
            end
            while b < hi do
                dst[k] = src[b]
                b = b + 1
                k = k + 1
            end
            i = hi
        end
        src, dst = dst, src
        width = width * 2
    end
    if src ~= list then
        for i = 1, n do list[i] = src[i] end
    end
    return list
end

local function runOne(name)
    local job = jobs[name]
    if not job then return end
    current = job
    counter = 0
    local finished
    if job.co then
        local ok, err = coroutine.resume(job.co)
        if not ok then fail(name, err) end
        finished = coroutine.status(job.co) == "dead"
    else
        job.run()
        finished = true
    end
    current = nil
    if finished and jobs[name] == job then remove(name) end
end

local function adapt(now)
    if now - lastAdaptMs < Jobs.ADAPT_MS or not avgIntervalMs then return end
    lastAdaptMs = now
    local p = profile()
    local budget = currentBudget()
    if avgIntervalMs > p.strainedMs and #order > 0 then
        healthyRuns = 0
        if budget > p.min then
            budgetMs = math.max(p.min, math.floor(budget / 2))
            if isServer() then
                print(string.format("[ZomboidFixesB42] server ticks are slow (%d ms); job budget lowered to %d ms a tick",
                    math.floor(avgIntervalMs), budgetMs))
            end
        end
    elseif avgIntervalMs < p.healthyMs then
        healthyRuns = healthyRuns + 1
        if budget < p.max and healthyRuns >= Jobs.RECOVER_AFTER then
            healthyRuns = 0
            budgetMs = budget + 1
        end
    end
end

local function onTick()
    local now = getTimestampMs()
    if lastTickMs then
        local interval = now - lastTickMs
        avgIntervalMs = avgIntervalMs and (avgIntervalMs * 0.8 + interval * 0.2) or interval
    end
    lastTickMs = now
    adapt(now)
    if #order == 0 then return end
    sliceEndMs = now + currentBudget()
    local names = {}
    for i, name in ipairs(order) do names[i] = name end
    for _, name in ipairs(names) do
        if getTimestampMs() >= sliceEndMs then break end
        runOne(name)
    end
    if #order > 1 then
        local first = table.remove(order, 1)
        if jobs[first] then order[#order + 1] = first end
    end
end

Events.OnTick.Add(onTick)
