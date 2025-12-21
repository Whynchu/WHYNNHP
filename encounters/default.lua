-- server/encounters/default.lua
print("[default.lua] LOADED")

local room_builder = require('scripts/whynn_core/encounters/room_builder')
local tileslib     = require('scripts/encounter_lib/tiles')
require("scripts/whynn_core/npcs/hpmem_shop_bot")


local ROOM_CFG = {
  area_id = "default",
  is_wild = true,

  scenario = "/server/assets/ezlibs-assets/ezencounters/ezencounters.zip",
  weight = 10,
  encounter_name_prefix = "Default",
  print_get_encounters_called = true,

  max_target_rank = 7,

  -- Hard room safety: no rank 2+ until this HP
  rank_cap_hp_threshold = 120,

  -- How many candidate encounters to return each tick
  return_count = 3,

  allowed_ranks = {
    Mettaur  = {1,2,3,4,6,7},
    Gunner   = {1,4,6,7},
    Canodumb = {1,2,3},
    Ratty    = {1,2,3,4},
    Swordy   = {1,2,3,4,8},
  },

  enemy_pool = {
    { name="Mettaur",  weight=42 },
    { name="Canodumb", weight=20 },
    { name="Gunner",   weight=13 },
    { name="Ratty",    weight=8 },
    { name="Swordy",   weight=17 },
  },

  enemy_tiles = tileslib.DEFAULT_ENEMY_TILES_RIGHT,

  swarm_rank_penalty_count = 4,
  swarm_rank_penalty = 1,
}

return {
  minimum_steps_before_encounter = 40,
  encounter_chance_per_step = 0.10,

  get_encounters = function(player_id)
    if ROOM_CFG.print_get_encounters_called then
      print(string.format("[default.lua] get_encounters CALLED for %s", tostring(player_id)))
    end
    return room_builder.build_encounters_for_room(player_id, ROOM_CFG)
  end,
}
