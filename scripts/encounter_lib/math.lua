-- server/scripts/encounter_lib/math.lua
local M = {}

function M.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function M.rand_int(a, b)
  return math.random(a, b)
end

return M
