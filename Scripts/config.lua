-- Ski patrol settings. Change a value, then type `skipatrol reload` in the
-- UE4SS console (or restart the game). Anything left out uses the default
-- listed in README.md. Times are game hours unless they say otherwise.
return {
    -- enabled = true,              -- false: the patrol never closes runs

    -- Avalanche danger closes steep runs (degrees at each danger level).
    -- avalanche_pitch_deg = {[3] = 30, [4] = 25, [5] = 20},
    -- avalanche_control_hours = 2,

    -- Blizzards close runs this steep, or rated expert (2) and above.
    -- storm_pitch_deg = 22,
    -- storm_difficulty = 2,

    -- Thin cover: close below, reopen at or above (cm).
    -- thin_close_cm = 25,
    -- thin_open_cm = 35,

    -- grooming = true,
    -- cold_close_c = -30,

    -- If you reopen a run the patrol closed, it stays open this long.
    -- override_hours = 24,

    -- Units in messages: 'auto' (follow the game's Measurement System), 'metric' or 'imperial'.
    -- units = 'auto',

    -- false: no Ski patrol section in the trail panel (restart the game after changing).
    -- trail_panel = true,
}
