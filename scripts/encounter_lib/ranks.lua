-- server/scripts/encounter_lib/ranks.lua
local mathlib = require('scripts/encounter_lib/math')

local M = {}

-- HP -> target rank 1..max_target_rank (2000 maps to 7 in your default config)
function M.rank_from_player_hp(max_hp, base_hp, max_hp_for_scaling, max_target_rank)
  max_hp = tonumber(max_hp) or tonumber(base_hp) or 100
  max_hp = mathlib.clamp(max_hp, 1, max_hp_for_scaling)

  local band = max_hp_for_scaling / max_target_rank
  local rank = math.floor((max_hp - 1) / band) + 1
  return mathlib.clamp(rank, 1, max_target_rank)
end

-- Tier -> minimum rank floor (data-driven), with "closest lower tier" fallback
function M.min_rank_for_tier(tier, rank_floor_by_tier)
  tier = tonumber(tier) or 0
  local map = rank_floor_by_tier

  if type(map) == "table" then
    local v = map[tier]
    if v ~= nil then
      return tonumber(v) or 1
    end

    local best_tier = nil
    local best_rank = nil
    for k, r in pairs(map) do
      local kt = tonumber(k)
      local rr = tonumber(r)
      if kt and rr and kt <= tier then
        if best_tier == nil or kt > best_tier then
          best_tier = kt
          best_rank = rr
        end
      end
    end
    if best_rank ~= nil then
      return best_rank
    end
  end

  return 1
end

-- 70% no change, 15% -1, 15% +1 (matches your current roll thresholds)
function M.jitter_rank(desired_rank)
  local roll = math.random()
  if roll < 0.15 then return math.max(1, desired_rank - 1) end
  if roll < 0.30 then return desired_rank + 1 end
  return desired_rank
end

-- Choose highest allowed rank <= desired. If none, return lowest allowed.
function M.pick_available_rank(mob_name, desired_rank, allowed_ranks)
  desired_rank = tonumber(desired_rank) or 1

  local allowed = allowed_ranks and allowed_ranks[mob_name]
  if type(allowed) ~= "table" then
    return 1
  end

  local best = nil
  for _, r in ipairs(allowed) do
    if r <= desired_rank and (best == nil or r > best) then
      best = r
    end
  end
  if best ~= nil then return best end

  local lowest = allowed[1]
  for i = 2, #allowed do
    if allowed[i] < lowest then lowest = allowed[i] end
  end
  return lowest or 1
end

-- Clamp to 1..8 then snap (Swordy rank 8 compatibility)
function M.safe_rank(mob_name, desired_rank, allowed_ranks)
  desired_rank = mathlib.clamp(tonumber(desired_rank) or 1, 1, 8)
  return M.pick_available_rank(mob_name, desired_rank, allowed_ranks)
end

return M
