--=====================================================
-- Loadout-Truth Scaling :: Master Configuration
--
-- Defines ALL balance knobs for:
--   * Player power evaluation
--   * Tier & rank gating
--   * Encounter pack sizing (counts)   <-- ADDED (C.PACK)
--   * Rewards & drops
--   * Post-battle survivability systems
--
-- Design principles:
--   - HP establishes a HARD FLOOR (cannot fake weakness)
--   - Loadout refines difficulty (optional, soft trust)
--   - No whitelists, no package inspection, no lies
--=====================================================

local C = {}

--=====================================================
-- DIFFICULTY (GLOBAL)
--=====================================================
-- Optional global difficulty nudge used by encounter_director.
-- 1.0 = neutral
-- <=0.90 => -1 desired rank
-- >=1.10 => +1 desired rank
--
C.DIFFICULTY = 1.0

--=====================================================
-- HP (AUTHORITATIVE / HARD FLOOR)
--=====================================================
-- Used as a neutral comparison point only.
-- Players are NEVER clamped to this.
--
C.BASE_HP     = 100
C.HPMEM_BONUS = 20

--=====================================================
-- HP FLOOR (HARD GATE)
--=====================================================
-- HP cannot be faked.
-- Establishes MINIMUM tier regardless of loadout.
--
C.HP_FLOOR = {
  { tier = 0, max = 1.25 },
  { tier = 1, max = 1.75 },
  { tier = 2, max = 2.50 },
  { tier = 3, max = math.huge },
}

--=====================================================
-- MAX HP -> FLOOR TIER
--=====================================================
-- Absolute HP mapping fallback.
--
C.HP_FLOOR_BY_MAX_HP = {
  { hp = 100,  tier = 0 },
  { hp = 250,  tier = 1 },
  { hp = 600,  tier = 2 },
  { hp = 1200, tier = 3 },
  { hp = 2000, tier = 4 },
}

--=====================================================
-- MAX HP -> FLOOR TIER
--=====================================================

HOT_STREAK = {
  persist    = true, -- set true if you want streak saved via ezmemory
  max_level  = 6,     -- cap to prevent infinite escalation
  bump_rank  = true,  -- rank +N
  bump_count = true   -- mob count +N
}


--=====================================================
-- MOB GATING (RANK FLOORS)
--=====================================================
-- Final hard gate.
-- No encounter may roll below this.
--
C.RANK_FLOOR_BY_TIER = {
  [0] = 1,
  [1] = 2,
  [2] = 2,
  [3] = 3,
  [4] = 5,
}

--=====================================================
-- PACK SIZING (ENCOUNTER COUNTS)
--=====================================================
-- Central place for "how many mobs" per encounter.
-- encounter_director reads this and applies HP safety caps.
--
-- by_tier:
--   [tier] = { min = X, max = Y }
--
-- hp_caps:
--   If hp_max <= cap.hp_max then plan.max is clamped to cap.max_count
--   (and optionally min_count too).
--   First match wins.
--
-- hp_nudges:
--   Optional knobs for very high HP (rank/spike nudges).
--
C.PACK = {
  -- Default pack ranges per tier
  by_tier = {
    [0] = { min = 2, max = 2 },
    [1] = { min = 2, max = 4 },
    [2] = { min = 2, max = 5 },
    [3] = { min = 3, max = 5 },
    [4] = { min = 3, max = 6 }, -- tier4+ fallback
  },

  -- Safety caps based on max HP
  hp_caps = {
    { hp_max = 120, max_count = 2, min_count = 1, note = "lowhp_cap" },
    { hp_max = 160, max_count = 2, note = "hp160_cap" },
  },

  -- Extra allowances for very high HP (optional)
  hp_nudges = {
    { hp_min = 900,  tier_min = 3, spike_max = 2, spike_chance_add = 0.06, note = "hp900_spike2" },
    { hp_min = 1200, tier_min = 3, desired_rank_add = 1, note = "hp_nudge" },
  },

  -- Final safety clamps for counts
  clamp = {
    min_lo = 1,
    min_hi = 3,
    max_hi = 4,
  },
}

--=====================================================
-- REWARD ECONOMY
--=====================================================
-- No rewards for movement.
-- No rewards for stalling.
--
C.REWARDS = {

  money_per_score = {
    [0]=20, [1]=18, [2]=16, [3]=15, [4]=14,
  },

  bugfrags = {
    [0]=0, [1]=0, [2]=2, [3]=3, [4]=4,
  },

  chip_drop_chance = {
    [0]=0.22, [1]=0.22, [2]=0.22, [3]=0.22, [4]=0.22,
  },

  money_per_mob = {
    [0]=0,  [1]=15, [2]=20, [3]=25,
    [4]=30, [5]=35, [6]=40, [7]=45,
  },

  quality_weights = {
    [0] = { low=94, mid=5,  high=1 },
    [1] = { low=88, mid=10, high=2 },
    [2] = { low=82, mid=15, high=3 },
    [3] = { low=75, mid=20, high=5 },
    [4] = { low=70, mid=23, high=7 },
  },
}

