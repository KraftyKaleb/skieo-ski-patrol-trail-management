-- Decision rules: geometry, weather model, danger and every closure reason.
local Rules = require('patrol_rules')

local warnings = {}
local cfg = Rules.config({thin_close_cm = 20, bogus = 1, storm_pitch_deg = 'steep'}, function(m) warnings[#warnings + 1] = m end)
assert(cfg.thin_close_cm == 20 and cfg.thin_open_cm == 35, 'override merged')
assert(cfg.storm_pitch_deg == 22 and #warnings == 2, 'bad settings ignored with warnings')
cfg = Rules.config({})

-- Geometry: a straight 100 m run with a 20 m steep section (45°) in the middle.
local function p(x, z) return {x = x * 100, y = 0, z = z * 100} end
local curves = {
    {p(0, 100), p(20, 95), p(40, 90)},        -- 14°
    {p(40, 90), p(50, 80), p(60, 70)},        -- 45°
    {p(60, 70), p(80, 65), p(100, 60)},       -- 14°
}
local line = Rules.polyline(curves, 500)
local profile = Rules.profile(line, 20)
assert(math.abs(profile.length_m - 100) < 0.5, 'length ' .. profile.length_m)
assert(math.abs(profile.drop_m - 40) < 0.01, 'drop')
assert(math.abs(profile.pitch_deg - 45) < 1, 'steepest pitch ' .. profile.pitch_deg)
local gentle = Rules.profile(Rules.polyline({{p(0, 10), p(50, 5), p(100, 0)}}), 20)
assert(math.abs(gentle.pitch_deg - math.deg(math.atan(0.1))) < 0.2, 'gentle pitch')
local samples = Rules.sample_points(line, 25, 64)
assert(#samples == 5 and samples[2].x == 2500 and samples[5].x == 10000, 'samples every 25 m')
assert(#Rules.sample_points(Rules.polyline({{p(0, 0), p(2000, 0), p(4000, 0)}}), 25, 64) == 64, 'sample cap')

-- Cover uses a low percentile and needs most samples ready.
assert(Rules.cover({{total = 50}, {total = 10}, {total = 60}, {total = 70}, {total = 80}}, 10) == 10)
assert(Rules.cover({false, false, {total = 50}}, 10) == nil, 'too few readings')

-- Weather model: 10 hours of blizzard at -8 °C builds 40 cm of new snow.
local w = Rules.new_weather()
Rules.update_weather(w, cfg, 0, 3, -8)
for h = 1, 10 do Rules.update_weather(w, cfg, h, 3, -8) end
assert(w.new_snow_cm > 35 and w.new_snow_cm < 40.1, 'blizzard snowfall ' .. w.new_snow_cm)
assert(Rules.danger(w, cfg) == 4, 'considerable plus wind loading = 4, got ' .. Rules.danger(w, cfg))
Rules.update_weather(w, cfg, 11, 0, -8)
assert(Rules.danger(w, cfg) == 3, 'wind gone, still considerable')
-- Rain does not add snow; warming makes the snow wet.
local before = w.new_snow_cm
Rules.update_weather(w, cfg, 12, 2, 4)
assert(w.new_snow_cm < before and w.warm, 'rain on snow')
assert(Rules.danger(w, cfg) == 4, 'wet snow raises danger')
-- Settling: two days of sun bring danger down.
for h = 13, 72 do Rules.update_weather(w, cfg, h, 0, -5) end
assert(not w.warm and Rules.danger(w, cfg) <= 2, 'settled ' .. w.new_snow_cm)
-- A long gap (loading a save) is capped.
Rules.update_weather(w, cfg, 1000, 3, -5)
assert(w.new_snow_cm < 40, 'gap capped')

-- Closure decisions.
local function ctx(t)
    t.cfg = t.cfg or cfg
    t.weather = t.weather or {weather = 0, new_snow_cm = 0}
    t.danger = t.danger or 1
    if t.enabled == nil then t.enabled = true end
    return t
end
local steep = {disabled = false, pitch_deg = 32}
local easy = {disabled = false, pitch_deg = 12, difficulty = 0}

-- Avalanche: danger 3 closes 30°+ only.
local mem = Rules.new_memory()
local action, message = Rules.decide(steep, ctx({now = 0, danger = 3}), mem)
assert(action == 'close' and message:find('avalanche danger 3'), tostring(message))
steep.disabled = true
assert(Rules.decide(easy, ctx({now = 0, danger = 3}), Rules.new_memory()) == nil, 'easy run stays open')
-- Danger drops: needs 2 h of control work before reopening.
assert(Rules.decide(steep, ctx({now = 1, danger = 2}), mem) == nil)
assert(Rules.decide(steep, ctx({now = 2.5, danger = 2}), mem) == nil, 'control work')
action = Rules.decide(steep, ctx({now = 3.1, danger = 2}), mem)
assert(action == 'open' and not mem.owned, 'reopened after control')
steep.disabled = false
-- Danger rising again during control restarts the wait.
mem = Rules.new_memory()
Rules.decide(steep, ctx({now = 0, danger = 4}), mem); steep.disabled = true
Rules.decide(steep, ctx({now = 1, danger = 2}), mem)
Rules.decide(steep, ctx({now = 2, danger = 3}), mem)
assert(Rules.decide(steep, ctx({now = 3.5, danger = 2}), mem) == nil, 'wait restarted')
assert(Rules.reopen_eta(steep, ctx({now = 3.5, danger = 2}), mem) > 1.9)
assert(Rules.decide(steep, ctx({now = 5.6, danger = 2}), mem) == 'open')
steep.disabled = false

-- Storm closes steep or expert runs, reopens an hour after the blizzard.
local expert = {disabled = false, pitch_deg = 15, difficulty = 2}
mem = Rules.new_memory()
local blizzard = {weather = 3, new_snow_cm = 0}
assert(Rules.decide(expert, ctx({now = 0, weather = blizzard}), mem) == 'close'); expert.disabled = true
assert(Rules.decide(easy, ctx({now = 0, weather = blizzard}), Rules.new_memory()) == nil, 'easy run open in storm')
assert(Rules.decide(expert, ctx({now = 0.8, weather = {weather = 1, new_snow_cm = 0}}), mem) == nil)
assert(Rules.decide(expert, ctx({now = 1.5, weather = {weather = 1, new_snow_cm = 0}}), mem) == nil)
assert(Rules.decide(expert, ctx({now = 1.9, weather = {weather = 1, new_snow_cm = 0}}), mem) == 'open')
expert.disabled = false

-- Thin cover with hysteresis.
local run = {disabled = false, pitch_deg = 10}
mem = Rules.new_memory()
assert(Rules.decide(run, ctx({now = 0, cover = 30}), mem) == nil)
assert(Rules.decide(run, ctx({now = 0, cover = 18}), mem) == 'close'); run.disabled = true
assert(Rules.decide(run, ctx({now = 1, cover = 30}), mem) == nil, 'between thresholds stays closed')
assert(Rules.decide(run, ctx({now = 2, cover = 36}), mem) == 'open'); run.disabled = false

-- Grooming closes while the snowcat works, but not forever.
mem = Rules.new_memory()
assert(Rules.decide(run, ctx({now = 0, grooming_flag = true}), mem) == 'close'); run.disabled = true
assert(Rules.decide(run, ctx({now = 0.6, grooming_flag = false}), mem) == 'open'); run.disabled = false
mem = Rules.new_memory()
assert(Rules.decide(run, ctx({now = 10, grooming_flag = true}), mem) == 'close'); run.disabled = true
assert(Rules.decide(run, ctx({now = 14.5, grooming_flag = true}), mem) == 'open', 'endless grooming ignored'); run.disabled = false
assert(Rules.decide(run, ctx({now = 15, grooming_flag = true}), mem) == nil, 'and not closed again')

-- Extreme cold.
mem = Rules.new_memory()
assert(Rules.decide(run, ctx({now = 0, temperature = -31}), mem) == 'close'); run.disabled = true
assert(Rules.decide(run, ctx({now = 1, temperature = -28}), mem) == nil)
assert(Rules.decide(run, ctx({now = 1, temperature = -25}), mem) == 'open'); run.disabled = false

-- Minimum closed time.
mem = Rules.new_memory()
Rules.decide(run, ctx({now = 0, temperature = -31}), mem); run.disabled = true
assert(Rules.decide(run, ctx({now = 0.1, temperature = -20}), mem) == nil, 'min closed time')
assert(Rules.decide(run, ctx({now = 0.6, temperature = -20}), mem) == 'open'); run.disabled = false

-- The player's own closures are never touched.
local mine = {disabled = true, pitch_deg = 40}
mem = Rules.new_memory()
assert(Rules.decide(mine, ctx({now = 0, danger = 5}), mem) == nil and not mem.owned)
assert(Rules.decide(mine, ctx({now = 1, danger = 1}), mem) == nil)

-- The player reopening a patrol closure overrides the patrol for a day.
mem = Rules.new_memory()
assert(Rules.decide(steep, ctx({now = 0, danger = 4}), mem) == 'close')
steep.disabled = false   -- player reopened it
action, message = Rules.decide(steep, ctx({now = 1, danger = 4}), mem)
assert(action == nil and message:find('leave it alone'), 'override noticed')
assert(Rules.decide(steep, ctx({now = 10, danger = 4}), mem) == nil, 'override holds')
assert(Rules.decide(steep, ctx({now = 25.5, danger = 4}), mem) == 'close', 'override expires')

-- Turning the patrol off reopens only its own closures.
local c_off = ctx({now = 30, danger = 4, enabled = false})
steep.disabled = true
assert(Rules.decide(steep, c_off, mem) == 'open' and not mem.owned)
assert(Rules.decide(mine, c_off, Rules.new_memory()) == nil)

-- A closure restored from an earlier session but open in this save is dropped quietly.
mem = {owned = true, restored = true, reasons = {storm = {since = 0}}, closed_at = 0}
action, message = Rules.decide({disabled = false, pitch_deg = 5}, ctx({now = 3}), mem)
assert(action == nil and message == nil and not mem.owned and not mem.override_until)

-- Disabled rules don't close, and drop held reasons.
local no_cold = Rules.config({cold = false})
mem = Rules.new_memory()
assert(Rules.decide(run, ctx({cfg = no_cold, now = 0, temperature = -40}), mem) == nil)

-- Units for messages
assert(Rules.IMPERIAL.temperature(-30) == '-22 °F' and Rules.IMPERIAL.depth(25.4) == '10 in' and Rules.IMPERIAL.length(100) == '328 ft')
assert(Rules.METRIC.temperature(-30) == '-30 °C' and Rules.METRIC.depth(25) == '25 cm' and Rules.METRIC.length(300) == '300 m')
assert(Rules.units('imperial').imperial and not Rules.units('metric').imperial and not Rules.units(nil).imperial)
local warned = {}
assert(Rules.config({units = 'furlongs'}, function(m) warned[#warned + 1] = m end).units == 'auto' and #warned == 1, 'bad units setting')

-- Per-run switches: a condition only counts when the run's `allowed` set includes it.
do
    local m = Rules.new_memory()
    assert(Rules.decide(run, ctx({now = 0, temperature = -40, allowed = {}}), m) == nil, 'nothing switched on: nothing closes')
    assert(Rules.decide(run, ctx({now = 0, temperature = -40, allowed = {grooming = true}}), m) == nil, 'only other conditions on')
    local a = Rules.decide(run, ctx({now = 0, temperature = -40, allowed = {cold = true}}), m)
    assert(a == 'close', 'cold switched on closes')
end
