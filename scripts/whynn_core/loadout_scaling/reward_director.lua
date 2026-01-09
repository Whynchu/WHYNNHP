--=====================================================
-- reward_director.lua
--
-- Responsibilities:
--   * Decide whether rewards apply (win-only)
--   * Compute money rewards (score + mob count scaling)
--   * Compute post-battle critical HP heal (optional)
--   * Apply money authoritatively (Net.set_player_money)
--   * Show rewards UI (Net.send_player_battle_rewards)
--   * Persist final wallet (ezmemory)
--   * Persist health/emotion, then clear encounter context
--
-- Notes:
--   - No rewards on run/escape/non-win outcomes
--   - Crit heal is NOT a reward for running (blocked)
--   - v1 cooldown is in-memory per server runtime
--=====================================================

local C = require('scripts/whynn_core/loadout_scaling/scaling_config')
local encounter_director = require('scripts/whynn_core/loadout_scaling/encounter_director')

local M = {}

-- v1 cooldown is in-memory (OK for now)
local last_crit_heal_at = {}

--=====================================================
-- Small math helpers
--=====================================================

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

--=====================================================
-- Debug / player messaging helpers
--=====================================================

local function dbg_print(player_id, msg)
  if not (C.DEBUG and C.DEBUG.enabled) then return end
  print(string.format("[loadout_scaling][%s] %s", tostring(player_id), msg))
end

local function maybe_msg_player(player_id, msg, deps)
  if not (C.DEBUG and C.DEBUG.to_player) then return end
  if deps and deps.Net and deps.Net.message_player then
    deps.Net.message_player(player_id, msg)
  end
end

--=====================================================
-- Persistence: health + emotion
--=====================================================

local function persist_health_and_emotion(player_id, stats, deps)
  stats = stats or {}

  -- Emotion: only persist "hurt" (1), otherwise clear
  if deps and deps.Net and type(deps.Net.set_player_emotion) == "function" then
    if stats.emotion == 1 then
      deps.Net.set_player_emotion(player_id, stats.emotion)
    else
      deps.Net.set_player_emotion(player_id, 0)
    end
  end

  -- Health persistence via ezmemory (if present)
  if deps and deps.ezmemory and type(deps.ezmemory.set_player_health) == "function" and stats.health then
    deps.ezmemory.set_player_health(player_id, stats.health)
  end
end

--=====================================================
-- Outcome normalization helpers
--=====================================================

local function truthy(v)
  return v == true or v == 1 or v == "1" or v == "true"
end

local function get_outcome(stats)
  if type(stats) ~= "table" then return nil end
  return stats.outcome or stats.result or stats.end_reason or stats.reason
end

local function outcome_string(stats)
  local o = get_outcome(stats)
  if type(o) == "string" then return string.lower(o) end
  return nil
end

-- rewards ONLY on confirmed win
local function is_nonwin(stats)
  if type(stats) ~= "table" then return true end

  -- Explicit run flags are an immediate deny
  if truthy(stats.ran) or truthy(stats.run) or truthy(stats.escaped) or truthy(stats.escape) then
    return true
  end

  -- Numeric outcome: 1 == win, anything else is non-win
  local outcome = get_outcome(stats)
  if type(outcome) == "number" then
    return outcome ~= 1
  end

  -- String outcome: accept a few canonical win values
  local o = outcome_string(stats)
  if o then
    if o == "win" or o == "victory" or o == "cleared" or o == "clear" or o == "1" then
      return false
    end
    return true
  end

  -- Fallback: accept common win booleans
  if truthy(stats.victory) or truthy(stats.win) or truthy(stats.won) or truthy(stats.cleared) then
    return false
  end

  return true
end

local function did_run(stats)
  if type(stats) ~= "table" then return false end
  if truthy(stats.ran) or truthy(stats.run) or truthy(stats.escaped) or truthy(stats.escape) then return true end

  local o = outcome_string(stats)
  if o == "run" or o == "ran" or o == "escape" or o == "escaped" or o == "fled" then return true end

  return false
end

--=====================================================
-- Encounter extraction: mob count
--=====================================================

local function mob_count_from_encounter(encounter_info)
  if type(encounter_info) ~= "table" then return 0 end

  -- Preferred explicit fields (fast path)
  local n = tonumber(encounter_info._mob_count or encounter_info._enemy_count or encounter_info.mob_count)
  if n and n >= 0 then
    return math.floor(n)
  end

  -- Fallback: look at common spawn arrays
  if type(encounter_info.enemies) == "table" then return #encounter_info.enemies end
  if type(encounter_info.mobs) == "table" then return #encounter_info.mobs end
  if type(encounter_info.spawn) == "table" then return #encounter_info.spawn end

  return 0
end

local function mob_count_multiplier(mob_count)
  mob_count = tonumber(mob_count) or 0
  if mob_count <= 1 then return 1.00 end
  if mob_count == 2 then return 1.10 end
  if mob_count == 3 then return 1.25 end
  if mob_count == 4 then return 1.55 end
  return 2.00
