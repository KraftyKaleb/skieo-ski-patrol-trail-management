-- Game access for the ski patrol: native trails, time, weather, grooming and
-- snow. Every call is guarded, because the game is in Early Access and its
-- classes can change. Runs only on the game thread.
local Native = {}

local function valid(o)
    if o == nil then return false end
    local ok, result = pcall(function() return o:IsValid() end)
    return ok and result
end
Native.valid = valid

local function unwrap(value)
    for _ = 1, 3 do
        if type(value) ~= 'userdata' and type(value) ~= 'table' then break end
        local ok, inner = pcall(function() return value:get() end)
        if not ok then break end
        value = inner
    end
    return value
end

local world_helper
local function world()
    if world_helper == nil then
        local ok, helpers = pcall(require, 'UEHelpers')
        world_helper = ok and helpers or false
    end
    if world_helper then
        local ok, w = pcall(world_helper.GetWorld)
        if ok and valid(w) then return w end
    end
    return nil
end

function Native.world_key()
    local w = world()
    if not w then return nil end
    local ok, address = pcall(function() return w:GetAddress() end)
    return ok and address or nil
end

-- The subsystem instance that belongs to the current world.
local cache = {}
local function subsystem(name)
    local key = Native.world_key()
    local cached = cache[name]
    if cached and cached.world == key and valid(cached.object) then return cached.object end
    cache[name] = nil
    if not key then return nil end
    for _, o in ipairs(FindAllOf(name) or {}) do
        if valid(o) then
            local ok, same = pcall(function()
                if o:GetFullName():find('Default__', 1, true) then return false end
                local w = o:GetWorld()
                return valid(w) and w:GetAddress() == key
            end)
            if ok and same then
                cache[name] = {world = key, object = o}
                return o
            end
        end
    end
    return nil
end
Native.subsystem = subsystem

-- Game clock: total game hours, hour of day, and whether time is stopped.
function Native.clock()
    local time = subsystem('TimeSubsystem')
    if not time then return nil end
    local ok, result = pcall(function()
        local hours = tonumber(time:GetTotalGameHoursElapsed())
        local rate = tonumber(time:GetTimeRate()) or 1
        local paused = time:IsTimePaused() or rate == 0
        return {hours = hours, hour = tonumber(time:GetTimeOfDayHours()), paused = paused}
    end)
    if ok and result and result.hours then return result end
    return nil
end

-- Native weather type (0 sun, 1 clouds, 2 precipitation, 3 blizzard) and the
-- temperature at a position.
function Native.weather(x, y, z)
    local weather = subsystem('WeatherSubsystem')
    if not weather then return nil end
    local ok, kind = pcall(function() return tonumber(weather:GetWeatherType()) end)
    if not ok then return nil end
    local temperature
    if x then
        local okt, t = pcall(function() return weather:GetTemperatureAtLocation({X = x, Y = y, Z = z or 0}) end)
        if okt then temperature = tonumber(t) end
    end
    return kind, temperature
end

local function point(v)
    v = unwrap(v)
    return {x = tonumber(v.X) or 0, y = tonumber(v.Y) or 0, z = tonumber(v.Z) or 0}
end

local function curve(v)
    v = unwrap(v)
    return {point(v.StartPoint), point(v.ControlPoint), point(v.Endpoint)}
end

-- Plain Lua copies of every registered trail.
function Native.trails()
    local map = subsystem('TrailMapSubsystem')
    if not map then return nil end
    local list = {}
    local ok, failure = pcall(function()
        map.RegisteredTrails:ForEach(function(key, value)
            local info = unwrap(value)
            local id = tonumber(unwrap(key))
            if not id or not info then return end
            local trail = {id = id, curves = {}}
            pcall(function() trail.name = info.DisplayName:ToString() end)
            pcall(function() trail.disabled = info.bManuallyDisabled and true or false end)
            pcall(function() trail.curves[1] = curve(info.Curve) end)
            -- Only the first curve is read. Never touch info.AdditionalCurves:
            -- on game build CL8198 with UE4SS 4.0, that array's element
            -- property comes back null when the trail info is read out of
            -- RegisteredTrails, and iterating it (or indexing it) makes
            -- UE4SS read through a null pointer. That is a hard crash that
            -- pcall can't catch, and it hits as soon as a save with a
            -- multi-segment run loads. Steepness is therefore measured on the
            -- first segment of each run.
            -- Optional: the native difficulty enum, if the struct exposes it.
            pcall(function() trail.difficulty = tonumber(unwrap(info.Difficulty)) end)
            if trail.disabled ~= nil and #trail.curves > 0 then list[#list + 1] = trail end
        end)
    end)
    if not ok then return nil, failure end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function Native.set_disabled(id, disabled)
    local map = subsystem('TrailMapSubsystem')
    if not map then return false, 'trail map unavailable' end
    local ok, failure = pcall(function() map:SetTrailDisabled(id, disabled) end)
    return ok, failure
end

-- True/false while a grooming job runs on the trail, nil if unknown.
function Native.grooming(id)
    local groom = subsystem('GroomingSubsystem')
    if not groom then return nil end
    local ok, active = pcall(function() return groom:HasActiveGroomingEvent(id) end)
    if ok then return active and true or false end
    return nil
end

