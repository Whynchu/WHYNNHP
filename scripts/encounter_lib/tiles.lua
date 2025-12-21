-- server/scripts/encounter_lib/tiles.lua
local mathlib = require('scripts/encounter_lib/math')

local M = {}

-- Enemy-side tiles (right half): cols 4..6
M.DEFAULT_ENEMY_TILES_RIGHT = {
  {1,4},{1,5},{1,6},
  {2,4},{2,5},{2,6},
  {3,4},{3,5},{3,6},
}

function M.pick_tiles(tile_list, n)
  local pool = {}
  for i=1,#tile_list do pool[i] = tile_list[i] end

  local out = {}
  n = math.min(n, #pool)
  for i=1,n do
    local idx = mathlib.rand_int(1, #pool)
    out[i] = pool[idx]
    table.remove(pool, idx)
  end
  return out
end

function M.build_positions_from_tiles(chosen_tiles)
  local grid = {
    {0,0,0,0,0,0},
    {0,0,0,0,0,0},
    {0,0,0,0,0,0},
  }

  for i, rc in ipairs(chosen_tiles) do
    local r, c = rc[1], rc[2]
    grid[r][c] = i
  end
  return grid
end

return M
