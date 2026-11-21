***AI GENERATED CONTENT DISCLAIMER: I've had fun playing Ski-E-O so far, and this project is a fun test of claude code's skill. I am in no way fully confident that the mod will be free of all bugs or security issues, so use it at your own risk. I (human Kaleb) have tested the project against a local save and have not observed anything particularly worrisome. Have fun and let me know if you find any issues :)***

# Ski patrol (`ski-patrol`)

A Ski-E-O! mod that adds a ski patrol trail management function. The patrol watches the weather, the snow and
the snowcats, closes runs when they're unsafe and reopens them when conditions
recover. It works on every resort, including the stock maps.

## Screenshots
<img width="531" height="248" alt="image" src="https://github.com/user-attachments/assets/50c30023-4bad-4b98-a18e-65daa905a9a0" />
<img width="525" height="305" alt="image" src="https://github.com/user-attachments/assets/87642b49-8d59-49c9-a2b8-611915187838" />

## What it does

The patrol checks every run about every two seconds of real time, while game time
is running. It closes a run for any of these reasons and reopens it once all of
them have cleared (and it has been closed for at least half a game hour):

| Reason | Closes when | Reopens when |
| --- | --- | --- |
| **Avalanche danger** | The resort's danger level reaches 3 and the run has a 30° pitch, 25° at level 4, 20° at level 5. | The danger drops below that, plus **2 game hours of control work**. If the danger rises again during control work, the wait starts over. |
| **Blizzard** | Native blizzard weather, on runs with a 22° pitch or a native expert/extreme rating. | 1 game hour after the blizzard ends. |
| **Thin cover** | The thinnest 10 % of the run has less than 25 cm of snow. | 35 cm or more. |
| **Grooming** | A snowcat grooming job is active on the run. | The job ends. A job that runs longer than 4 hours is ignored, so a run can't stay closed for good. |
| **Extreme cold** | −30 °C at the top of the run. | −26 °C. |

**Avalanche danger** uses the European 1–5 scale and is worked out from a new-snow
model. Snowfall adds 2 cm per hour, blizzards 4 cm per hour, and only when it's
cold enough to snow (1.5 °C or below). New snow settles with a 36-hour half-life,
or 12 hours above 0 °C. The levels are 10, 25, 40 and 60 cm of new snow. A blizzard
on new snow adds a level (wind slab), and so does a warm spell or rain on 15 cm or
more of new snow (wet snow).

**Steepness** is measured from the run's own geometry: the steepest average pitch
over any 20 m section. The game's difficulty rating is used too, where it's
available. Only a run's **first segment** is measured: reading the rest of a
multi-segment run crashes the game on build CL8198 with UE4SS 4.0 (fixed in 0.1.1,
see Changes below).

**Your closures win.** The patrol never opens a run you closed. If you reopen a
run the patrol closed, it leaves that run alone for 24 game hours.

**Per-run switches (all off by default).** The patrol only closes a run for a
condition you switched on for that run. Open a run's panel and look under the game's
Open/Closed switch for the **Ski patrol** section. Under *Close this run automatically
for:* there is one switch each for avalanche danger, blizzard, thin snow, grooming and
extreme cold; click one to turn it on or off. The choices are kept in
`%LOCALAPPDATA%\Ski-E-O-Mod-ski-patrol-run-settings.txt`, outside the mod folder, so updates keep them.

There is no extra open/close button: **the game's own Open/Closed switch is the one to use.**
The section's text says why the patrol closed the run and roughly when it expects to reopen it,
for example *Closed by ski patrol: blizzard: high wind and poor visibility.* If you reopen a run
the patrol closed with the game's switch, the patrol leaves it alone for 24 game hours
(`override_hours`); changing one of that run's switches ends that break.

- Switching a condition off while the patrol holds the run closed for it lets the patrol reopen the run
  (after the usual 0.5 game hours minimum).
- Runs you closed yourself are never touched and say so.
- Runs the **game itself** closed (since build CL8198 it closes runs for *not enough
  snow* or *avalanche danger*, and roped-off runs) say so too: the patrol can't reopen them,
  and the game does it by itself.
- If two runs share a name, the switches are hidden; rename one.
- The `avalanche`, `storm`, `thin_cover`, `grooming` and `cold` settings in `config.lua` still turn a rule off for every run.

**Restarts.** The patrol remembers which closures were its own and the new-snow
model in `%LOCALAPPDATA%\Ski-E-O-Mod-ski-patrol-patrol-closures.txt`, outside the mod folder so updates keep it (0.2.2 and older kept `patrol-closures.txt` in the mod folder; it is read once and then left alone). After you load a save, it still
reopens its runs when conditions recover.