end

--=====================================================
-- Money IO helpers (authoritative wallet is Net)
--=====================================================

local function net_get_money(player_id, deps)
  local Net = deps and deps.Net or _G.Net
  if not Net or type(Net.get_player_money) ~= "function" then return 0 end

  local ok, v = pcall(function() return Net.get_player_money(player_id) end)
  if not ok then return 0 end
  return (type(v) == "number") and v or 0
end

local function net_set_money(player_id, deps, amount)
  local Net = deps and deps.Net or _G.Net
  if not Net or type(Net.set_player_money) ~= "function" then
    return false, "missing set_player_money"
  end

  local ok, err = pcall(function() Net.set_player_money(player_id, amount) end)
  if not ok then return false, err end
  return true
end

-- Persist final wallet value into ezmemory (store the final number; do NOT add here)
local function ezmem_set_money(player_id, deps, amount)
  if not deps or not deps.ezmemory then return false end
  if type(deps.ezmemory.set_player_money) ~= "function" then
    dbg_print(player_id, "ezmem_set_money: missing ezmemory.set_player_money")
    return false
  end

  local ok, err = pcall(function()
    deps.ezmemory.set_player_money(player_id, amount)
  end)

  if not ok then
    dbg_print(player_id, "ezmem_set_money ERROR: " .. tostring(err))
    return false
  end

  return true
end

--=====================================================
-- Critical heal computation (post-battle survivability)
--=====================================================

local function compute_crit_heal(player_id, max_hp, end_hp, tier, is_wild, did_run_flag)
  local function log(msg) dbg_print(player_id, "crit_heal: " .. msg) end

  local H = C.CRIT_HEAL
  if not (H and H.enabled) then log("DENY disabled") return 0 end
  if did_run_flag then log("DENY did_run=true") return 0 end
  if H.wild_only and not is_wild then log("DENY not_wild") return 0 end

  max_hp = tonumber(max_hp) or 0
  end_hp = tonumber(end_hp) or 0
  tier   = tonumber(tier) or 0

  if max_hp <= 0 then log("DENY max_hp<=0") return 0 end
  if end_hp <= 0 then log("DENY end_hp<=0 (KO)") return 0 end

  -- Defaults allow config to omit some fields safely
  local threshold_pct = H.threshold_pct or 0.45
  local floor_pct     = H.floor_pct     or 0.10

  local min_chance    = H.min_chance    or 0.10
  local max_chance    = H.max_chance    or 0.95

  local min_heal_pct  = H.min_heal_pct  or 0.06
  local max_heal_pct  = H.max_heal_pct  or 0.22

  local cooldown_s    = H.cooldown_s    or 60

  local tier_mult_per = H.tier_mult_per or 0.03
  local wild_mult     = H.wild_mult     or 1.00

  local min_heal_abs  = H.min_heal_abs  or 1
  local max_heal_abs  = H.max_heal_abs  or 999999

  local ratio = end_hp / max_hp
  if ratio > threshold_pct then
    log(string.format(
      "DENY above_thr hp=%d/%d (%.1f%%>%.1f%%)",
      end_hp, max_hp, ratio * 100, threshold_pct * 100
    ))
    return 0
  end

  -- Cooldown: in-memory
  local now   = os.time()
  local last  = last_crit_heal_at[player_id] or 0
  local since = now - last
  if since < cooldown_s then
    log(string.format(
      "DENY cooldown %ds_left hp=%d/%d (%.1f%%)",
      (cooldown_s - since), end_hp, max_hp, ratio * 100
    ))
    return 0
  end

  -- Map ratio within [threshold, floor] -> t in [0..1]
  local denom = (threshold_pct - floor_pct)
  local t = 1.0
  if denom > 0 then
    t = clamp01((threshold_pct - ratio) / denom)
  end

  local tier_mult = 1.0 + (tier_mult_per * tier)
  local wm = is_wild and wild_mult or 1.0

  local chance   = clamp01(lerp(min_chance,    max_chance,    t) * tier_mult * wm)
  local heal_pct =          lerp(min_heal_pct, max_heal_pct, t) * tier_mult * wm

  local roll = math.random()
  if roll > chance then
    log(string.format(
      "NO_PROC hp=%d/%d (%.1f%%) t=%.2f roll=%.3f>%.3f heal%%=%.1f",
      end_hp, max_hp, ratio * 100, t, roll, chance, heal_pct * 100
    ))
    return 0
  end

  local heal = math.floor(max_hp * heal_pct + 0.5)
  heal = clamp(heal, min_heal_abs, max_heal_abs)

  last_crit_heal_at[player_id] = now
  log(string.format(
    "PROC hp=%d/%d (%.1f%%) t=%.2f roll=%.3f<=%.3f heal=%d (%.1f%%) cd=%ds",
    end_hp, max_hp, ratio * 100, t, roll, chance, heal, heal_pct * 100, cooldown_s
  ))

  return heal
