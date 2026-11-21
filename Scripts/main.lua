-- Ski patrol for Ski-E-O! (UE4SS mod, loaded at game startup).
-- Every couple of seconds the patrol checks each run against the weather,
-- avalanche danger, snow cover, grooming and cold, closes runs that are unsafe
-- and reopens them when conditions recover. Runs you close yourself are never
-- touched, and a run you reopen is left alone for a while.
--
-- F9 or `skipatrol` in the UE4SS console: write a patrol report to the log.
-- Ctrl+F9 or `skipatrol off` / `skipatrol on`: pause or resume the patrol.
local Rules = require('patrol_rules')
local Native = require('patrol_native')
local Store = require('patrol_store')
local Support = require('modsupport')

local VERSION = '0.4.0'
local source = debug.getinfo(1, 'S').source:match('^@(.*)$') or ''
local SCRIPTS = source:match('^(.*[/\\])[^/\\]+$') or './'
local ROOT = SCRIPTS:match('^(.*[/\\])Scripts[/\\]$') or SCRIPTS
local Mod = Support.new(SCRIPTS)
-- Saved outside the mod folder (see modsupport.lua); 0.2.2 and older kept it in the mod folder.
local STATE_FILE = Mod.state_file('patrol-closures.txt')
local LEGACY_STATE_FILE = Mod.legacy_file('patrol-closures.txt')
-- Which conditions may close each run (chosen in the trail panel; all off until you switch them on).
local SETTINGS_FILE = Mod.state_file('run-settings.txt')

local Patrol = {
    runs = {},          -- per store key: {trail, mem, profile, samples, cover, next_cover}
    events = {},        -- recent log lines for the report
    flags = {},
    tick = 0,
    settings = {},      -- per store key: {reason id = true}, the conditions that may close that run
}

local function log(message)
    local line = string.format('%s %s', Patrol.cfg and Patrol.cfg.log_prefix or '[Ski Patrol]', message)
    print(line .. '\n')
    return line
end
Patrol.log = log

local function remember(message)
    local stamp = Patrol.clock and string.format('day %d %02d:%02d', math.floor(Patrol.clock.hours / 24) + 1,
        math.floor((Patrol.clock.hour or 0)), math.floor(((Patrol.clock.hour or 0) % 1) * 60)) or ''
    table.insert(Patrol.events, 1, stamp .. '  ' .. message)
    while #Patrol.events > 12 do table.remove(Patrol.events) end
    log(message)
end

function Patrol.load_config()
    local user = {}
    local chunk, failure = loadfile(SCRIPTS .. 'config.lua', 't', {})
    if chunk then
        local ok, result = pcall(chunk)
        if ok and type(result) == 'table' then user = result
        else log('config.lua ignored: ' .. tostring(ok and 'it must return a table' or result)) end
    elseif failure and not tostring(failure):find('No such file', 1, true) and not tostring(failure):find('cannot open', 1, true) then
        log('config.lua ignored: ' .. tostring(failure))
    end
    Patrol.cfg = Rules.config(user, function(message) log('config.lua: ' .. message) end)
    if Patrol.enabled == nil then Patrol.enabled = Patrol.cfg.enabled end
    return Patrol.cfg
end

local function name_of(run)
    local name = run.trail.name
    if not name or name == '' then name = 'Run ' .. run.trail.id end
    return '"' .. name .. '"'
end

