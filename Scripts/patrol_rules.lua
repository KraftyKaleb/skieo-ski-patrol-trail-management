-- Ski patrol decisions. Pure Lua with no game access, so it can be tested
-- outside Ski-E-O!. Times are game hours (TimeSubsystem total hours elapsed),
-- distances are centimetres (Unreal units), temperatures are Celsius.
local Rules = {}

Rules.DEFAULTS = {
    enabled = true,
    -- How often the patrol looks at the mountain (real milliseconds).
    tick_ms = 2000,
    -- Snow depth along each run is resampled at most this often (real seconds).
    cover_refresh_seconds = 30,
    snow_sample_spacing_m = 25,
    -- Steepness is the steepest average pitch over any section this long.
    pitch_window_m = 20,

    -- Avalanche danger (European 1-5 scale), from a new-snow model.
    avalanche = true,
    new_snow_levels_cm = {10, 25, 40, 60},   -- 2, 3, 4, 5 at or above each
    blizzard_cm_per_hour = 4,
    snowfall_cm_per_hour = 2,
    snow_below_c = 1.5,                        -- precipitation is snow at or below this
    settle_half_life_hours = 36,               -- new snow stabilises over time
    warm_settle_half_life_hours = 12,          -- faster above 0 °C
    warming_c = 2,                             -- warm spell on new snow raises danger
    -- Close runs at least this steep (degrees) at each danger level.
    avalanche_pitch_deg = {[3] = 30, [4] = 25, [5] = 20},
    avalanche_control_hours = 2,               -- control work before reopening

    -- Blizzard: close exposed runs, reopen after the storm has passed.
    storm = true,
    storm_pitch_deg = 22,
    storm_difficulty = 2,                      -- native 0 beginner .. 3 extreme
    storm_clear_hours = 1,

    -- Thin snow cover (needs the Custom Map loader's snow sampler).
    thin_cover = true,
    thin_close_cm = 25,
    thin_open_cm = 35,
    thin_percentile = 10,                      -- judge the run by its worst 10 %

    -- Close a run while a snowcat is grooming it.
    grooming = true,
    grooming_max_hours = 4,                    -- ignore grooming jobs that never end

    -- Extreme cold.
    cold = true,
    cold_close_c = -30,
    cold_open_c = -26,

    -- Units shown in messages: 'auto' follows the game's Measurement System setting,
    -- or force 'metric' / 'imperial'.
    units = 'auto',

    -- General.
    min_closed_hours = 0.5,
    -- If you reopen a run the patrol closed, the patrol leaves it alone this long.
    override_hours = 24,
    -- Show the "Ski patrol" section (closure reason, reopen button) in the trail panel.
    trail_panel = true,
    log_prefix = '[Ski Patrol]',
}

local function finite(n) return type(n) == 'number' and n == n and math.abs(n) < 1e12 end

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end
Rules.copy = copy

-- Merge user overrides into the defaults. Unknown keys and wrong types are
-- reported and ignored rather than stopping the mod.
function Rules.config(user, warn)
    local cfg = copy(Rules.DEFAULTS)
    warn = warn or function() end
    for key, value in pairs(user or {}) do
        local default = Rules.DEFAULTS[key]
        if default == nil then
            warn('unknown setting ' .. tostring(key))
        elseif type(default) ~= type(value) or (type(value) == 'number' and not finite(value)) then
            warn('setting ' .. tostring(key) .. ' should be a ' .. type(default))
        elseif type(value) == 'table' then
            local ok = true
            for k, v in pairs(value) do ok = ok and type(k) == 'number' and finite(v) end
            if ok then cfg[key] = copy(value) else warn('setting ' .. key .. ' should list numbers') end
        else
            cfg[key] = value
        end
    end
    cfg.tick_ms = math.max(250, math.min(60000, cfg.tick_ms))
    cfg.snow_sample_spacing_m = math.max(5, cfg.snow_sample_spacing_m)
    cfg.pitch_window_m = math.max(5, cfg.pitch_window_m)
    if cfg.units ~= 'auto' and cfg.units ~= 'metric' and cfg.units ~= 'imperial' then
        warn("setting units should be 'auto', 'metric' or 'imperial'")
        cfg.units = 'auto'
    end
    if cfg.thin_open_cm < cfg.thin_close_cm then cfg.thin_open_cm = cfg.thin_close_cm end
    if cfg.cold_open_c < cfg.cold_close_c then cfg.cold_open_c = cfg.cold_close_c end
    return cfg
end

------------------------------------------------------------------------
-- Units for messages (the rules themselves always work in cm, m and °C)
------------------------------------------------------------------------
local function num(v, decimals) return string.format('%.' .. (decimals or 0) .. 'f', v) end
Rules.METRIC = {
    imperial = false,
    depth = function(cm) return num(cm) .. ' cm' end,
    temperature = function(c) return num(c) .. ' °C' end,
    length = function(m) return num(m) .. ' m' end,
}
Rules.IMPERIAL = {
    imperial = true,
    depth = function(cm) return num(cm / 2.54) .. ' in' end,
    temperature = function(c) return num(c * 9 / 5 + 32) .. ' °F' end,
    length = function(m) return num(m * 3.28084) .. ' ft' end,
}
-- system: 'imperial' or anything else (metric)
function Rules.units(system) return system == 'imperial' and Rules.IMPERIAL or Rules.METRIC end

------------------------------------------------------------------------
-- Run geometry
------------------------------------------------------------------------

-- Native trails are chains of quadratic Bézier curves {a, c, b} with
-- {x, y, z} points. Returns a polyline sampled about every `step` cm.
function Rules.polyline(curves, step)
    step = step or 500
    local points = {}
    for _, curve in ipairs(curves) do
        local a, c, b = curve[1], curve[2], curve[3]
        local chord = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2)
        local n = math.max(1, math.min(200, math.ceil(chord / step)))
        for i = (#points == 0 and 0 or 1), n do
            local t = i / n
            local u = 1 - t
            points[#points + 1] = {
                x = u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                y = u * u * a.y + 2 * u * t * c.y + t * t * b.y,
                z = u * u * a.z + 2 * u * t * c.z + t * t * b.z,
            }
        end
    end
    return points
end

-- Length, vertical drop and steepest pitch (degrees) of a polyline.
function Rules.profile(points, window_m)
    local window = (window_m or 20) * 100
    local along = {0}
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        along[i] = along[i - 1] + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    end
    local length = along[#along] or 0
    local pitch = 0
    local j = 1
    for i = 2, #points do
        -- Shortest section ending at i that spans the window (or the whole run).
        while j + 1 < i and along[i] - along[j + 1] >= window do j = j + 1 end
        local horizontal = along[i] - along[j]
        if horizontal >= math.min(window, length) and horizontal > 0 then
            local drop = math.abs(points[j].z - points[i].z)
            pitch = math.max(pitch, math.deg(math.atan(drop, horizontal)))
        end
    end
    local drop = #points > 1 and math.abs(points[1].z - points[#points].z) or 0
    return {length_m = length / 100, drop_m = drop / 100, pitch_deg = pitch}
end

-- Evenly spaced positions for snow samples (at most `limit`).
function Rules.sample_points(points, spacing_m, limit)
    limit = limit or 64
    local spacing = spacing_m * 100
    local out, carried = {}, 0
    if #points == 0 then return out end
    out[1] = {x = points[1].x, y = points[1].y}
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        local d = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        local s = spacing - carried
        while s <= d do
            local t = s / d
            out[#out + 1] = {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t}
            s = s + spacing
        end
        carried = d - (s - spacing)
    end
    local last = points[#points]
    if out[#out].x ~= last.x or out[#out].y ~= last.y then out[#out + 1] = {x = last.x, y = last.y} end
    if #out <= limit then return out end
    local thinned = {}
    for i = 1, limit do thinned[i] = out[1 + math.floor((i - 1) * (#out - 1) / (limit - 1) + 0.5)] end
    return thinned
end

-- Snow cover of a run from samples ({total=cm} or false). Returns the given
-- percentile depth, or nil when too few samples are ready to judge.
function Rules.cover(samples, percentile)
    local depths = {}
    for _, s in ipairs(samples) do if s and finite(s.total) then depths[#depths + 1] = s.total end end
    if #samples == 0 or #depths < math.max(1, math.ceil(#samples * 0.6)) then return nil end
    table.sort(depths)
    local index = math.max(1, math.min(#depths, math.ceil(#depths * (percentile or 10) / 100)))
    return depths[index]
end

------------------------------------------------------------------------
-- Weather history and avalanche danger
------------------------------------------------------------------------

function Rules.new_weather()
    return {new_snow_cm = 0, warm = false}
end

-- weather_type: native 0 sun, 1 clouds, 2 precipitation, 3 blizzard.
function Rules.update_weather(w, cfg, now, weather_type, temperature_c)
    local dt = 0
    if w.hours then dt = math.max(0, math.min(6, now - w.hours)) end
    w.hours = now
    w.weather = weather_type
    w.temperature_c = temperature_c
    local precipitating = weather_type == 2 or weather_type == 3
    local snowing = precipitating and (temperature_c == nil or temperature_c <= cfg.snow_below_c)
    local warm = temperature_c ~= nil and temperature_c > 0
    local half = warm and cfg.warm_settle_half_life_hours or cfg.settle_half_life_hours
    w.new_snow_cm = w.new_snow_cm * 0.5 ^ (dt / half)
    if snowing then
        local rate = weather_type == 3 and cfg.blizzard_cm_per_hour or cfg.snowfall_cm_per_hour
        w.new_snow_cm = w.new_snow_cm + rate * dt
    end
    if w.new_snow_cm < 0.05 then w.new_snow_cm = 0 end
    if weather_type == 3 then w.last_blizzard = now end
    -- Warming or rain on recent snow makes it wet and unstable.
    if w.new_snow_cm >= 15 and ((temperature_c and temperature_c >= cfg.warming_c) or (precipitating and not snowing)) then
        w.warm = true
    elseif temperature_c and temperature_c <= 0 then
        w.warm = false
    end
    return w
end

local DANGER_NAMES = {'low', 'moderate', 'considerable', 'high', 'very high'}
Rules.DANGER_NAMES = DANGER_NAMES

function Rules.danger(w, cfg)
    local level = 1
    for i, threshold in ipairs(cfg.new_snow_levels_cm) do
        if w.new_snow_cm >= threshold then level = i + 1 end
    end
    if w.weather == 3 and w.new_snow_cm >= cfg.new_snow_levels_cm[1] then level = level + 1 end
    if w.warm and w.new_snow_cm >= 15 then level = level + 1 end
    return math.max(1, math.min(5, level))
end

------------------------------------------------------------------------
-- Closure reasons
------------------------------------------------------------------------
-- Each reason has:
--   active(run, c) -> true when the run must close now
--   clear(run, c)  -> true when the reason no longer applies (hysteresis)
--   hold(c)        -> hours the reason must stay clear before reopening
--   text(run, c)   -> shown in the log and the patrol report
-- `c` is the context: {cfg, now, weather (w), danger, grooming, cover, temperature}

local function avalanche_pitch(cfg, danger)
    local best
    for level, pitch in pairs(cfg.avalanche_pitch_deg) do
        if danger >= level and (not best or pitch < best) then best = pitch end
    end
    return best
end

Rules.REASONS = {
    {
        id = 'avalanche',
        label = 'Avalanche danger',
        enabled = function(cfg) return cfg.avalanche end,
        active = function(run, c)
            local limit = avalanche_pitch(c.cfg, c.danger)
            return limit ~= nil and (run.pitch_deg or 0) >= limit
        end,
        clear = function(run, c)
            local limit = avalanche_pitch(c.cfg, c.danger)
            return limit == nil or (run.pitch_deg or 0) < limit
        end,
        hold = function(c) return c.cfg.avalanche_control_hours end,
        text = function(run, c)
            return string.format('avalanche danger %d (%s) on a %.0f° pitch', c.danger, DANGER_NAMES[c.danger], run.pitch_deg or 0)
        end,
    },
    {
        id = 'storm',
        label = 'Blizzard',
        enabled = function(cfg) return cfg.storm end,
        active = function(run, c)
            if c.weather.weather ~= 3 then return false end
            return (run.pitch_deg or 0) >= c.cfg.storm_pitch_deg
                or (run.difficulty ~= nil and run.difficulty >= c.cfg.storm_difficulty)
        end,
        clear = function(run, c) return c.weather.weather ~= 3 end,
        hold = function(c) return c.cfg.storm_clear_hours end,
        text = function() return 'blizzard: high wind and poor visibility' end,
    },
    {
        id = 'thin_cover',
        label = 'Thin snow',
        enabled = function(cfg) return cfg.thin_cover end,
        active = function(run, c) return c.cover ~= nil and c.cover < c.cfg.thin_close_cm end,
        -- Without a reading the patrol cannot justify the closure.
        clear = function(run, c) return c.cover == nil or c.cover >= c.cfg.thin_open_cm end,
        hold = function() return 0 end,
        text = function(run, c)
            return c.cover and ('thin snow cover (' .. (c.units or Rules.METRIC).depth(c.cover) .. ')') or 'thin snow cover'
        end,
    },
    {
        id = 'grooming',
        label = 'Grooming',
        enabled = function(cfg) return cfg.grooming end,
        active = function(run, c)
            return c.grooming and c.grooming_hours < c.cfg.grooming_max_hours
        end,
        clear = function(run, c) return not c.grooming or c.grooming_hours >= c.cfg.grooming_max_hours end,
        hold = function() return 0 end,
        text = function() return 'snowcat grooming in progress' end,
    },
    {
        id = 'cold',
        label = 'Extreme cold',
        enabled = function(cfg) return cfg.cold end,
        active = function(run, c) return c.temperature ~= nil and c.temperature <= c.cfg.cold_close_c end,
        clear = function(run, c) return c.temperature == nil or c.temperature >= c.cfg.cold_open_c end,
        hold = function() return 0 end,
        text = function(run, c) return 'extreme cold (' .. (c.units or Rules.METRIC).temperature(c.temperature or 0) .. ')' end,
    },
}
local REASON_BY_ID = {}
for _, reason in ipairs(Rules.REASONS) do REASON_BY_ID[reason.id] = reason end
Rules.REASON_BY_ID = REASON_BY_ID

-- Persistent memory for one run (kept by the caller).
function Rules.new_memory() return {owned = false, reasons = {}} end

local function describe(run, c, mem)
    local parts = {}
    for _, reason in ipairs(Rules.REASONS) do
        if mem.reasons[reason.id] then parts[#parts + 1] = reason.text(run, c) end
    end
    return table.concat(parts, '; ')
end
Rules.describe = describe

-- Decide what to do with one run.
--   run: {disabled=bool (native closed flag), pitch_deg, difficulty?}
--   c:   context (see above), c.enabled false means the patrol is off
-- Returns action ('close', 'open' or nil) and a message for the log.
function Rules.decide(run, c, mem)
    local now = c.now
    -- Which conditions may close this run: c.allowed is a set of reason ids chosen per run
    -- (nil = all, for callers that don't have per-run settings).
    local function on_for(reason)
        return reason.enabled(c.cfg) and (c.allowed == nil or c.allowed[reason.id] == true)
    end
    -- Track how long a grooming job has been running on this run.
    if c.grooming_flag ~= nil then
        if c.grooming_flag then mem.groom_since = mem.groom_since or now else mem.groom_since = nil end
    end
    c.grooming = c.grooming_flag and true or false
    c.grooming_hours = mem.groom_since and (now - mem.groom_since) or 0

    if mem.restored and not run.disabled then
        -- Remembered from an earlier session, but this save has the run open.
        mem.owned, mem.restored, mem.reasons = false, nil, {}
    end
    mem.restored = nil

    if not c.enabled then
        if mem.owned and run.disabled then
            mem.owned, mem.reasons = false, {}
            return 'open', 'reopened: patrol automation is off'
        end
        mem.owned, mem.reasons = false, {}
        return nil
    end

    if run.disabled and not mem.owned then
        -- Closed by the player (or another mod): never touch it.
        mem.reasons = {}
        return nil
    end

    if mem.owned and not run.disabled then
        -- The player reopened a run the patrol had closed.
        mem.owned, mem.reasons = false, {}
        mem.override_until = now + c.cfg.override_hours
        return nil, string.format('you reopened it; the patrol will leave it alone for %g game hours', c.cfg.override_hours)
    end

    if not run.disabled then
        if mem.override_until and now < mem.override_until then return nil end
        mem.override_until = nil
        local reasons = {}
        local any = false
        for _, reason in ipairs(Rules.REASONS) do
            if on_for(reason) and reason.active(run, c) then
                reasons[reason.id] = {since = now}
                any = true
            end
        end
        if not any then return nil end
        mem.owned, mem.closed_at, mem.reasons = true, now, reasons
        return 'close', 'closed: ' .. describe(run, c, mem)
    end

    -- Closed by the patrol: keep the reasons current, reopen when all clear.
    for _, reason in ipairs(Rules.REASONS) do
        local held = mem.reasons[reason.id]
        local on = on_for(reason)
        if on and reason.active(run, c) then
            if held then held.clear_since = nil else mem.reasons[reason.id] = {since = now} end
        elseif held then
            if not on then
                mem.reasons[reason.id] = nil
            elseif reason.clear(run, c) then
                held.clear_since = held.clear_since or now
                if now - held.clear_since >= reason.hold(c) then mem.reasons[reason.id] = nil end
            else
                held.clear_since = nil
            end
        end
    end
    if next(mem.reasons) == nil and now - (mem.closed_at or now) >= c.cfg.min_closed_hours then
        mem.owned, mem.closed_at = false, nil
        return 'open', 'reopened: conditions are safe again'
    end
    return nil
end

-- Hours until a patrol-closed run could reopen, or nil when a reason is still active.
function Rules.reopen_eta(run, c, mem)
    local wait = math.max(0, (mem.closed_at or c.now) + c.cfg.min_closed_hours - c.now)
    for id, held in pairs(mem.reasons) do
        local reason = REASON_BY_ID[id]
        if not held.clear_since then return nil end
        wait = math.max(wait, held.clear_since + reason.hold(c) - c.now)
    end
    return wait
end

return Rules