## Controls

| Input | Effect |
| --- | --- |
| **F9** | (rebindable in the Mods menu) Writes a patrol report to the UE4SS log and console. |
| **Ctrl+F9** | (rebindable) Pauses the patrol, which reopens every run it closed. Press again to resume. |
| `skipatrol` | Same report, from the UE4SS console. `skipatrol off`, `skipatrol on` and `skipatrol reload` (re-read `config.lua`) also work. |

Every closure and reopening goes in the log with its reason. A report looks like this:

```text
[Ski Patrol] Report (version 0.4.0)
[Ski Patrol]   Weather: blizzard, -9 °C at the top. New snow (model): 25 cm. Avalanche danger: 3 (considerable).
[Ski Patrol]   Snow cover readings: available (ok)
[Ski Patrol]   "Bunny Hill": 6° steepest, 300 m, cover 120 cm. open
[Ski Patrol]   "Summit Couloir": 34° steepest, 300 m, cover 120 cm. CLOSED by patrol: avalanche danger 3 (considerable) on a 34° pitch; blizzard: high wind and poor visibility
[Ski Patrol]   "Ridge": 23° steepest, 300 m, cover 120 cm. CLOSED by patrol: blizzard: high wind and poor visibility
[Ski Patrol]   "Closed By Me": 40° steepest, 300 m, cover 120 cm. closed by you
[Ski Patrol]   Recent patrol actions:
[Ski Patrol]     day 1 08:30  "Ridge" closed: blizzard: high wind and poor visibility
```

## Install

