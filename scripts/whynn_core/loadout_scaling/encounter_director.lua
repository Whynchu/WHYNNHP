--=====================================================
-- encounter_director.lua
--
-- Purpose:
--   Decide an encounter "plan" per player based on computed power:
--     * tier
--     * desired enemy rank band (with jitter + rare spikes)
--     * enemy count range (pack size)
--
-- This module does NOT spawn enemies by itself.
-- It produces a plan for encounter scripts to consume.
--
-- Key rules:
--   - Tier comes from player_power.compute()
--   - HP fairness caps prevent low-HP players from getting unfair packs
--   - Loadout cannot force scary packs at low HP
--   - Optional global difficulty nudges desired_rank by +/- 1
--   - RANK_FLOOR_BY_TIER is enforced as a hard floor on desired_rank
--
-- In-memory:
--   encounter_ctx[player_id] stores the plan and power snapshot
--=====================================================

local player_power = require('scripts/whynn_core/loadout_scaling/player_power')
local C            = require('scripts/whynn_core/loadout_scaling/scaling_config')

local M = {}

-- In-memory encounter context keyed by player_id
local encounter_ctx = {}

--=====================================================
-- Small helpers
--=====================================================

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function rand01()
  return math.random()
end

-- Default difficulty is 1.0 (neutral).
-- NOTE: This is a "nudge" knob, not a multiplier applied everywhere.
local function difficulty_mult()
  local d = tonumber(C and C.DIFFICULTY) or 1.0
  if d <= 0 then return 1.0 end
  return d
end

-- Config-driven hard rank floors by tier:
--   C.RANK_FLOOR_BY_TIER[tier] => min desired_rank
local function rank_floor_for_tier(tier)
  if not (C and C.RANK_FLOOR_BY_TIER) then return 1 end
  local t = tonumber(tier) or 0
  return tonumber(C.RANK_FLOOR_BY_TIER[t]) or 1
end

--=====================================================
-- Rank rolling
--=====================================================
-- Roll a rank using:
--   1) jitter: +/- rank_jitter around desired_rank
--   2) spike: rare upward bonus (1..spike_max)
--
function M.roll_rank(plan)
  if type(plan) ~= "table" then return 1 end

  local base = tonumber(plan.desired_rank) or 1
  local j    = tonumber(plan.rank_jitter) or 0

  base = clamp(base, 1, 7)
  j    = clamp(j, 0, 2)

  -- 1) Jitter first
  local jittered = base
  if j > 0 then
    jittered = base + math.random(-j, j)
  end

  -- 2) Spike second (rare upward push)
  local spike_chance = tonumber(plan.spike_chance) or 0.0
  local spike_max    = tonumber(plan.spike_max) or 0

  spike_chance = clamp(spike_chance, 0.0, 1.0)
  spike_max    = clamp(spike_max, 0, 2)

  if spike_max > 0 and spike_chance > 0 and rand01() < spike_chance then
    local bonus = math.random(1, spike_max)
    jittered = jittered + bonus
  end

  return clamp(jittered, 1, 7)
end

--=====================================================
-- Plan computation ("the tuning brain") [PUBLIC]
--=====================================================

