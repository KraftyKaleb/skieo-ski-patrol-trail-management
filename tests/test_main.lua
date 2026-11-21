-- Loads Scripts/main.lua the way UE4SS does, against a fake Ski-E-O! world,
-- and plays through a storm, a restart, player overrides and grooming.
-- Self-contained: no game or loader code runs here.
local SCRIPTS = MODS_DIR .. 'ski-patrol/Scripts/'
local NATIVE_STATE = MODS_DIR .. 'Ski-E-O-Mod-ski-patrol-snow'   -- job, answer and status files (in LOCALAPPDATA)

------------------------------------------------------------------------
-- Fake game
------------------------------------------------------------------------
local logs = {}
print = function(s) logs[#logs + 1] = tostring(s):gsub('\n$', '') end
local function logged(pattern, from)
    for i = (from or 0) + 1, #logs do if logs[i]:find(pattern) then return logs[i] end end
end

local world = {IsValid = function() return true end, GetAddress = function() return 0x1000 end}
local function object(name, t)
    t.IsValid = function() return true end
    t.GetFullName = function() return 'SkiResortSimulator.' .. name .. ' /Game/Maps/Resort.' .. name .. '_0' end
    t.GetWorld = function() return world end
    t.GetAddress = function() return 0x2000 + #name end
    return t
end
package.preload.UEHelpers = function() return {GetWorld = function() return world end} end

local game = {hours = 8, rate = 1, paused = false, weather = 0, temperature = -5, grooming = {}}
local time = object('TimeSubsystem', {
    GetTotalGameHoursElapsed = function() return game.hours end,
    GetTimeOfDayHours = function() return game.hours % 24 end,
    GetTimeRate = function() return game.rate end,
    IsTimePaused = function() return game.paused end,
})
local weather = object('WeatherSubsystem', {
    GetWeatherType = function() return game.weather end,
    -- Colder with altitude (Z is cm).
    GetTemperatureAtLocation = function(_, p) return game.temperature - p.Z / 100 * 0.0065 end,
})
local grooming = object('GroomingSubsystem', {
    HasActiveGroomingEvent = function(_, id) return game.grooming[id] == true end,
})
local snow_cache = object('SnowStateCache', {})
local snow_class = {IsValid = function() return true end, GetAddress = function() return 0x9000 end}
StaticFindObject = function(path)
    if path:find('^/Script/UMG%.') then return {IsValid = function() return true end, umg = path:match('[^.]+$')} end
    assert(path == '/Script/SkiResortSimulator.SnowStateCache')
    return snow_class
end

-- Fake UMG, enough for the trail panel section.
FText = function(s) return {ToString = function() return s end, text = s} end
FName = function(s) return s end
local function widget(kind, t)
    t = t or {}
    t.kind, t.children, t.visibility = kind, t.children or {}, 0
    t.IsValid = function() return true end
    t.GetClass = function() return {GetFName = function() return {ToString = function() return kind end} end} end
    t.GetParent = function(self) return self.parent end
    t.Font = {Size = 10}
    local function add(self, child, at)
        child.parent = self
        table.insert(self.children, at or #self.children + 1, child)
        return {SetPadding = function() end, SetSize = function() end, SetVerticalAlignment = function() end}
    end
    t.AddChild, t.AddChildToVerticalBox, t.AddChildToHorizontalBox = add, add, add
    t.InsertChildAt = function(self, at, child) return add(self, child, at + 1) end
    t.GetChildIndex = function(self, child)
        for i, c in ipairs(self.children) do if c == child then return i - 1 end end
        return -1
    end
    t.SetText = function(self, text) self.text = text.text end
    t.GetText = function(self) return FText(self.text or '') end
    t.SetFont = function(self, f) self.Font = f end
    t.SetColorAndOpacity = function(self, c) self.color = c.SpecifiedColor end
    t.SetAutoWrapText = function() end
    t.SetJustification = function() end
    t.SetBackgroundColor = function(self, c) self.background = c end
    t.SetContent = function(self, child) self.content = child; child.parent = self end
    t.SetVisibility = function(self, v) self.visibility = v end
    t.IsVisible = function(self) return self.visibility ~= 1 and self.visibility ~= 2 end
    t.IsPressed = function(self) return self.pressed == true end
    t.IsHovered = function(self) return self.hovered == true end
    t.GetFullName = function() return kind .. ' /Game/UI/WBP_TrailEdit.' .. kind .. '_0' end
    return t
end
StaticConstructObject = function(class, outer)
    assert(outer and outer.kind == 'WidgetTree', 'widgets are made in the panel\'s WidgetTree')
    return widget(class.umg)
end
local frame_loops, new_object = {}, {}
LoopInGameThreadAfterFrames = function(n, fn) frame_loops[#frame_loops + 1] = fn end
NotifyOnNewObject = function(class, fn) new_object[class] = fn end
local function frames(n) for _ = 1, n or 1 do for _, fn in ipairs(frame_loops) do fn() end end end

-- Native trails: id -> info. Curves are quadratic Béziers in cm.
local function v(x, y, z) return {X = x * 100, Y = y * 100, Z = z * 100} end
local function straight(x0, z0, length, drop, y)
    local curves = {}
    local segments = 4
    for i = 1, segments do
        local a = (i - 1) / segments
        local b = i / segments
        local m = (a + b) / 2
        curves[i] = {
            StartPoint = v(x0 + length * a, y, z0 - drop * a),
            ControlPoint = v(x0 + length * m, y, z0 - drop * m),
            Endpoint = v(x0 + length * b, y, z0 - drop * b),
            CorridorWidth = 2000,
        }
    end
    return curves
end
local function wrap(value) return {get = function() return value end} end
-- AdditionalCurves crashes UE4SS 4.0 on CL8198 (null element property) the
-- moment anything iterates or indexes it, so any access here fails the test.
local touched_additional = false
local function array(items)
    local function touch() touched_additional = true; error('AdditionalCurves must not be read') end
    return {ForEach = touch, get = touch, __items = items}
end
local trails = {}
local function add_trail(id, name, curves, extra)
    local info = {TrailId = id, DisplayName = {ToString = function() return name end},
        bManuallyDisabled = false, Curve = curves[1], AdditionalCurves = array({table.unpack(curves, 2)})}
    for k, x in pairs(extra or {}) do info[k] = x end
    trails[id] = info
    return info
end
-- 300 m long runs with different drops (pitch = atan(drop/300)).
add_trail(1, 'Bunny Hill', straight(0, 2000, 300, 30, 0))                         -- ~6°
add_trail(2, 'Summit Couloir', straight(0, 2400, 300, 200, 100))                  -- ~34°
add_trail(3, 'Ridge', straight(0, 2300, 300, 130, 200), {Difficulty = 2})         -- ~23.4°, expert
add_trail(4, 'Closed By Me', straight(0, 2300, 300, 250, 300)).bManuallyDisabled = true
add_trail(5, 'Low Traverse', straight(0, 1600, 300, 40, 400))                     -- thin snow
local calls = {}
local trail_map = object('TrailMapSubsystem', {
    RegisteredTrails = {ForEach = function(_, fn)
        local ids = {}
        for id in pairs(trails) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do fn(wrap(id), wrap(trails[id])) end
    end},
    SetTrailDisabled = function(_, id, disabled)
        calls[#calls + 1] = {id = id, disabled = disabled}
        trails[id].bManuallyDisabled = disabled
    end,
})
local subsystems = {TimeSubsystem = time, WeatherSubsystem = weather, GroomingSubsystem = grooming,
    SnowStateCache = snow_cache, TrailMapSubsystem = trail_map}
FindAllOf = function(name) return subsystems[name] and {subsystems[name]} or nil end

-- The mod's own snow reader (Native/PatrolSnow.dll): reads the SKSN v2 job, writes results and a status line.
local function snow_depth(x, y) return y >= 40000 and 15 or 120 end
local jobs = 0
package.loadlib = function(path, symbol)
    assert(path == MODS_DIR .. 'ski-patrol/Native/PatrolSnow.dll', 'snow DLL path: ' .. path)
    assert(symbol == 'patrol_snow')
    return function()
        jobs = jobs + 1
        local f = assert(io.open(NATIVE_STATE .. '.job', 'rb'))
        local bytes = f:read('a'); f:close()
        local magic, version, owner, cls, count, reserved, offset = string.unpack('<c4I4I8I8I4I4', bytes)
        assert(magic == 'SKSN' and version == 2 and owner == snow_cache:GetAddress() and cls == 0x9000)
        assert(count >= 1 and count <= 64 and reserved == 0 and #bytes == 32 + count * 16, 'job size')
        local out = {}
        for _ = 1, count do
            local x, y
            x, y, offset = string.unpack('<dd', bytes, offset)
            out[#out + 1] = string.pack('<ffff', 1, snow_depth(x, y) - 10, 10, 260)
        end
        f = assert(io.open(NATIVE_STATE .. '.bin', 'wb'))
        f:write(table.concat(out)); f:close()
        f = assert(io.open(NATIVE_STATE .. '.status', 'wb')); f:write('ok'); f:close()
    end
end

-- UE4SS scheduling and input.
local queue = {}
ExecuteWithDelay = function(ms, fn) queue[#queue + 1] = {ms = ms, fn = fn} end
ExecuteInGameThread = function(fn) fn() end
Key = {F9 = 'F9'}
ModifierKey = {CONTROL = 'CONTROL'}
local keys = {}
RegisterKeyBind = function(key, a, b)
    if b then keys[key .. '+' .. a[1]] = b else keys[key] = a end
end
-- Z's Mod Loader: shared variables, and state kept outside the mod folder.
local shared = {}
ModRef = {GetSharedVariable = function(_, k) return shared[k] end, SetSharedVariable = function(_, k, v) shared[k] = v end}
local real_getenv = os.getenv
os.getenv = function(name) if name == 'LOCALAPPDATA' then return MODS_DIR:gsub('/$', '') end return real_getenv(name) end
local commands = {}
RegisterConsoleCommandHandler = function(name, fn) commands[name] = fn end

local function pump(n, hours)
    for _ = 1, n or 1 do
        local item = table.remove(queue, 1)
        assert(item and item.ms == 2000, 'patrol loop scheduled every 2 s')
        game.hours = game.hours + (hours or 0)
        item.fn()
        assert(#queue == 1, 'exactly one pending tick')
    end
end
local function closed(id) return trails[id].bManuallyDisabled end
local function start()
    queue, frame_loops = {}, {}
    for _, name in ipairs({'patrol_rules', 'patrol_native', 'patrol_store', 'patrol_panel'}) do package.loaded[name] = nil end
    local chunk = assert(loadfile(SCRIPTS .. 'main.lua'))
    return chunk()
end

------------------------------------------------------------------------
-- Scenario
------------------------------------------------------------------------
local Patrol = start()
assert(logged('%[Ski Patrol%] 0%.3%.2 loaded'), 'startup message')
assert(keys.F9 and keys['F9+CONTROL'] and commands.skipatrol, 'hotkeys and console command')
assert(shared['SkiEOMods.enabled.ski-patrol'] == true, 'live flag published under the folder name')

-- Calm morning: only the thin run closes.
pump(1)
assert(closed(5) and not closed(1) and not closed(2) and not closed(3), 'thin cover closes Low Traverse')
assert(logged('"Low Traverse" closed: thin snow cover %(15 cm%)'), 'closure logged')
assert(jobs >= 5, 'snow sampled through the loader DLL')
local profile = Patrol.runs['2@0,100'].profile
assert(math.abs(profile.pitch_deg - math.deg(math.atan(200 / 300))) < 0.5, 'couloir pitch')

-- Blizzard rolls in: exposed runs close, the easy run and the player's closure don't change.
game.weather, game.temperature = 3, -6
pump(1, 0.5)
assert(closed(3) and logged('"Ridge" closed: blizzard'), 'storm closes the expert ridge')
assert(closed(2) and logged('"Summit Couloir" closed: blizzard'), 'storm closes the steep couloir')
assert(Patrol.runs['2@0,100'].mem.reasons.avalanche == nil, 'no avalanche danger yet')
for _ = 1, 12 do pump(1, 0.5) end   -- 6 h of blizzard, about 24 cm
assert(Patrol.danger >= 3 and Patrol.runs['2@0,100'].mem.reasons.avalanche, 'avalanche danger added')
assert(not closed(1), 'bunny hill stays open')
for _, call in ipairs(calls) do assert(call.id ~= 4, 'player closure never touched') end
assert(closed(4))

-- The closures survive a restart of the game.
local state_file = MODS_DIR .. 'Ski-E-O-Mod-ski-patrol-patrol-closures.txt'
local f = assert(io.open(state_file)); local saved = f:read('a'); f:close()
assert(saved:find('^2@0,100\t') or saved:find('\n2@0,100\t'), 'couloir recorded')
assert(not saved:find('4@'), 'player closure not recorded')
logs = {}
Patrol = start()
pump(1, 0.5)
assert(Patrol.runs['2@0,100'].mem.owned and Patrol.runs['3@0,200'].mem.owned, 'ownership restored')

-- The storm clears and the snow settles: everything the patrol closed reopens.
game.weather, game.temperature = 0, -8
for _ = 1, 4 do pump(1, 0.5) end
assert(not closed(3) and logged('"Ridge" reopened'), 'ridge reopens after the storm')
assert(closed(2), 'couloir waits for the snow to settle')
for _ = 1, 60 do pump(1, 1) end
assert(not closed(2) and logged('"Summit Couloir" reopened'), 'couloir reopens')
assert(closed(5), 'thin run still closed')
assert(closed(4), 'player closure still closed')

-- More snow arrives on the thin run.
snow_depth = function() return 120 end
for _ = 1, 16 do pump(1, 0.1) end
assert(not closed(5), 'thin run reopens once covered')

-- Grooming closes a run while the snowcat works.
game.grooming[1] = true
pump(1, 0.1)
assert(closed(1) and logged('"Bunny Hill" closed: snowcat grooming'), 'grooming closure')
game.grooming[1] = nil
for _ = 1, 6 do pump(1, 0.1) end
assert(not closed(1), 'reopens after grooming')

-- The player reopens a patrol closure: the patrol leaves it alone.
game.weather = 3
for _ = 1, 2 do pump(1, 0.5) end
assert(closed(3))
trails[3].bManuallyDisabled = false
pump(1, 0.5)
assert(logged('"Ridge": you reopened it'), 'override noticed')
for _ = 1, 4 do pump(1, 0.5) end
assert(not closed(3), 'override respected')

-- The trail panel: a "Ski patrol" section right under the Open/Closed switch.
local edit_tab = widget('VerticalBox')
local switch_row = widget('HorizontalBox')
local switch_button = widget('CheckBox')
local switch_label = widget('TextBlock', {text = 'Open'})
edit_tab:AddChildToVerticalBox(switch_row)
switch_row:AddChildToHorizontalBox(switch_button)
switch_button:SetContent(switch_label)
edit_tab:AddChildToVerticalBox(widget('HorizontalBox'))
local name_label = widget('TextBlock', {text = 'Summit Couloir'})
local panel = widget('TrailEditWidget', {WidgetTree = widget('WidgetTree'), EditTabContent = edit_tab,
    OpenClosedToggleLabel = switch_label, TrailNameLabel = name_label})
assert(new_object['/Script/SkiResortSimulator.TrailEditWidget'], 'waits for the trail panel')
new_object['/Script/SkiResortSimulator.TrailEditWidget'](panel)
frames(30)
local section = edit_tab.children[2]
assert(section and section.kind == 'VerticalBox' and section.children[1].text == 'Ski patrol', 'section under the switch')
local note, button_row = section.children[2], section.children[3]
local button = button_row.children[1]
assert(closed(2), 'couloir closed by the blizzard')
assert(note.text:find('^Closed by ski patrol: .*blizzard'), 'reason shown: ' .. tostring(note.text))
assert(button_row.visibility == 0 and button.content.text == 'Reopen anyway', 'reopen button shown')

-- Reopen anyway: the run opens and the patrol leaves it alone.
button.pressed, button.hovered = true, true
frames(1)
button.pressed = false
frames(1)
assert(not closed(2), 'reopened from the panel')
assert(logged('"Summit Couloir" reopened by you from the trail panel'), 'reopen logged')
frames(15)
assert(note.text:find('^Open%. You reopened it'), 'override shown: ' .. tostring(note.text))
assert(button.content.text == 'Let the patrol close it again')
pump(1, 0.5)
assert(not closed(2), 'blizzard still on, but the override holds')

-- Hand it back: the patrol closes it again in the storm.
button.pressed = true; frames(1); button.pressed = false; frames(1)
pump(1, 0.5)
assert(closed(2), 'patrol closes it again once handed back')
frames(15)
assert(note.text:find('^Closed by ski patrol'), 'closed again')

-- A run you closed: no button.
name_label.text = 'Closed By Me'
frames(1)
assert(note.text:find('^Closed by you') and button_row.visibility == 1, 'player closure: no button')
-- The game's own closures: shown, no button (the patrol can't open them).
local status_label = widget('TextBlock', {text = 'Closed: not enough snow'})
panel.TrailStatusLabel = status_label
name_label.text = 'Bunny Hill'
frames(1)
assert(not closed(1), 'not a manual closure')
assert(note.text:find('^Closed by the game: not enough snow') and button_row.visibility == 1, 'no-snow closure: ' .. note.text)
status_label.text = 'Closed: avalanche danger'
frames(15)
assert(note.text:find('^Closed by the game: avalanche danger'), 'avalanche closure shown')
status_label.text = 'Closed by rope'
frames(15)
assert(note.text:find('^Closed by a rope'), 'rope closure shown')
status_label.text = 'Open'
frames(15)
assert(note.text:find('^Open%.'), 'open again: ' .. note.text)
assert(Patrol.game_closure('Closed by you') == nil and Patrol.game_closure('Open') == nil)
assert(Patrol.game_closure('[Closed: No Snow] ') and Patrol.game_closure('Closed: something new'):find('something new'))
-- A hidden panel takes no clicks.
panel.visibility = 1
button.pressed, button.hovered = true, true; frames(1); button.pressed = false; frames(1)
panel.visibility = 0
button.hovered = false

-- Pausing time stops the patrol.
game.paused = true
local before = #calls
game.temperature = -40
for _ = 1, 3 do pump(1, 0) end
assert(#calls == before, 'no changes while time is paused')
game.paused, game.temperature, game.weather = false, -8, 0

-- Ctrl+F9 pauses the patrol and hands back its runs; F9 writes a report.
game.grooming[1] = true
pump(1, 0.1)
assert(closed(1))
keys['F9+CONTROL']()
pump(1, 0.1)
assert(not closed(1) and logged('patrol paused'), 'paused patrol reopens its runs')
assert(closed(4), 'but not yours')
logs = {}
keys.F9()
pump(1, 0.1)
assert(logged('Report %(version 0%.3%.2%) %(patrol paused%)'), 'report header')
assert(logged('"Closed By Me": .* closed by you'), 'report lists player closure')
assert(logged('Snow cover readings: available'), 'report shows sampler')
local out = {}
commands.skipatrol('skipatrol on', {'on'}, {Log = function(_, s) out[#out + 1] = s end})
pump(1, 0.1)
assert(out[1]:find('report follows') and logged('patrol resumed'))
assert(closed(1) and logged('"Bunny Hill" closed: snowcat grooming'), 'resumed patrol acts again')
assert(commands.skipatrol('skipatrol x', {'x'}, nil) == true)

-- The Mods menu: a managed key press and the live switch.
shared['SkiEOMods.keybind.managed.ski-patrol.Pause or resume patrol'] = true
local before = #logs
keys['F9+CONTROL']()
pump(1, 0.1)
assert(not logged('patrol paused: reopening', before), 'own key steps aside while the loader manages it')
shared['SkiEOMods.keybind.request.ski-patrol.Pause or resume patrol'] = true
pump(1, 0.1)
assert(Patrol.enabled == false and shared['SkiEOMods.keybind.request.ski-patrol.Pause or resume patrol'] == nil, 'managed pause request')
shared['SkiEOMods.keybind.request.ski-patrol.Pause or resume patrol'] = true
pump(1, 0.1)
assert(Patrol.enabled == true, 'managed resume request')
shared['SkiEOMods.enabled.ski-patrol'] = false
pump(1, 0.1)
assert(Patrol.enabled == false, 'switched off in the Mods menu')
shared['SkiEOMods.enabled.ski-patrol'] = true
pump(1, 0.1)
assert(Patrol.enabled == true, 'switched back on')

-- A removed run is forgotten.
trails[1] = nil
pump(1, 0.1)
assert(Patrol.runs['1@0,0'] == nil and logged('"Bunny Hill" was removed while closed'))

-- Units follow the game's Measurement System setting (2 metric, 1 imperial, 0 automatic).
local settings = object('SkiResortGameUserSettings', {MeasurementSystem = 1})
subsystems.SkiResortGameUserSettings = settings
logs = {}
Patrol = start()
pump(1, 0.1)
keys.F9(); pump(1, 0.1)
assert(logged('showing imperial units %(the game\'s Measurement System setting%)'), 'imperial detected')
assert(logged('°F at the top') and logged('New snow %(model%): [%d%.]+ in%.'), 'report in °F and inches')
assert(logged('"Low Traverse": .* %d+ ft, cover [%d]+ in'), 'run length in ft, cover in inches')
settings.MeasurementSystem = 2
pump(1, 0.1); logs = {}
keys.F9(); pump(1, 0.1)
assert(logged('°C at the top') and logged('"Low Traverse": .* %d+ m, cover [%d]+ cm'), 'switches to metric live')
settings.MeasurementSystem = 0
pump(1, 0.1)
assert(Patrol.fmt.imperial == false, 'automatic without en-US culture is metric')
subsystems.SkiResortGameUserSettings = nil
assert(Patrol.cfg.units == 'auto')

-- A game build the reader doesn't recognise: it says so, and the patrol stops asking.
local asked = 0
package.loadlib = function()
    return function()
        asked = asked + 1
        local f = assert(io.open(NATIVE_STATE .. '.status', 'wb')); f:write('unsupported: layout\n'); f:close()
    end
end
logs = {}
Patrol = start()
pump(2, 0.1)
assert(asked == 1, 'the patrol asks an unsupported reader only once: ' .. asked)
keys.F9(); pump(1, 0.1)
assert(logged('thin%-cover rule is off: the snow reader doesn\'t recognise this game build'), 'report explains')
assert(not Patrol.runs['5@0,400'].cover, 'no cover reading without a supported reader')

-- Without the DLL the thin-cover rule just has no readings.
package.loadlib = function() return nil end
logs = {}
Patrol = start()
pump(1, 0.1)
keys.F9(); pump(1, 0.1)
assert(logged('Snow cover readings: unavailable'), 'graceful without sampler')

-- Main menu: no world, nothing happens and nothing fails.
world.GetAddress = function() return nil end
UEHELPERS_NONE = true
package.loaded.UEHelpers = nil
pump(1, 0.1)
assert(not logged('error:'), 'no errors logged')
assert(not touched_additional, 'AdditionalCurves was read (crashes the game on CL8198)')