This is a script mod for Z's Mod Loader (a UE4SS mod, `mod.ini` + `Scripts/main.lua`). A
mapmod's sandboxed API can't open or close runs, but UE4SS can call the game's own run
closure (the same switch you use in the game's UI).

Install it from the Mods menu / Mod Manager, or by hand: unzip `ski-patrol-<release>.zip` into
`<game>\mods` so you get `<game>\mods\ski-patrol\mod.ini`, and switch it on in the Mods menu
(or add an empty `enabled.txt` to the folder). It loads when the game starts. The mod's `Id` and
folder name are `ski-patrol`; keep them.

**Snow cover readings** come from a small native library that ships with the mod,
`Native/PatrolSnow.dll` (source and build line in `Native/`). Lua can't read the game's
snow, so the library reads the game's CPU snow tiles, read-only and on the game thread.
Before it touches any memory it checks four exact code fingerprints of the game's own
snow cache routines, so on a game build it doesn't recognise it refuses and the
thin-cover rule turns itself off (the report and the trail panel say so). Nothing in the
game is changed. It talks to Lua through three small files in `%LOCALAPPDATA%`
(`Ski-E-O-Mod-ski-patrol-snow.job`, `.bin`, `.status`). The snow reading code is derived
from the skieomod loader's sampler (BSD-3-Clause, see `Native/LICENSE-skieomod`); you do
not need that loader.

It is a native library, so if it were wrong it could crash the game instead of logging a
Lua error, which Lua tests can't catch. Set `thin_cover = false` in `Scripts/config.lua`
to stop the mod from ever loading it. `Native/run_tests.sh` tests the reading logic
(and, given `skieogame.exe`, the fingerprints) on Linux/macOS.

## Settings

Edit `Scripts/config.lua` in the installed mod folder, then run `skipatrol reload`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Start with the patrol on. |
| `avalanche` | `true` | Use the avalanche rule. |
| `avalanche_pitch_deg` | `{[3]=30, [4]=25, [5]=20}` | Minimum pitch closed at each danger level. |
| `avalanche_control_hours` | 2 | Control work before reopening. |
| `new_snow_levels_cm` | `{10, 25, 40, 60}` | New snow for danger 2, 3, 4 and 5. |
| `snowfall_cm_per_hour`, `blizzard_cm_per_hour` | 2, 4 | Snow model rates. |
| `settle_half_life_hours`, `warm_settle_half_life_hours` | 36, 12 | How fast new snow stabilises. |
| `storm` | `true` | Use the blizzard rule. |
| `storm_pitch_deg`, `storm_difficulty` | 22, 2 | Runs closed in a blizzard (difficulty 0 beginner to 3 extreme). |
| `storm_clear_hours` | 1 | Wait after a blizzard. |
| `thin_cover` | `true` | Use the thin-cover rule. |
| `thin_close_cm`, `thin_open_cm` | 25, 35 | Close and reopen depths. |
| `grooming`, `grooming_max_hours` | `true`, 4 | Close during grooming. |
| `cold`, `cold_close_c`, `cold_open_c` | `true`, −30, −26 | Extreme cold. |
| `min_closed_hours` | 0.5 | Shortest closure. |
| `override_hours` | 24 | How long a run you reopened is left alone. |
| `units` | `'auto'` | Units in messages: `'auto'` (the game's Measurement System), `'metric'` or `'imperial'`. |
| `trail_panel` | `true` | Show the Ski patrol section in the trail panel. Set `false` (and restart the game) if it causes any trouble. |
| `tick_ms` | 2000 | Real milliseconds between patrol checks. |

## How it works

```text
Scripts/main.lua           UE4SS entry: patrol loop, report, hotkeys, console command, memory file
Scripts/patrol_rules.lua   Decisions (pure Lua): run geometry, snow model, danger, closure reasons
Scripts/patrol_native.lua  Game access: TrailMapSubsystem, TimeSubsystem, WeatherSubsystem,
                           GroomingSubsystem, and snow through Native/PatrolSnow.dll
Scripts/patrol_store.lua   the patrol's own closures + snow model file
Scripts/modsupport.lua     Mods menu glue: state file location, live on/off, managed keys
Scripts/patrol_panel.lua   The Ski patrol section in the game's trail panel
Scripts/config.lua         Your settings
tools/run_lua.py           Runs the tests through lupa (Lua 5.4)
tests/test_rules.lua       Every rule, hysteresis, overrides, the snow model
tests/test_main.lua        Loads the mod like UE4SS against a fake game: a storm, a restart,
                           grooming, overrides, pause/resume, no snow sampler, main menu
```

```sh
pip install lupa
python tools/run_lua.py tests/test_rules.lua
python tools/run_lua.py tests/test_main.lua
```

Limits: the game doesn't expose avalanches, wind speed or skier injuries to mods,
so danger is modelled from snowfall, temperature and blizzards, and there's no
incident rule. Closures happen in the game's native run state, so they show up
wherever the game shows closed runs. The trail panel finds a run by its name, so
two runs with the same name show a note asking you to rename one.

License: MIT.

## Changes

**0.4.0** Per-run switches in the trail panel for which conditions may close that run, all
off by default (so after updating, nothing closes until you switch conditions on for each run).
The extra Reopen / "Let the patrol close it again" button is gone; use the game's Open/Closed switch.
Settings are saved in `run-settings.txt` next to the closure memory.

**0.3.2** The game build is CL8198 (earlier notes said CL8119 by mistake): `mod.ini`
`GameVersion` and the README now say so. No code changed. The snow reader never checked
a build number; it only matches code fingerprints, which were confirmed against the
installed game's `skieogame.exe`.

**0.3.1** Messages and the report use the units you chose in the game (Options >
Measurement System): inches, °F and feet when imperial; cm, °C and metres when metric.
Automatic follows your system language (en-US shows imperial). `units = 'metric'` or
`'imperial'` in `config.lua` overrides it.

**0.3.0** Thin-snow closures now work without any other mod. New `Native/PatrolSnow.dll`
reads the game's snow depth along each run, after matching the game build. A run closes
when its thinnest tenth has under 25 cm of snow (so half a bare run closes it) and
reopens at 35 cm. Version 0.2.x needed the Custom Map loader for this, which isn't
installed on a Z's Mod Loader setup. `thin_cover = false` disables the reader.

**0.2.3** Brought in line with the Ski-E-O! developer modding FAQ: `mod.ini` replaces
`custom-mod.json`; Id = folder = `ski-patrol`; F9 and Ctrl+F9 are listed under `[Keybinds]`
with `ManagedKeybinds = true` so players can rebind them in the Mods menu; the saved
closures moved out of the mod folder; switching the mod off in the Mods menu pauses the
patrol (reopening its runs) without a restart.

**0.2.2** (older) Without a snow reader the thin-snow rule can't work, so the trail panel now says so on open runs instead of implying the patrol checks snow.

**0.2.1** The trail panel section now shows the game's own closures (not enough
snow, avalanche danger, rope) instead of calling those runs open.

**0.2.0** Added the Ski patrol section to the trail panel: why a run is closed,
when it should reopen, a **Reopen anyway** button, and **Let the patrol close it
again** for runs you reopened. Setting `trail_panel = false` turns it off.

**0.1.1** Fixed the game crashing a few seconds after loading a save. Version 0.1.0
read each run's extra segments (`AdditionalCurves`), and on build CL8198 with UE4SS
4.0 that array comes back without its element type, so UE4SS read a null pointer
(`EXCEPTION_ACCESS_VIOLATION reading address 0x34` in `TArray:ForEach`). Any save
with a run made of more than one segment crashed. The patrol now measures only the
first segment of each run.

