-- server/encounters/default.lua
local ezmemory = require('scripts/ezlibs-scripts/ezmemory')

local SCENARIO = "/server/assets/ezlibs-assets/ezencounters/ezencounters.zip"

-- Fair baseline (NOT enforced)
local BASE_HP     = 100
local HPMEM_ITEM  = "HPMem"
local HPMEM_BONUS = 20

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

local function tier_from_ratio(r)
  if r < 1.25 then return 0 end
  if r < 1.75 then return 1 end
  if r < 2.50 then return 2 end
  return 3
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

  -- (optional) reward soft-scaling:
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

local function clamp_rank(x)
  if x < 1 then return 1 end
  if x > 4 then return 4 end
  return x
end

local function mk_mettaur_canodumb(tier)
  local r = clamp_rank(1 + tier)
  return {
    name = "Mettaur_Canodumb_T"..tier,
    path = SCENARIO,
    weight = 10,
    enemies = {
      { name = "Mettaur",  rank = r },
      { name = "Mettaur",  rank = r },
      { name = "Canodumb", rank = r },
    },
    positions = {
      {0,0,0,0,0,3},
      {0,0,0,0,1,0},
      {0,0,0,2,0,0},
    },
    results_callback = give_result_awards,
  }
end

local function mk_mettaur_gunner(tier)
  local r = clamp_rank(1 + tier)
  return {
    name = "Mettaur_Gunner_T"..tier,
    path = SCENARIO,
    weight = 10,
    enemies = {
      { name = "Mettaur", rank = r },
      { name = "Gunner",  rank = r },
    },
    positions = {
      {0,0,0,0,0,2},
      {0,0,0,0,1,0},
      {0,0,0,0,0,0},
    },
    results_callback = give_result_awards,
  }
end

local encounters_by_tier = {
  [0] = { mk_mettaur_canodumb(0), mk_mettaur_gunner(0) },
  [1] = { mk_mettaur_canodumb(1), mk_mettaur_gunner(1) },
  [2] = { mk_mettaur_canodumb(2), mk_mettaur_gunner(2) },
  [3] = { mk_mettaur_canodumb(3), mk_mettaur_gunner(3) },
}

-- union for asset provisioning
local all_encounters = {}
for t = 0, 3 do
  for _, e in ipairs(encounters_by_tier[t]) do
    table.insert(all_encounters, e)
  end
end

return {
  minimum_steps_before_encounter = 40,
  encounter_chance_per_step = 0.10,

  -- For provisioning + named encounters at boot:
  all_encounters = all_encounters,

  -- For runtime selection per player:
  get_encounters = function(player_id)
    local t = tier_from_ratio(overcap_ratio(player_id))
    return encounters_by_tier[t] or encounters_by_tier[0]
  end,
}
