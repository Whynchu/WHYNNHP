--=====================================================
-- server/scripts/encounter_lib/factory.lua
--=====================================================

local mathlib  = require('scripts/encounter_lib/math')
local ranks    = require('scripts/encounter_lib/ranks')
local pools    = require('scripts/encounter_lib/pools')
local tileslib = require('scripts/encounter_lib/tiles')

local M = {}

--=====================================================
-- Small helpers
--=====================================================

local function clamp(x, lo, hi)
  return mathlib.clamp(x, lo, hi)
end

local function log_call(log_fn, level, fmt, ...)
  if type(log_fn) ~= "function" then return end
  log_fn(level, fmt, ...)
end

local function adjust_rank_for_swarm(desired_rank, count, cfg)
  local thresh  = tonumber(cfg.swarm_rank_penalty_count) or 4
  local penalty = tonumber(cfg.swarm_rank_penalty) or 1
  local maxr    = tonumber(cfg.max_target_rank) or 7

  if count >= thresh then
    return clamp(desired_rank - penalty, 1, maxr)
  end
  return desired_rank
end

local function roll_pack_count(plan, cfg)
  local lo = tonumber(plan and plan.min_count) or tonumber(cfg.min_count) or 1
  local hi = tonumber(plan and plan.max_count) or tonumber(cfg.max_count) or lo

  local max_pack = tonumber(cfg.max_pack_size) or 3
  lo = clamp(lo, 1, max_pack)
  hi = clamp(hi, lo, max_pack)

  return math.random(lo, hi)
end

local function compute_desired_rank(plan, cfg, count)
  local maxr = tonumber(cfg.max_target_rank) or 7
  local desired = tonumber(plan and plan.desired_rank) or tonumber(cfg.desired_rank) or 1
  desired = clamp(desired, 1, maxr)
  desired = adjust_rank_for_swarm(desired, count, cfg)
  return desired
end

local function apply_rank_cap(rolled_rank, plan, cfg)
  local maxr = tonumber(cfg.max_target_rank) or 7
  local r = tonumber(rolled_rank) or 1

  local cap = tonumber(plan and plan.rank_cap)
  if cap and cap > 0 then
    r = clamp(r, 1, cap)
  end

  return clamp(r, 1, maxr)
end

local function validate_enemy_pool(cfg)
  if type(cfg.enemy_pool) ~= "table" then
    error("factory: cfg.enemy_pool must be a table")
  end
end

-- Normalize pool pick to a mob name string.
local function mob_name_from_pick(pick)
  local t = type(pick)
  if t == "string" then
    return pick
  end
  if t == "table" then
    -- common patterns
    if type(pick.name) == "string" then return pick.name end
    if type(pick.mob)  == "string" then return pick.mob end
    if type(pick.id)   == "string" then return pick.id end
  end
  -- last resort
  return tostring(pick)
end

--=====================================================
-- Public API
--=====================================================

function M.build_one(cfg, ctx)
  if type(cfg) ~= "table" then error("factory.build_one: cfg must be a table") end
  if type(ctx) ~= "table" then error("factory.build_one: ctx must be a table") end

  validate_enemy_pool(cfg)

  local player_id  = ctx.player_id
  local plan       = ctx.plan or {}
  local hp         = tonumber(ctx.hp) or 0
  local tier       = tonumber(ctx.tier) or tonumber(plan.tier) or 0
  local results_cb = ctx.results_cb
  local roll_rank  = ctx.roll_rank
  local log_fn     = ctx.log

  if player_id == nil then
    error("factory.build_one: missing ctx.player_id")
  end
  if type(results_cb) ~= "function" then
    error("factory.build_one: missing ctx.results_cb (function)")
  end
  if type(roll_rank) ~= "function" then
    error("factory.build_one: missing ctx.roll_rank (function)")
  end

  local count = roll_pack_count(plan, cfg)
  local desired_rank = compute_desired_rank(plan, cfg, count)

  log_call(log_fn, 2,
    "[encounter][%s] build: hp=%d desired_rank=%d count=%d tier=%d",
    tostring(player_id),
    tonumber(hp) or -1,
    tonumber(desired_rank) or -1,
    tonumber(count) or -1,
    tonumber(tier) or -1
  )

  local tile_list = cfg.enemy_tiles or tileslib.DEFAULT_ENEMY_TILES_RIGHT
  local chosen = tileslib.pick_tiles(tile_list, count)
  local positions = tileslib.build_positions_from_tiles(chosen)

  local enemies = {}
  for i = 1, count do
    local pick = pools.weighted_pick(cfg.enemy_pool)
    local mob_name = mob_name_from_pick(pick)

    local rolled = roll_rank(plan, desired_rank, cfg)
    rolled = apply_rank_cap(rolled, plan, cfg)

    local picked_rank = ranks.safe_rank(mob_name, rolled, cfg.allowed_ranks)

    log_call(log_fn, 2,
      "[encounter][%s] mob=%s rolled=%d picked_rank=%d",
      tostring(player_id),
      tostring(mob_name),
      tonumber(rolled) or -1,
      tonumber(picked_rank) or -1
    )

    enemies[#enemies + 1] = { name = mob_name, rank = picked_rank }
  end

  return {
    name = (cfg.encounter_name_prefix or "Default") .. "_R" .. desired_rank .. "_N" .. count,
    path = cfg.scenario,
    scenario = cfg.scenario,
    weight = cfg.weight or 10,

    _tier = tier,
    _max_hp = hp,

    enemies = enemies,
    positions = positions,
    results_callback = results_cb,
  }
end

function M.build_many(cfg, ctx, n)
  if type(cfg) ~= "table" then error("factory.build_many: cfg must be a table") end
  if type(ctx) ~= "table" then error("factory.build_many: ctx must be a table") end

  local maxn = tonumber(cfg.max_return_count) or 6
  n = tonumber(n) or 3
  n = clamp(n, 1, maxn)

  local out = {}
  for i = 1, n do
    out[i] = M.build_one(cfg, ctx)
  end
  return out
end

return M