end

--=====================================================
-- Public API: battle end handler
--=====================================================

function M.on_battle_end(player_id, deps, stats, encounter_info)
  stats = stats or {}
  local end_hp = stats.health or 0

  -- Gate rewards strictly to confirmed wins
  if is_nonwin(stats) then
    dbg_print(player_id, string.format(
      "DENY rewards: non-win (outcome=%s ran=%s win=%s victory=%s)",
      tostring(get_outcome(stats)),
      tostring(stats.ran),
      tostring(stats.win),
      tostring(stats.victory)
    ))

    persist_health_and_emotion(player_id, stats, deps)
    encounter_director.clear_context(player_id)
    return
  end

  -- Tier / max HP source (prefer encounter_info annotations)
  local tier = 0
  local max_hp = 0
  local is_wild = true

  if encounter_info then
    if encounter_info._tier ~= nil then tier = encounter_info._tier end
    if encounter_info._max_hp ~= nil then max_hp = encounter_info._max_hp end
    if encounter_info._is_wild ~= nil then is_wild = encounter_info._is_wild end
  end

  -- Fallback to Net max HP if needed
  if (not max_hp or max_hp <= 0) and deps and deps.Net and type(deps.Net.get_player_max_health) == "function" then
    max_hp = deps.Net.get_player_max_health(player_id)
  end

  dbg_print(player_id, string.format(
    "tier_source: encounter_info._tier=%s encounter_info._max_hp=%s",
    tostring(encounter_info and encounter_info._tier),
    tostring(encounter_info and encounter_info._max_hp)
  ))

  -- Reward calculation
  local score     = tonumber(stats.score) or 0
  local mob_count = mob_count_from_encounter(encounter_info)

  local per_score = (C.REWARDS.money_per_score and C.REWARDS.money_per_score[tier]) or 10
  local per_mob   = (C.REWARDS.money_per_mob   and C.REWARDS.money_per_mob[tier])   or 0

  local base_money = score * per_score
  local mob_money  = mob_count * per_mob
  local mult       = mob_count_multiplier(mob_count)

  local money_award = math.max(0, math.floor((base_money + mob_money) * mult + 0.5))

  dbg_print(player_id, string.format(
    "money_calc: tier=%d score=%d per_score=%d mobs=%d per_mob=%d base=%d mob=%d mult=%.2f award=%d",
    tier, score, per_score, mob_count, per_mob,
    math.floor(base_money + 0.5),
    math.floor(mob_money + 0.5),
    mult,
    money_award
  ))

  local frag_award = (C.REWARDS.bugfrags and C.REWARDS.bugfrags[tier]) or 0
  local crit_heal  = compute_crit_heal(player_id, max_hp, end_hp, tier, is_wild, did_run(stats))

  dbg_print(player_id, string.format(
    "rewards_roll: money_award=%d frag_award=%d crit_heal=%d",
    money_award, frag_award, crit_heal
  ))

  -- 1) APPLY MONEY AUTHORITATIVELY (Net wallet is source of truth)
  local cur_money = net_get_money(player_id, deps)
  local new_money = cur_money + money_award

  if money_award > 0 then
    local ok, err = net_set_money(player_id, deps, new_money)
    dbg_print(player_id, string.format(
      "money_apply: cur=%d +=%d => %d ok=%s err=%s",
      cur_money, money_award, new_money, tostring(ok), tostring(err)
    ))
  end

  -- 2) SHOW reward UI (display/sfx only; does not apply money)
  local rewards = {}
  if money_award > 0 then table.insert(rewards, { type = 0, value = money_award }) end
  if frag_award  > 0 then table.insert(rewards, { type = 3, value = frag_award  }) end
  if crit_heal   > 0 then table.insert(rewards, { type = 2, value = crit_heal   }) end

  if deps and deps.Net and type(deps.Net.send_player_battle_rewards) == "function" then
    deps.Net.send_player_battle_rewards(player_id, rewards)
    dbg_print(player_id, "send_player_battle_rewards: SENT entries=" .. tostring(#rewards))
  else
    dbg_print(player_id, "send_player_battle_rewards: MISSING")
  end

  -- 3) PERSIST final wallet into ezmemory (store final number; do NOT add again)
  if money_award > 0 then
    local ok = ezmem_set_money(player_id, deps, new_money)
    dbg_print(player_id, "money_persist: wallet=" .. tostring(new_money) .. " ok=" .. tostring(ok))
  end

  -- Health persistence (crit heal)
  local final_hp = end_hp + crit_heal
  if max_hp and max_hp > 0 and final_hp > max_hp then final_hp = max_hp end

  persist_health_and_emotion(player_id, { health = final_hp, emotion = stats.emotion }, deps)

  maybe_msg_player(
    player_id,
    string.format("tier=%d mobs=%d +$%d +%dHP", tier, mob_count, money_award, crit_heal),
    deps
  )

  encounter_director.clear_context(player_id)
end

return M