------------------------------------------------------------------------
-- The player's units: Options > Measurement System (Automatic, Imperial, Metric)
------------------------------------------------------------------------
local settings_object
-- 'imperial' or 'metric', or nil when the setting can't be read. Automatic follows
-- the system language: en-US (and the other imperial regions) show imperial.
function Native.measurement_system()
    if not (settings_object and valid(settings_object)) then
        settings_object = nil
        for _, o in ipairs(FindAllOf('SkiResortGameUserSettings') or {}) do
            local ok, default = pcall(function() return o:GetFullName():find('Default__', 1, true) end)
            if valid(o) and ok and not default then settings_object = o break end
        end
    end
    if not settings_object then return nil end
    local ok, value = pcall(function() return tonumber(settings_object.MeasurementSystem) end)
    if not ok or value == nil then return nil end
    if value == 1 then return 'imperial' elseif value == 2 then return 'metric' end
    -- Automatic: ask the engine for the current culture.
    local okc, culture = pcall(function()
        local lib = StaticFindObject('/Script/Engine.Default__KismetInternationalizationLibrary')
        return lib:GetCurrentLocale():ToString()
    end)
    if okc and type(culture) == 'string' and (culture:find('^en[-_]US') or culture:find('^en[-_]LR')
        or culture:find('^my')) then return 'imperial' end
    return 'metric'
end

------------------------------------------------------------------------
-- Snow depth through this mod's own native reader (Native/PatrolSnow.dll)
------------------------------------------------------------------------
-- Lua can't read the game's snow, so Native/PatrolSnow.dll does: it reads the
-- game's CPU snow tiles (no GPU readback) and only after four exact code
-- fingerprints of this game build match, otherwise it answers "unsupported".
-- Job and answer travel through three small files in %LOCALAPPDATA% named
-- Ski-E-O-Mod-<mod folder>-snow.job / .bin / .status (see native/patrol_snow.c).
-- When the DLL, LOCALAPPDATA or a supported game build is missing, snow cover
-- is simply unknown and the thin-cover rule is skipped.
local sampler = {state = 'unknown'}   -- unknown | ready | missing | unsupported

local function locate()
    local source = debug.getinfo(1, 'S').source:match('^@(.*)$') or ''
    local scripts = source:match('^(.*[/\\])[^/\\]+$')
    local root = scripts and scripts:match('^(.*[/\\])Scripts[/\\]$')
    local id = root and root:match('([^/\\]+)[/\\]$')
    local base = os.getenv and os.getenv('LOCALAPPDATA')
    if not (root and id and base and base ~= '') then return nil end
    local prefix = base:gsub('[/\\]+$', '') .. '/Ski-E-O-Mod-' .. id .. '-snow'
    return {dll = root .. 'Native/PatrolSnow.dll', job = prefix .. '.job', out = prefix .. '.bin',
        status = prefix .. '.status'}
end
Native._locate = locate

local function load_sampler()
    if sampler.state ~= 'unknown' then return end
    sampler.state, sampler.reason = 'missing', 'the snow reader (Native/PatrolSnow.dll) could not be loaded'
    local where = locate()
    if not (where and type(package.loadlib) == 'function') then return end
    local ok, fn = pcall(package.loadlib, where.dll, 'patrol_snow')
    if ok and fn then
        sampler.fn, sampler.files, sampler.state, sampler.reason = fn, where, 'ready', nil
    end
end

local function read_status()
    local f = sampler.files and io.open(sampler.files.status, 'r')
    if not f then return nil end
    local line = f:read('l')
    f:close()
    return line
end

-- true unless snow readings are known to be impossible
function Native.snow_available()
    load_sampler()
    return sampler.state == 'ready'
end

-- Why snow readings are not available (a short phrase), or nil.
function Native.snow_problem()
    load_sampler()
    if sampler.state == 'ready' then return nil end
    return sampler.reason
end

-- Samples up to 64 positions. Returns one entry per point:
-- {total, packed, fresh} in cm, or false where the cache has no data.
function Native.sample_snow(points)
    if #points == 0 or not Native.snow_available() then return nil end
    local cache_object = subsystem('SnowStateCache')
    local cls = StaticFindObject('/Script/SkiResortSimulator.SnowStateCache')
    if not cache_object or not valid(cls) then return nil end
    local ok, rows = pcall(function()
        local batch = {}
        for i = 1, math.min(64, #points) do batch[i] = points[i] end
        local parts = {string.pack('<c4I4I8I8I4I4', 'SKSN', 2, cache_object:GetAddress(), cls:GetAddress(), #batch, 0)}
        for _, p in ipairs(batch) do parts[#parts + 1] = string.pack('<dd', p.x, p.y) end
        local files = sampler.files
        local f = assert(io.open(files.job, 'wb'))
        f:write(table.concat(parts))
        f:close()
        os.remove(files.out)
        sampler.fn()
        local status = read_status()
        if status and status:find('^unsupported') then
            sampler.state, sampler.reason = 'unsupported', "the snow reader doesn't recognise this game build"
            sampler.detail = status
            return nil
        end
        f = io.open(files.out, 'rb')
        if not f then return nil end
        local bytes = f:read('a')
        f:close()
        if #bytes ~= #batch * 16 then return nil end
        local result = {}
        for i = 1, #batch do
            local ready, packed, fresh = string.unpack('<fff', bytes, 1 + (i - 1) * 16)
            result[i] = ready == 1 and {total = packed + fresh, packed = packed, fresh = fresh} or false
        end
        return result
    end)
    if ok then return rows end
    return nil
end

-- The reader's own one-line status ("ok", "unsupported: ...", "error: ..."), for the report.
function Native.snow_detail()
    load_sampler()
    return sampler.detail or read_status() or (sampler.state == 'ready' and 'not used yet' or sampler.reason)
end

return Native