local function signature(trail)
    local parts = {}
    for _, c in ipairs(trail.curves) do
        for _, p in ipairs(c) do parts[#parts + 1] = string.format('%d,%d,%d', p.x // 50, p.y // 50, p.z // 50) end
    end
    return table.concat(parts, ';')
end

local function prepare(run, trail)
    local sig = signature(trail)
    if run.signature ~= sig then
        run.signature = sig
        local line = Rules.polyline(trail.curves, 500)
        run.profile = Rules.profile(line, Patrol.cfg.pitch_window_m)
        run.samples = Rules.sample_points(line, Patrol.cfg.snow_sample_spacing_m, 64)
        run.top = line[1]
        for _, p in ipairs(line) do if p.z > run.top.z then run.top = p end end
        run.cover, run.next_cover = nil, Patrol.tick
    end
    run.trail = trail
    trail.pitch_deg = run.profile.pitch_deg
end

local function world_changed()
    Patrol.runs = {}
    Patrol.weather = Rules.new_weather()
    Patrol.events = {}
    Patrol.last_danger = nil
    Patrol.records = Store.load(STATE_FILE)
    Patrol.settings = Patrol.load_settings()
    local current = io.open(STATE_FILE, 'r')
    if current then current:close() else Patrol.records = Store.load(LEGACY_STATE_FILE) end   -- first start after 0.2.2
end

local function save_records()
    if Patrol.dirty then
        Patrol.dirty = false
        if not Store.save(STATE_FILE, Patrol.records) then log('could not write ' .. STATE_FILE) end
    end
end

local function record(key, mem)
    local before = Patrol.records[key]
    if mem.owned then
        local ids = {}
        for id in pairs(mem.reasons) do ids[#ids + 1] = id end
        table.sort(ids)
        local closed = mem.closed_at
        if not before or before.closed_at ~= closed or table.concat(before.reasons, ',') ~= table.concat(ids, ',') then
            Patrol.records[key] = {closed_at = closed, reasons = ids}
            Patrol.dirty = true
        end
    elseif before then
        Patrol.records[key] = nil
        Patrol.dirty = true
    end
end

-- Per-run conditions. Stored like the closure records: key, nothing, comma-separated reason ids.
function Patrol.load_settings()
    local settings = {}
    for key, record in pairs(Store.load(SETTINGS_FILE)) do
        local set, any = {}, false
        for _, id in ipairs(record.reasons) do
            if Rules.REASON_BY_ID[id] then set[id], any = true, true end
        end
        if any then settings[key] = set end
    end
    return settings
end

local function save_settings()
    local records = {}
    for key, set in pairs(Patrol.settings) do
        local ids = {}
        for id in pairs(set) do ids[#ids + 1] = id end
        table.sort(ids)
        if #ids > 0 then records[key] = {reasons = ids} end
    end
    if not Store.save(SETTINGS_FILE, records) then log('could not write ' .. tostring(SETTINGS_FILE)) end
end

-- Switch one condition on or off for one run. Changing a run's settings also ends the
-- 24-hour break after you reopened it: the new settings are your latest word on it.
function Patrol.set_allowed(key, id, on)
    local run = Patrol.runs[key]
    if not Rules.REASON_BY_ID[id] or not run then return false end
    local set = Patrol.settings[key] or {}
    set[id] = on and true or nil
    Patrol.settings[key] = next(set) and set or nil
    run.mem.override_until = nil
    save_settings()
    remember(string.format('%s: %s %s', name_of(run), Rules.REASON_BY_ID[id].label, on and 'may now close this run' or 'no longer closes this run'))
    return true
end

local function allowed_text(key)
    local set, names = Patrol.settings[key] or {}, {}
    for _, reason in ipairs(Rules.REASONS) do if set[reason.id] then names[#names + 1] = reason.label:lower() end end
    return #names > 0 and table.concat(names, ', ') or 'nothing'
end

local function context(run, now, temperature, grooming)
    return {
        allowed = Patrol.settings[run.key] or {},
        cfg = Patrol.cfg, now = now, weather = Patrol.weather, danger = Patrol.danger,
        cover = run.cover, temperature = temperature, enabled = Patrol.enabled,
        grooming_flag = grooming, units = Patrol.fmt,
    }
end

function Patrol.report()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    local w = Patrol.weather or Rules.new_weather()
    add(string.format('Report (version %s)%s', VERSION, Patrol.enabled and '' or ' (patrol paused)'))
    if not Patrol.clock then
        add('  No resort is loaded.')
    else
        local names = {[0] = 'sun', 'clouds', 'precipitation', 'blizzard'}
        local fmt = Patrol.fmt or Rules.METRIC
        add(string.format('  Weather: %s, %s at the top. New snow (model): %s. Avalanche danger: %d (%s).',
            names[w.weather or -1] or 'unknown', w.temperature_c and fmt.temperature(w.temperature_c) or 'temperature unknown',
            fmt.depth(w.new_snow_cm), Patrol.danger or 1, Rules.DANGER_NAMES[Patrol.danger or 1]))
        add('  Snow cover readings: ' .. (Native.snow_available() and ('available (' .. tostring(Native.snow_detail()) .. ')')
            or ('unavailable, thin-cover rule is off: ' .. tostring(Native.snow_problem()))))
        local keys = {}
        for key in pairs(Patrol.runs) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return Patrol.runs[a].trail.id < Patrol.runs[b].trail.id end)
        for _, key in ipairs(keys) do
            local run = Patrol.runs[key]
            local mem = run.mem
            local status
            if run.trail.disabled and mem.owned then
                local c = context(run, Patrol.clock.hours, run.temperature, mem.groom_since ~= nil)
                c.grooming, c.grooming_hours = mem.groom_since ~= nil, mem.groom_since and Patrol.clock.hours - mem.groom_since or 0
                local eta = Rules.reopen_eta(run.trail, c, mem)
                status = 'CLOSED by patrol: ' .. Rules.describe(run.trail, c, mem)
                    .. (eta and string.format(' (reopens in about %.1f h)', eta) or '')
            elseif run.trail.disabled then
                status = 'closed by you'
            elseif mem.override_until and mem.override_until > Patrol.clock.hours then
                status = string.format('open, patrol overridden for %.1f h', mem.override_until - Patrol.clock.hours)
            else
                status = 'open'
            end
            add(string.format('  %s: %.0f° steepest, %s, cover %s. Auto-closes for: %s. %s', name_of(run), run.profile.pitch_deg,
                fmt.length(run.profile.length_m), run.cover and fmt.depth(run.cover) or '?', allowed_text(key), status))
        end
        if #keys == 0 then add('  No runs yet.') end
        if #Patrol.events > 0 then
            add('  Recent patrol actions:')
            for _, e in ipairs(Patrol.events) do add('    ' .. e) end
        end
    end
    for _, s in ipairs(lines) do log(s) end
    return lines
end

function Patrol.step()
    Patrol.tick = Patrol.tick + 1
    local flags = Patrol.flags
    Patrol.flags = {}
    if flags.reload then Patrol.load_config(); log('settings reloaded') end
    if flags.enable ~= nil and flags.enable ~= Patrol.enabled then
        Patrol.enabled = flags.enable
        remember(Patrol.enabled and 'patrol resumed' or 'patrol paused: reopening the runs it closed')
    end

    local key = Native.world_key()
    if not key then Patrol.clock = nil; if flags.report then Patrol.report() end; return end
    if key ~= Patrol.world then Patrol.world = key; world_changed() end

    local clock = Native.clock()
    local trails = clock and Native.trails()
    if not clock or not trails then Patrol.clock = nil; if flags.report then Patrol.report() end; return end
    Patrol.clock = clock
    local system = Patrol.cfg.units ~= 'auto' and Patrol.cfg.units or Native.measurement_system()
    if system ~= Patrol.system then
        Patrol.system = system
        Patrol.fmt = Rules.units(system)
        log('showing ' .. (Patrol.fmt.imperial and 'imperial' or 'metric') .. ' units'
            .. (Patrol.cfg.units ~= 'auto' and ' (config.lua)' or system and ' (the game\'s Measurement System setting)' or ' (setting unreadable)'))
    end
    -- While time is stopped nothing changes on the mountain, except that a
    -- paused patrol still hands back its runs.
    if clock.paused and flags.enable == nil then
        if flags.report then Patrol.report() end
        return
    end
    local now = clock.hours

    -- Weather at the highest point of the resort, where snow falls first.
    local summit
    local seen = {}
    for _, trail in ipairs(trails) do
        local k = Store.key(trail)
        seen[k] = true
        local run = Patrol.runs[k]
        if not run then
            run = {mem = Rules.new_memory(), key = k}
            Patrol.runs[k] = run
            local saved = Patrol.records[k]
            if saved and trail.disabled then
                run.mem.owned, run.mem.restored, run.mem.closed_at = true, true, saved.closed_at or now
                for _, id in ipairs(saved.reasons) do
                    if Rules.REASON_BY_ID[id] then run.mem.reasons[id] = {since = run.mem.closed_at} end
                end
            end
        end
        prepare(run, trail)
        if not summit or run.top.z > summit.z then summit = run.top end
    end
    for k, run in pairs(Patrol.runs) do
        if not seen[k] then
            Patrol.runs[k] = nil
            if Patrol.settings[k] then Patrol.settings[k] = nil; save_settings() end
            if Patrol.records[k] then Patrol.records[k] = nil; Patrol.dirty = true end
            if run.mem.owned then remember(name_of(run) .. ' was removed while closed') end
        end
    end
    if not summit then save_records(); if flags.report then Patrol.report() end; return end

    local weather_type, summit_temperature = Native.weather(summit.x, summit.y, summit.z)
    if not Patrol.weather.hours then Store.restore_weather(Patrol.records['~weather'], Patrol.weather, now) end
    Rules.update_weather(Patrol.weather, Patrol.cfg, now, weather_type, summit_temperature)
    -- Save the snow model about once per game hour.
    local saved = Patrol.records['~weather']
    if not saved or not saved.closed_at or math.abs(now - saved.closed_at) >= 1 then
        Patrol.records['~weather'] = Store.weather_record(Patrol.weather)
        Patrol.dirty = true
    end
    Patrol.danger = Rules.danger(Patrol.weather, Patrol.cfg)
    if Patrol.last_danger and Patrol.danger ~= Patrol.last_danger then
        remember(string.format('avalanche danger is now %d (%s)', Patrol.danger, Rules.DANGER_NAMES[Patrol.danger]))
    end
    Patrol.last_danger = Patrol.danger

    local refresh = math.max(1, math.floor(Patrol.cfg.cover_refresh_seconds * 1000 / Patrol.cfg.tick_ms + 0.5))
    local index = 0
    for _, trail in ipairs(trails) do
        index = index + 1
        local k = Store.key(trail)
        local run = Patrol.runs[k]
        -- Spread snow sampling over time: a few runs per tick.
        if Patrol.cfg.thin_cover and Patrol.tick >= (run.next_cover or 0) then
            local rows = Native.sample_snow(run.samples)
            run.cover = rows and Rules.cover(rows, Patrol.cfg.thin_percentile) or nil
            run.next_cover = Patrol.tick + refresh + (index % refresh)
        elseif not Patrol.cfg.thin_cover then
            run.cover = nil
        end
        local _, temperature = Native.weather(run.top.x, run.top.y, run.top.z)
        run.temperature = temperature or summit_temperature
        local grooming = Patrol.cfg.grooming and Native.grooming(trail.id) or false
        local c = context(run, now, run.temperature, grooming)
        local action, message = Rules.decide(trail, c, run.mem)
        if action then
            local ok, failure = Native.set_disabled(trail.id, action == 'close')
            if ok then
                trail.disabled = action == 'close'
                remember(name_of(run) .. ' ' .. message)
            else
                log(string.format('could not %s %s: %s', action, name_of(run), tostring(failure)))
                if action == 'close' then run.mem.owned, run.mem.reasons = false, {} else run.mem.owned = true end
            end
        elseif message then
            remember(name_of(run) .. ': ' .. message)
        end
        record(k, run.mem)
    end
    save_records()
    if flags.report then Patrol.report() end
end

------------------------------------------------------------------------
-- Trail panel support: status of one run and the player's buttons
------------------------------------------------------------------------
-- The game's trail panel shows the run's name, so runs are found by name.
local function runs_named(name)
    local found = {}
    for key, run in pairs(Patrol.runs) do
        if run.trail.name == name then found[#found + 1] = {key = key, run = run} end
    end
    return found
end

local function hours_text(h)
    if h < 1 then return string.format('%d min', math.max(1, math.floor(h * 60 + 0.5))) end
    return string.format('%.1f h', h)
end

-- The game itself closes runs too (since CL8198): "Closed: not enough snow",
-- "Closed: avalanche danger", "Closed by rope". Those aren't the native
-- manual switch the patrol uses, so the patrol can't open them; the panel
-- just explains them. `game_status` is the panel's own status line.
local GAME_CLOSURES = {
    {pattern = 'snow', text = 'Closed by the game: not enough snow on the run. It reopens by itself once there is '
        .. 'enough snow (snowfall or snowmaking). The ski patrol can\'t reopen it.'},
    {pattern = 'avalanche', text = 'Closed by the game: avalanche danger. It reopens by itself when the danger '
        .. 'passes. The ski patrol can\'t reopen it.'},
    {pattern = 'rope', text = 'Closed by a rope. Remove the rope to reopen the run.'},
}
local function game_closure(game_status)
    if type(game_status) ~= 'string' then return nil end
    local s = game_status:lower()
    if not s:find('^%s*%[?closed') or s:find('by you', 1, true) then return nil end
    for _, closure in ipairs(GAME_CLOSURES) do
        if s:find(closure.pattern, 1, true) then return closure.text end
    end
    return 'Closed by the game (' .. game_status:gsub('^%s+', ''):gsub('%s+$', '') .. '). The ski patrol can\'t reopen it.'
end
Patrol.game_closure = game_closure

-- What the panel shows for the run called `name`:
-- {text, tone ('closed'|'open'|'you'|'info'), key (the run's store key, nil when there is no single run),
--  allowed (set of reason ids that may close it)}
-- The game's own Open/Closed switch is the only open/close button: the patrol notices when you
-- reopen one of its runs and leaves it alone.
function Patrol.panel_status(name, game_status)
    local found = runs_named(name or '')
    local key = #found == 1 and found[1].key or nil
    local function result(text, tone)
        return {text = text, tone = tone, key = key, allowed = key and Patrol.settings[key] or {}}
    end
    local game = game_closure(game_status)
    if game and not (#found == 1 and found[1].run.trail.disabled) then return result(game, 'closed') end
    if not Patrol.clock then return result('The ski patrol starts once the resort is running.', 'info') end
    if #found == 0 then return result('The ski patrol hasn\'t looked at this run yet.', 'info') end
    if #found > 1 then
        return result('Two runs are called ' .. name .. '. Rename one to set up the patrol for it.', 'info')
    end
    local run = found[1].run
    local mem, now = run.mem, Patrol.clock.hours
    if run.trail.disabled and mem.owned then
        local c = context(run, now, run.temperature, mem.groom_since ~= nil)
        c.grooming, c.grooming_hours = mem.groom_since ~= nil, mem.groom_since and now - mem.groom_since or 0
        local why = Rules.describe(run.trail, c, mem)
        if why == '' then why = 'conditions are being checked' end
        local eta = Rules.reopen_eta(run.trail, c, mem)
        local when = eta and ('It reopens by itself in about ' .. hours_text(eta) .. ' of game time.')
            or 'It stays closed while this lasts.'
        return result(string.format('Closed by ski patrol: %s. %s Use the Open/Closed switch above to reopen it now; the patrol then leaves it alone for %g game hours.',
            why, when, Patrol.cfg.override_hours), 'closed')
    elseif run.trail.disabled then
        return result('Closed by you. The ski patrol never reopens runs you close.', 'you')
    elseif not Patrol.enabled then
        return result('Open. The ski patrol is paused (Ctrl+F9 resumes it).', 'info')
    elseif mem.override_until and mem.override_until > now then
        return result(string.format('Open. You reopened it, so the ski patrol leaves it alone for another %s. Changing a condition below hands it back now.',
            hours_text(mem.override_until - now)), 'you')
    end
    local set = Patrol.settings[key] or {}
    if next(set) == nil then
        return result('Open. The ski patrol is not set to close this run. Switch on the conditions below that should close it.', 'info')
    end
    local note = ''
    if set.thin_cover and Patrol.cfg.thin_cover and not Native.snow_available() then
        note = ' Thin snow can\'t be checked: ' .. tostring(Native.snow_problem()) .. '.'
    end
    return result(string.format('Open. The ski patrol is watching it (%.0f° at its steepest).',
        run.profile and run.profile.pitch_deg or 0) .. note, 'open')
end

local function guarded_step()
    local ok, failure = pcall(Patrol.step)
    if not ok then
        Patrol.failures = (Patrol.failures or 0) + 1
        if Patrol.failures <= 5 then log('error: ' .. tostring(failure)) end
    end
end
Patrol.guarded_step = guarded_step

-- The Mods menu can switch the mod off and on without a restart, and the loader
-- reports managed key presses as requests; both only set flags for the next step.
local function poll_loader()
    Mod.poll(function(live)
        Patrol.flags.enable = live and Patrol.cfg.enabled or false
        Patrol.flags.report = true
    end, {
        ['Write patrol report'] = function() Patrol.flags.report = true end,
        ['Pause or resume patrol'] = function()
            Patrol.flags.enable = not Patrol.enabled
            Patrol.flags.report = true
        end,
    })
end

local function schedule()
    ExecuteWithDelay(Patrol.cfg.tick_ms, function()
        ExecuteInGameThread(function() poll_loader(); guarded_step() end)
        schedule()
    end)
end

-- Key and console callbacks only set flags; the game-thread tick acts on them.
local function command(parameters)
    local word = parameters and parameters[1] and tostring(parameters[1]):lower() or 'report'
    if word == 'on' then Patrol.flags.enable = true
    elseif word == 'off' then Patrol.flags.enable = false
    elseif word == 'reload' then Patrol.flags.reload = true
    elseif word == 'report' then Patrol.flags.report = true
    else return false end
    Patrol.flags.report = true
    return true
end
Patrol.command = command

function Patrol.install()
    Patrol.load_config()
    if type(RegisterConsoleCommandHandler) == 'function' then
        RegisterConsoleCommandHandler('skipatrol', function(_, parameters, output)
            local ok = command(parameters)
            local reply = ok and 'Ski patrol: report follows in the UE4SS log' or 'Usage: skipatrol [report|on|off|reload]'
            if output then pcall(function() output:Log(reply) end) end
            return true
        end)
    end
    Mod.start()
    Mod.bind('F9', nil, 'Write patrol report', function() Patrol.flags.report = true end)
    Mod.bind('F9', 'CONTROL', 'Pause or resume patrol', function()
        Patrol.flags.enable = not Patrol.enabled
        Patrol.flags.report = true
    end)
    schedule()
    log(string.format('%s loaded%s. F9 for a report, Ctrl+F9 to pause or resume.', VERSION,
        Patrol.enabled and '' or ' (paused by config.lua)'))
end

Patrol.reasons = Rules.REASONS
Patrol.install()

-- The "Ski patrol" section in the game's trail panel. Optional: if anything
-- about the panel is different in this game build, the patrol still runs.
if Patrol.cfg.trail_panel then
    local ok, Panel = pcall(require, 'patrol_panel')
    if ok then
        local started, failure = pcall(Panel.install, Patrol)
        if not started then log('trail panel unavailable: ' .. tostring(failure)) end
        Patrol.panel = Panel
    else
        log('trail panel unavailable: ' .. tostring(Panel))
    end
end
return Patrol