--=====================================================
-- CRITICAL HP POST-BATTLE HEAL
--=====================================================
C.CRIT_HEAL = {
  enabled       = true,
  wild_only     = false,

  threshold_pct = 0.30,
  floor_pct     = 0.10,

  min_chance    = 0.20,
  max_chance    = 0.95,

  min_heal_pct  = 0.06,
  max_heal_pct  = 0.50,

  cooldown_s    = 45,

  tier_mult_per = 0.03,
  wild_mult     = 1.00,

  min_heal_abs  = 1,
  max_heal_abs  = 500,
}

--=====================================================
-- CLIENT LOADOUT USAGE
--=====================================================
-- If false:
--   * Buster + folder telemetry is ignored
--   * Scaling is HP-only (safe mode)
-- If true:
--   * Telemetry is blended into power score
--
C.USE_CLIENT_LOADOUT = true

--=====================================================
-- POWER MODEL WEIGHTS (FUTURE-READY)
--=====================================================
-- Defines how much each system contributes
-- to the blended power score.
--
-- NOTE:
--   v1 relies primarily on HP floor logic.
--   These weights are preserved for v2+.
--
C.POWER_W_HP     = 0.20
C.POWER_W_BUSTER = 0.45
C.POWER_W_FOLDER = 0.35

--=====================================================
-- POWER -> TIER THRESHOLDS (P-SCORE)
--=====================================================
-- Used once full blended power is enabled.
--
C.TIER_P_THRESHOLDS = {
  { tier = 0, max = 1.15 },
  { tier = 1, max = 1.55 },
  { tier = 2, max = 2.10 },
  { tier = 3, max = math.huge },
}

--=====================================================
-- CLIENT TELEMETRY TRUST WINDOW
--=====================================================
-- max_age_s:
--   Rejects stale reports (prevents spoof caching)
--
-- trust_client:
--   true  = accept sanitized telemetry (testing)
--   false = ignore all telemetry (production-safe)
--
C.TELEMETRY = {
  max_age_s    = 15,
  trust_client = true,
}

--=====================================================
-- TELEMETRY SANITY LIMITS
--=====================================================
-- Absolute clamps to prevent nonsense values.
-- These do NOT normalize; they only bound.
--
C.TELEMETRY_LIMITS = {
  atk_min = 1,   atk_max = 5,
  cmult_min = 10, cmult_max = 50,
  spd_min = 1.0, spd_max = 5.0,

  folder_score_min = 1.0,
  folder_score_max = 5.0,

  chip_count_min = 1,
  chip_count_max = 60,
}

--=====================================================
-- BUSTER POWER MODEL
--=====================================================
-- Weighted linear score.
-- Baseline buster ~= 1.70
--
C.BUSTER = {
  weights = {
    attack = 1.00,
    charge = 0.35,
    rapid  = 0.35,
  },

  -- atk=1, charge=1, rapid=1
  baseline_score = 1.70,
}

--=====================================================
-- FOLDER POWER MODEL
--=====================================================
-- Folder score assumed pre-normalized.
--
C.FOLDER = {
  baseline_score = 1.0,
}

--=====================================================
-- DEBUG
--  level:
--    0 = off
--    1 = decisions (tier/plan/applied changes)
--    2 = lifecycle (joins/transfers/hooks)
--    3 = verbose (telemetry + sniff + breakdown spam)
--=====================================================
C.DEBUG = {
  enabled = true,
  level = 1,
  to_player = false,

  -- Feature gates (generally used at level >= 3)
  power_breakdown = false,
  telemetry = false,
  sniff_events = false,
}

--=====================================================
-- Debug helpers (use everywhere)
--=====================================================
function C.dbg_enabled(level)
  if not (C.DEBUG and C.DEBUG.enabled) then return false end
  local lvl = tonumber(C.DEBUG.level) or 0
  return lvl >= (tonumber(level) or 1)
end

function C.dbg_print(level, tag, msg)
  if not C.dbg_enabled(level) then return end
  tag = tag or "core"
  print(string.format("[loadout_scaling][%s] %s", tostring(tag), tostring(msg)))
end

function C.dbg_player(level, player_id, tag, msg, deps)
  if not C.dbg_enabled(level) then return end
  if not (C.DEBUG and C.DEBUG.to_player) then return end
  if deps and deps.Net and deps.Net.message_player then
    deps.Net.message_player(
      player_id,
      string.format("[loadout_scaling][%s] %s", tostring(tag or "core"), tostring(msg))
    )
  end
end

return C
