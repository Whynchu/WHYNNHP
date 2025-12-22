--=====================================================
-- hot_streak.lua
--
-- Purpose:
--   Track player "HOT STREAK" based on battle scores.
--   If player gets 9+ three times in a row:
--     * activate hot streak
--     * each subsequent battle gets harder (+1 rank/count per fight)
--   Hot streak ends if:
--     * player loses (if caller can detect)
--     * score <= 2
--
-- Integration points:
--   1) encounter_director: call apply_bonus_to_plan(player_id, plan)
--   2) post-battle handler: call on_battle_end(player_id, score, did_win, deps)
--
-- Notes:
--   - Server should treat score as trusted ONLY if the server computes it.
--     If score is client-sent, clamp + sanity-check it.
--=====================================================

local C = require('scripts/whynn_core/loadout_scaling/scaling_config')

local M = {}

--=====================================================
-- State
--=====================================================

-- In-memory state keyed by player_id
--   nine_streak: consecutive 9+ results
--   hot_level: difficulty bonus currently applied (0 = off)
--   hot_active: true once activated
local state = {}

-- Optional persistence toggles (safe default: off)
local PERSIST = (C.HOT_STREAK and C.HOT_STREAK.persist) or false

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function dbg(player_id, msg)
  if not (C.DEBUG and C.DEBUG.enabled) then return end
  print(string.format("[hot_streak][%s] %s", tostring(player_id), msg))
end

local function get_s(player_id)
  local s = state[player_id]
  if s then return s end

  s = { nine_streak = 0, hot_level = 0, hot_active = false }
  state[player_id] = s
  return s
end

--=====================================================
-- Persistence helpers (optional)
--=====================================================

local function load_persisted(player_id, deps)
  if not PERSIST then return end
  if not deps or not deps.ezmemory then return end

  local ezmemory = deps.ezmemory
  local mem = ezmemory.get_player_memory(player_id)
  if not mem then return end

  local hs = mem.hot_streak
  if type(hs) ~= "table" then return end

  local s = get_s(player_id)
  s.nine_streak = tonumber(hs.nine_streak) or 0
  s.hot_level   = tonumber(hs.hot_level) or 0
  s.hot_active  = (hs.hot_active == true)

  dbg(player_id, "loaded persisted hot_streak=" ..
    string.format("{nine=%d, level=%d, active=%s}", s.nine_streak, s.hot_level, tostring(s.hot_active)))
end

local function save_persisted(player_id, deps)
  if not PERSIST then return end
  if not deps or not deps.ezmemory then return end

  local ezmemory = deps.ezmemory
  local mem = ezmemory.get_player_memory(player_id)
  if not mem then return end

  local s = get_s(player_id)
  mem.hot_streak = {
    nine_streak = s.nine_streak,
    hot_level   = s.hot_level,
    hot_active  = s.hot_active
  }

  -- Depending on your ezmemory patch, you may need to explicitly save.
  -- If your ezmemory auto-saves, this is still safe.
  if ezmemory.save_player_memory then
    ezmemory.save_player_memory(player_id)
  end
end

--=====================================================
-- Public API
--=====================================================

-- Call on login / transfer if you want persistence.
function M.on_player_ready(player_id, deps)
  load_persisted(player_id, deps)
end

-- Reset everything (manual/admin/debug)
function M.reset(player_id, deps)
  local s = get_s(player_id)
  s.nine_streak = 0
  s.hot_level   = 0
  s.hot_active  = false
  dbg(player_id, "reset")
  save_persisted(player_id, deps)
end

-- Update streak after a battle finishes.
-- score: expected 0..10 (clamped)
-- did_win: boolean or nil (if nil, we only use score rules)
function M.on_battle_end(player_id, score, did_win, deps)
  local s = get_s(player_id)

  local sc = tonumber(score) or 0
  sc = clamp(sc, 0, 10)

  -- Loss kills the streak immediately (if caller can detect loss)
  if did_win == false then
    dbg(player_id, "battle loss -> hot streak ends")
    s.nine_streak = 0
    s.hot_level   = 0
    s.hot_active  = false
    save_persisted(player_id, deps)
    return
  end

  -- Low score kills the streak immediately
  if sc <= 2 then
    dbg(player_id, "score " .. sc .. " <= 2 -> hot streak ends")
    s.nine_streak = 0
    s.hot_level   = 0
    s.hot_active  = false
    save_persisted(player_id, deps)
    return
  end

  -- Build streak on 9+
  if sc >= 9 then
    s.nine_streak = s.nine_streak + 1
    dbg(player_id, "score " .. sc .. " -> nine_streak=" .. s.nine_streak)

    -- Activate hot streak at 3-in-a-row
    if (not s.hot_active) and s.nine_streak >= 3 then
      s.hot_active = true
      s.hot_level  = 1
      dbg(player_id, "HOT STREAK ACTIVATED level=1")
    elseif s.hot_active then
      -- Every fight while active bumps difficulty by +1
      s.hot_level = s.hot_level + 1
      dbg(player_id, "HOT STREAK leveled up -> " .. s.hot_level)
    end

    save_persisted(player_id, deps)
    return
  end

  -- Neutral score (3..8):
  -- You said streak continues until loss or <=2, so do nothing here.
  -- If you want neutral scores to break the 9+ chain but keep hot_active:
  --   s.nine_streak = 0
  dbg(player_id, "score " .. sc .. " neutral -> no change")
  save_persisted(player_id, deps)
end

-- Apply bonus to an encounter plan BEFORE spawning.
-- plan fields are up to you, but based on your director:
--   plan.desired_rank, plan.count_min, plan.count_max, etc.
function M.apply_bonus_to_plan(player_id, plan)
  if not plan then return plan end

  local s = get_s(player_id)
  if not s.hot_active or s.hot_level <= 0 then
    return plan
  end

  local cfg = (C.HOT_STREAK or {})
  local max_level = tonumber(cfg.max_level) or 6
  local level = clamp(s.hot_level, 1, max_level)

  -- What do we buff?
  local bump_rank  = (cfg.bump_rank ~= false)   -- default true
  local bump_count = (cfg.bump_count ~= false)  -- default true

  if bump_rank and plan.desired_rank then
    plan.desired_rank = plan.desired_rank + level
  end

  if bump_count then
    if plan.count_min then plan.count_min = plan.count_min + level end
    if plan.count_max then plan.count_max = plan.count_max + level end
  end

  -- Optional: tell the encounter script "this fight is hot"
  plan.hot_streak_level = level

  return plan
end

-- Debug helper for printing
function M.get_debug(player_id)
  local s = get_s(player_id)
  return {
    nine_streak = s.nine_streak,
    hot_active  = s.hot_active,
    hot_level   = s.hot_level
  }
end

return M
