-- server/encounters/default.lua
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')

local SCENARIO = "/server/assets/ezlibs-assets/ezencounters/ezencounters.zip"

-- Fair baseline (NOT enforced)
local BASE_HP     = 100
local HPMEM_ITEM  = "HPMem"
local HPMEM_BONUS = 20

-- === Rank scaling config ===
local MAX_PLAYER_HP_FOR_SCALING = 2000
local MAX_TARGET_RANK = 7

-- Allowed ranks by mob name (from ezencounters.zip list you provided)
-- Any mob not listed safely defaults to {1}.
local ALLOWED_RANKS = {
  Mettaur  = {1,2,3,4,6,7},
  Gunner   = {1,4,6,7},
  Canodumb = {1,2,3},
  Ratty    = {1,2,3,4},
  Swordy   = {1,2,3,4,8},
}

-- Enemy pool + weights (tune to taste)
local ENEMY_POOL = {
  { name="Mettaur",  weight=40 },
  { name="Canodumb", weight=20 },
  { name="Gunner",   weight=15 },
  { name="Ratty",    weight=15 },
  { name="Swordy",   weight=10 },
}

-- Enemy-side tiles (right half): cols 4..6
local DEFAULT_ENEMY_TILES = {
  {1,4},{1,5},{1,6},
  {2,4},{2,5},{2,6},
  {3,4},{3,5},{3,6},
}

-- =========================================================
-- Baseline memory + rewards (kept from your original)
-- =========================================================

local function count_hpmem(player_id)
  if ezmemory.count_player_item then
    return ezmemory.count_player_item(player_id, HPMEM_ITEM) or 0
  end
  return 0
end

local function fair_allowed_max_hp(player_id)
  return BASE_HP + (HPMEM_BONUS * count_hpmem(player_id))
end

local function overcap_ratio(player_id)
  local allowed = fair_allowed_max_hp(player_id)
  local have = Net.get_player_max_health(player_id)
  if allowed <= 0 or have <= 0 then return 1 end
  local r = have / allowed
  if r < 1 then r = 1 end
  return r
end

local function persist_health_and_emotion(player_id, stats)
  if stats.emotion == 1 then
    Net.set_player_emotion(player_id, stats.emotion)
  else
    Net.set_player_emotion(player_id, 0)
  end
  ezmemory.set_player_health(player_id, stats.health)
end

local function give_result_awards(player_id, encounter_info, stats)
  if stats.ran then
    persist_health_and_emotion(player_id, stats)
    return
  end

  -- reward soft-scaling
  local r = overcap_ratio(player_id)
  local mult = 1 / math.max(1, r)

  local monies = math.floor(((stats.score or 0) * 50) * mult + 0.5)
  local hp_bonus = ((stats.health or 0) < 21) and 50 or 0

  local rewards = {}
  if monies > 0 then table.insert(rewards, { type = 0, value = monies }) end
  if hp_bonus > 0 then table.insert(rewards, { type = 2, value = hp_bonus }) end

  if #rewards > 0 then
    Net.send_player_battle_rewards(player_id, rewards)
  end

  persist_health_and_emotion(player_id, { health = (stats.health or 0) + hp_bonus, emotion = stats.emotion })
end

-- =========================================================
-- Scaling + randomization helpers
-- =========================================================

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- HP -> target rank 1..7 (2000 maps to 7)
local function rank_from_player_hp(max_hp)
  max_hp = tonumber(max_hp) or BASE_HP
  max_hp = clamp(max_hp, 1, MAX_PLAYER_HP_FOR_SCALING)

  local band = MAX_PLAYER_HP_FOR_SCALING / MAX_TARGET_RANK -- ~285.714
  local rank = math.floor((max_hp - 1) / band) + 1
  return clamp(rank, 1, MAX_TARGET_RANK)
end

-- Choose highest allowed rank <= desired. If none, return lowest allowed.
local function pick_available_rank(mob_name, desired_rank)
  desired_rank = tonumber(desired_rank) or 1
  local allowed = ALLOWED_RANKS[mob_name]
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

  -- desired below minimum allowed: return minimum allowed
  local lowest = allowed[1]
  for i = 2, #allowed do
    if allowed[i] < lowest then lowest = allowed[i] end
  end
  return lowest or 1
end

-- 70% no change, 15% -1, 15% +1
local function jitter_rank(desired_rank)
  local roll = math.random()
  if roll < 0.15 then return desired_rank - 1 end
  if roll < 0.30 then return desired_rank + 1 end
  return desired_rank
end

