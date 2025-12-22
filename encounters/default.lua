-- server/encounters/default.lua
print("[default.lua] LOADED")

local room_builder = require('scripts/whynn_core/encounters/room_builder')
local tileslib     = require('scripts/encounter_lib/tiles')

-- Load NPC/shop bot (side-effect require)
require("scripts/whynn_core/npcs/hpmem_shop_bot")

--=====================================================
-- Room config
--=====================================================
local ROOM_CFG = {
  area_id = "default",
  is_wild = true,

  scenario = "/server/assets/ezlibs-assets/ezencounters/ezencounters.zip",
  weight = 10,
  encounter_name_prefix = "Default",
  print_get_encounters_called = true,

  -- Highest rank the room is allowed to try for (room_builder will still clamp/safety-cap)
  max_target_rank = 8,

  -- Hard room safety: no rank 2+ until this HP
  rank_cap_hp_threshold = 120,

  -- How many candidate encounters to return each tick
  return_count = 3,

  --=====================================================
  -- Rank availability per enemy name.
  --
  -- IMPORTANT:
  --   The keys here MUST match the enemy "name" used in enemy_pool AND whatever
  --   your room_builder expects when it resolves/spawns mobs (usually the package name).
  --=====================================================
  allowed_ranks = {
    -- Existing
    Mettaur  = {1,2,3,4,6,7},
    Gunner   = {1,4,6,7},
    Canodumb = {1,2,3},
    Ratty    = {1,2,3,4},
    Swordy   = {1,2,3,4,8},

    -- New adds (enable a full ladder by default; room safety will still gate early HP)
    Shrimpy  = {1,2,3,4,5,6,7,8},
    Fishy  = {1,2,3,4,5,6,7,8},
    Bunny    = {1,2,3,4,5,6,7,8},
    Flashy   = {1,2,3,4,5,6,7,8},
    HauntedCandle  = {1,2,3,4,5,6,7,8},
  },

  --=====================================================
  -- Weighted pool: higher weight = more likely to appear.
  -- Tune these however you like; nothing else has to change.
  --=====================================================
  enemy_pool = {
    -- Existing
    { name="Mettaur",  weight=28 },
    { name="Canodumb", weight=16 },
    { name="Gunner",   weight=7 },
    { name="Ratty",    weight=5  },
    { name="Swordy",   weight=14 },

    -- New
    { name="Shrimpy",  weight=12 },
    { name="Fishy",  weight=15 },
    { name="Bunny",    weight=12 },
    { name="Flashy",   weight=7  },
    { name="HauntedCandle",  weight=10 },
  },

  -- Enemy spawn side / tile layout
  enemy_tiles = tileslib.DEFAULT_ENEMY_TILES_RIGHT,

  -- Swarm tuning (if your room_builder uses these to penalize ranks for big packs)
  swarm_rank_penalty_count = 4,
  swarm_rank_penalty = 1,
}

--=====================================================
-- Encounter table export
--=====================================================
return {
  minimum_steps_before_encounter = 40,
  encounter_chance_per_step = 0.10,

  get_encounters = function(player_id)
    if ROOM_CFG.print_get_encounters_called then
      print(string.format("[default.lua] get_encounters CALLED for %s", tostring(player_id)))
    end

    -- This function is where all the pack sizing + rank selection magic happens
    return room_builder.build_encounters_for_room(player_id, ROOM_CFG)
  end,
}
