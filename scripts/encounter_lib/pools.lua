-- server/scripts/encounter_lib/pools.lua
local M = {}

function M.weighted_pick(entries)
  local total = 0
  for _, e in ipairs(entries) do
    total = total + (e.weight or 1)
  end

  local r = math.random() * total
  local acc = 0
  for _, e in ipairs(entries) do
    acc = acc + (e.weight or 1)
    if r <= acc then
      return e.name
    end
  end

  return entries[#entries].name
end

-- Default curve matches your current:
-- hp<=100 -> 2
-- roll < .60 -> 2
-- roll < .90 -> 3
-- roll < .95 -> 4
-- else -> 5
function M.weighted_enemy_count(player_max_hp, thresholds)
  local hp = tonumber(player_max_hp) or 0
  if hp <= 100 then return 2 end

  -- Allow override but keep defaults when omitted
  local t = thresholds or { a=0.60, b=0.90, c=0.95 }

  local roll = math.random()
  if roll < t.a then return 2 end
  if roll < t.b then return 3 end
  if roll < t.c then return 4 end
  return 5
end

return M