local function safe_rank(mob_name, desired_rank)
  desired_rank = clamp(tonumber(desired_rank) or 1, 1, 8) -- allow Swordy rank 8 snap
  return pick_available_rank(mob_name, desired_rank)
end

local function rand_int(a, b)
  return math.random(a, b)
end

local function weighted_pick(pool)
  local total = 0
  for _, e in ipairs(pool) do total = total + (e.weight or 1) end
  local r = math.random() * total
  local acc = 0
  for _, e in ipairs(pool) do
    acc = acc + (e.weight or 1)
    if r <= acc then return e.name end
  end
  return pool[#pool].name
end

-- At 100 HP (or below): ALWAYS 2 enemies.
-- Otherwise: 2 mobs: 55%, 3 mobs: 35%, 4 mobs: 8%, 5 mobs: 2%
local function weighted_enemy_count(player_max_hp)
  if (tonumber(player_max_hp) or 0) <= 100 then
    return 2
  end

  local roll = math.random()
  if roll < 0.60 then return 2 end
  if roll < 0.90 then return 3 end
  if roll < 0.95 then return 4 end
  return 5
end

local function pick_tiles(tiles, n)
  local pool = {}
  for i=1,#tiles do pool[i] = tiles[i] end

  local out = {}
  n = math.min(n, #pool)
  for i=1,n do
    local idx = rand_int(1, #pool)
    out[i] = pool[idx]
    table.remove(pool, idx)
  end
  return out
end

local function build_positions_from_tiles(chosen_tiles)
  local grid = {
    {0,0,0,0,0,0},
    {0,0,0,0,0,0},
    {0,0,0,0,0,0},
  }

  for i, rc in ipairs(chosen_tiles) do
    local r, c = rc[1], rc[2]
    grid[r][c] = i -- enemy index marker 1..N
  end
  return grid
end

-- Optional difficulty sanity: if you roll 4-5 mobs, slightly reduce target rank.
local function adjust_rank_for_swarm(desired_rank, count)
  if count >= 4 then
    return clamp(desired_rank - 1, 1, 8)
  end
  return desired_rank
end

local function build_random_encounter(desired_rank, player_max_hp)
  local count = weighted_enemy_count(player_max_hp)
  desired_rank = adjust_rank_for_swarm(desired_rank, count)

  local tiles = pick_tiles(DEFAULT_ENEMY_TILES, count)
  local positions = build_positions_from_tiles(tiles)

  local enemies = {}
  for i=1,count do
    local mob = weighted_pick(ENEMY_POOL)

    local jittered = jitter_rank(desired_rank)
    local rank = safe_rank(mob, jittered)

    enemies[#enemies+1] = { name = mob, rank = rank }
  end

  return {
    name = "Default_R"..desired_rank.."_N"..count,
    path = SCENARIO,
    weight = 10,
    enemies = enemies,
    positions = positions,
    results_callback = give_result_awards,
  }
end

-- =========================================================
-- Provisioning list (safe, small, covers ranks)
-- =========================================================

local all_encounters = {}
for r = 1, 8 do
  table.insert(all_encounters, {
    name = "Provision_R"..r.."_A",
    path = SCENARIO,
    weight = 1,
    enemies = {
      { name="Mettaur",  rank=safe_rank("Mettaur", r) },
      { name="Canodumb", rank=safe_rank("Canodumb", r) },
    },
    positions = build_positions_from_tiles(pick_tiles(DEFAULT_ENEMY_TILES, 2)),
    results_callback = give_result_awards,
  })

  table.insert(all_encounters, {
    name = "Provision_R"..r.."_B",
    path = SCENARIO,
    weight = 1,
    enemies = {
      { name="Mettaur", rank=safe_rank("Mettaur", r) },
      { name="Gunner",  rank=safe_rank("Gunner",  r) },
    },
    positions = build_positions_from_tiles(pick_tiles(DEFAULT_ENEMY_TILES, 2)),
    results_callback = give_result_awards,
  })
end

-- =========================================================
-- Public API
-- =========================================================

return {
  minimum_steps_before_encounter = 40,
  encounter_chance_per_step = 0.10,

  -- For provisioning + named encounters at boot:
  all_encounters = all_encounters,

  -- For runtime selection per player:
  get_encounters = function(player_id)
    local hp = Net.get_player_max_health(player_id)

    -- target rank 1..7 from HP scaling, but allow Swordy to snap to 8 if rolled/jittered
    local desired_rank = rank_from_player_hp(hp)

    return {
      build_random_encounter(desired_rank, hp),
      build_random_encounter(desired_rank, hp),
      build_random_encounter(desired_rank, hp),
    }
  end,
}
