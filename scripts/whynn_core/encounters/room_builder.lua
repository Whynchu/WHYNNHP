--=====================================================
-- server/scripts/whynn_core/encounters/room_builder.lua
--
-- Purpose:
--   Room encounter builder that wires:
--     * deps
--     * director plan/power
--     * safety caps
--     * results callback
--   Then delegates actual construction to encounter_lib/factory.lua
--=====================================================

local ezmemory  = require('scripts/ezlibs-scripts/ezmemory')
local telemetry = require('scripts/whynn_core/loadout_scaling/player_telemetry')

local encounterDir = require('scripts/whynn_core/loadout_scaling/encounter_director')
local rewardDir    = require('scripts/whynn_core/loadout_scaling/reward_director')
local C            = require('scripts/whynn_core/loadout_scaling/scaling_config')

local mathlib  = require('scripts/encounter_lib/math')
local callbacks= require('scripts/encounter_lib/callbacks')
local factory  = require('scripts/encounter_lib/factory')

local M = {}

--=====================================================
-- Small helpers
--=====================================================

local function clamp(x, lo, hi)
  return mathlib.clamp(x, lo, hi)
end

local function dbg_enabled(level)
  return C and type(C.dbg_enabled) == "function" and C.dbg_enabled(level)
end

local function dbg_print(level, fmt, ...)
  if not dbg_enabled(level) then return end
  local msg = string.format(fmt, ...)
  if C and type(C.dbg_print) == "function" then
    C.dbg_print(level, "room_builder", msg)
  else
    print(msg)
  end
end

local function get_deps()
  return { Net = Net, ezmemory = ezmemory }
end

local function get_plan_and_power(player_id, cfg, deps)
  local meta = { is_wild = (cfg.is_wild ~= false), area_id = cfg.area_id or "default" }
  local plan, power = encounterDir.get_plan(player_id, deps, meta)

  if type(plan) ~= "table" then
    plan = { tier = 0, desired_rank = 1, min_count = 1, max_count = 2 }
  end
  if type(power) ~= "table" then
    power = { final_tier = 0, max_hp = deps.Net.get_player_max_health(player_id) }
  end

  return plan, power
end

local function maybe_log_telemetry_fresh(player_id)
  if not (C and C.TELEMETRY and telemetry and telemetry.get_fresh) then return end

  local max_age = tonumber(C.TELEMETRY.max_age_s) or 15
  local fresh = telemetry.get_fresh(player_id, max_age)
  if not fresh then
    dbg_print(2,
      "[%s] telemetry NOT fresh (>%ds) - fallback scaling may be used",
      tostring(player_id),
      max_age
    )
  end
end

-- Director-owned rank roll wrapper.
-- Signature matches factory expectations: roll_rank(plan, desired_rank, cfg) -> integer
local function roll_rank_via_director(plan, desired_rank, cfg)
  -- Director owns jitter/spikes/caps. Factory still applies hard room cap + allowed ranks.
  return encounterDir.roll_rank(plan)
end

--=====================================================
-- Public API
--=====================================================

function M.build_encounters_for_room(player_id, cfg)
  local deps = get_deps()

  maybe_log_telemetry_fresh(player_id)

  local plan, power = get_plan_and_power(player_id, cfg, deps)

  local hp = deps.Net.get_player_max_health(player_id)

  -- Hard room safety: no rank 2+ until this HP threshold.
  -- This stays here because it is room policy. Director may also enforce its own caps.
  if (tonumber(hp) or 0) <= (tonumber(cfg.rank_cap_hp_threshold) or 120) then
    plan.rank_cap = math.min(tonumber(plan.rank_cap) or 999, 1)
  end

  local results_cb = callbacks.results_callback_loadout_truth(Net, ezmemory, rewardDir)

  local n = tonumber(cfg.return_count) or 3
  n = clamp(n, 1, tonumber(cfg.max_return_count) or 6)

  -- One ctx used for all candidate builds this tick.
  local ctx = {
    player_id  = player_id,
    hp         = hp,
    tier       = tonumber(plan.tier) or tonumber(power and power.final_tier) or 0,
    plan       = plan,
    power      = power,
    results_cb = results_cb,
    roll_rank  = roll_rank_via_director,
    log        = function(level, fmt, ...)
      dbg_print(level, fmt, ...)
    end,
  }

  return factory.build_many(cfg, ctx, n)
end

return M