function M.plan_from_power(power)
  local tier   = tonumber(power and power.final_tier) or 0
  local hp_max = tonumber((power and (power.max_hp or power.hp_max)) or 0) or 0

  -- Default plan skeleton (overwritten by tier logic)
  local plan = {
    tier = tier,

    desired_rank = 1,
    rank_jitter  = 1,
    min_count    = 1,
    max_count    = 2,

    spike_chance = 0.00,
    spike_max    = 0,

    note = "",
  }

  -- --------------------------------------------------
  -- Core tier bands
  -- --------------------------------------------------
  if tier <= 0 then
    plan.desired_rank = 1
    plan.rank_jitter  = 0
    plan.min_count    = 2
    plan.max_count    = 2
    plan.spike_chance = 0.00
    plan.spike_max    = 0
    plan.note = "tier0: rank1 pack"

  elseif tier == 1 then
    plan.desired_rank = 2
    plan.rank_jitter  = 0
    plan.min_count    = 2
    plan.max_count    = 2
    plan.spike_chance = 0.18
    plan.spike_max    = 1
    plan.note = "tier1: rank2 mostly (+rare 3)"

  elseif tier == 2 then
    plan.desired_rank = 2
    plan.rank_jitter  = 0
    plan.min_count    = 2
    plan.max_count    = 3
    plan.spike_chance = 0.25
    plan.spike_max    = 1
    plan.note = "tier2: softened rank2 (+sometimes 3)"

  elseif tier == 3 then
    plan.desired_rank = 3
    plan.rank_jitter  = 1
    plan.min_count    = 2
    plan.max_count    = 3
    plan.spike_chance = 0.20
    plan.spike_max    = 1
    plan.note = "tier3: rank3-4 capped packs"

  else
    plan.desired_rank = 4
    plan.rank_jitter  = 1
    plan.min_count    = 3
    plan.max_count    = 4
    plan.spike_chance = 0.22
    plan.spike_max    = 1
    plan.note = "tier4+: rank4-ish, bigger packs"
  end

  -- --------------------------------------------------
  -- HP fairness constraints (pack safety caps)
  -- --------------------------------------------------
  if hp_max <= 120 then
    plan.max_count = 2
    plan.min_count = 1

    if tier <= 2 then
      plan.spike_max = 1
    end

    plan.note = plan.note .. " +lowhp_cap"

  elseif hp_max <= 160 then
    plan.max_count = math.min(plan.max_count, 2)
    plan.note = plan.note .. " +hp160_cap"
  end

  -- --------------------------------------------------
  -- HP nudges (only when it's legit)
  -- --------------------------------------------------
  if hp_max >= 900 and tier >= 3 then
    plan.spike_max = 2
    plan.spike_chance = plan.spike_chance + 0.06
    plan.note = plan.note .. " +hp900_spike2"
  end

  if hp_max >= 1200 and tier >= 3 then
    plan.desired_rank = plan.desired_rank + 1
    plan.note = plan.note .. " +hp_nudge"
  end

  -- --------------------------------------------------
  -- Global difficulty nudge (optional)
  -- --------------------------------------------------
  local d = difficulty_mult()
  if d ~= 1.0 then
    local adj = 0
    if d <= 0.90 then
      adj = -1
    elseif d >= 1.10 then
      adj = 1
    end

    if adj ~= 0 then
      plan.desired_rank = plan.desired_rank + adj
    end

    -- Always record the knob value for debugging
    plan.note = plan.note .. string.format(" diff=%.2f", d)
  end

  -- --------------------------------------------------
  -- Hard rank floor by tier (config)
  -- --------------------------------------------------
  local floor = rank_floor_for_tier(tier)
  if plan.desired_rank < floor then
    plan.desired_rank = floor
    plan.note = plan.note .. " +rank_floor"
  end

  -- --------------------------------------------------
  -- Final clamps (BN ranks, pack safety)
  -- --------------------------------------------------
  plan.desired_rank = clamp(plan.desired_rank, 1, 7)
  plan.rank_jitter  = clamp(plan.rank_jitter, 0, 2)
  plan.min_count    = clamp(plan.min_count, 1, 3)
  plan.max_count    = clamp(plan.max_count, plan.min_count, 3)
  plan.spike_max    = clamp(plan.spike_max, 0, 2)
  plan.spike_chance = clamp(plan.spike_chance, 0.0, 0.60)

  return plan
end

--=====================================================
-- Public API: encounter lifecycle
--=====================================================

function M.begin_encounter(player_id, deps, meta)
  local power = player_power.compute(player_id, deps)
  local plan  = M.plan_from_power(power)

  local ctx = {
    started_at = os.time(),

    tier  = power.final_tier,
    power = power,
    plan  = plan,

    is_wild = (meta and meta.is_wild) ~= false,
    area_id = meta and meta.area_id or nil,
  }

  encounter_ctx[player_id] = ctx

  -- Debug lives at bottom (house style)
  M._dbg_begin(player_id, ctx)

  return ctx
end

function M.get_context(player_id)
  return encounter_ctx[player_id]
end

function M.clear_context(player_id)
  encounter_ctx[player_id] = nil
end

-- Convenience: compute plan without writing ctx
function M.get_plan(player_id, deps, meta)
  local power = player_power.compute(player_id, deps)
  local plan  = M.plan_from_power(power)
  return plan, power
end

-- Basic tier table selection helper
function M.select_encounter_for_tier(tier, encounter_tables)
  local t = encounter_tables[tier] or encounter_tables[0]
  return t
end

--=====================================================
-- DEBUG (keep at bottom)
--=====================================================

function M._dbg_enabled(level)
  return C and type(C.dbg_enabled) == "function" and C.dbg_enabled(level)
end

function M._dbg_print(level, tag, msg)
  if not M._dbg_enabled(level) then return end
  if C and type(C.dbg_print) == "function" then
    -- Expected signature in this stack: dbg_print(level, tag, msg)
    C.dbg_print(level, tag, msg)
  else
    -- Failsafe
    print(tostring(msg))
  end
end

function M._dbg_begin(player_id, ctx)
  local diff = difficulty_mult()

  -- Level 1: decision summary (keep it short)
  M._dbg_print(1, "director", string.format(
    "[%s] tier=%d P=%.3f hp_ratio=%.3f hp_max=%s diff=%.2f plan: rank=%d j=%d cnt=%d..%d spike=%.2f +%d (%s)",
    tostring(player_id),
    tonumber(ctx.power and ctx.power.final_tier) or -1,
    tonumber(ctx.power and ctx.power.P) or -1,
    tonumber(ctx.power and ctx.power.hp_ratio) or -1,
    tostring((ctx.power and (ctx.power.max_hp or ctx.power.hp_max)) or "?"),
    tonumber(diff) or 1.0,
    tonumber(ctx.plan and ctx.plan.desired_rank) or -1,
    tonumber(ctx.plan and ctx.plan.rank_jitter) or -1,
    tonumber(ctx.plan and ctx.plan.min_count) or -1,
    tonumber(ctx.plan and ctx.plan.max_count) or -1,
    tonumber(ctx.plan and ctx.plan.spike_chance) or 0,
    tonumber(ctx.plan and ctx.plan.spike_max) or 0,
    tostring((ctx.plan and ctx.plan.note) or "")
  ))
end

return M
