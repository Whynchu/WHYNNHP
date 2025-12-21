--=====================================================
-- player_telemetry.lua
--
-- Purpose:
--   Server-side, short-lived cache for client-reported loadout telemetry.
--
-- Stores (per player_id):
--   * buster_attack
--   * charged_attack_multiplier
--   * speed              (buster rapid/firing rate, NOT movement speed)
--   * folder_score
--   * chip_count
--   * folder_hash
--   * ts                 (server time; used for freshness gating)
--
-- Notes:
--   - In-memory only (resets on server restart).
--   - Freshness enforced by get_fresh(max_age_s).
--   - Payload accepts common aliases, but semantics stay strict.
--=====================================================

local C = require('scripts/whynn_core/loadout_scaling/scaling_config')

local M = {}

-- [player_id] = {
--   buster_attack,
--   charged_attack_multiplier,
--   speed,
--   folder_score,
--   chip_count,
--   folder_hash,
--   ts
-- }
local stats = {}

--=====================================================
-- Small conversion helpers
--=====================================================

local function now()
  return os.time()
end

local function to_num(x, fallback)
  local n = tonumber(x)
  if n == nil then return fallback end
  return n
end

local function to_str(x)
  if x == nil then return "" end
  return tostring(x)
end

--=====================================================
-- Public API
--=====================================================

function M.set(player_id, payload)
  if not player_id or type(payload) ~= "table" then return end

  local atk =
    payload.buster_attack or
    payload.attack_level or
    payload.atk

  local cmult =
    payload.charged_attack_multiplier or
    payload.charge_multiplier or
    payload.cmult

  -- IMPORTANT: "speed" here means buster rapid / firing rate.
  -- Accept common aliases, but DO NOT feed movement speed into this.
  local spd =
    payload.speed or
    payload.buster_speed or
    payload.rapid or
    payload.rapid_level

  local chip_count =
    payload.chip_count or
    payload.folder_count or
    payload.chips

  local rec = {
    buster_attack             = to_num(atk, 1),
    charged_attack_multiplier = to_num(cmult, 10),
    speed                     = to_num(spd, 1.0),

    folder_score              = to_num(payload.folder_score, 1.0),
    chip_count                = (chip_count ~= nil) and to_num(chip_count, nil) or nil,
    folder_hash               = to_str(payload.folder_hash),

    -- ALWAYS store server-time freshness (never trust client clocks)
    ts                        = now(),
  }

  stats[player_id] = rec

  -- Debug (verbose only)
  M._dbg_set(player_id, rec)
end

function M.get(player_id)
  return stats[player_id]
end

function M.get_fresh(player_id, max_age_s)
  local default_age = 15
  if C and C.TELEMETRY and C.TELEMETRY.max_age_s then
    default_age = to_num(C.TELEMETRY.max_age_s, 15)
  end
  max_age_s = to_num(max_age_s, default_age)

  local s = stats[player_id]
  if not s or not s.ts then return nil end

  if (now() - s.ts) > max_age_s then
    return nil
  end

  return s
end

function M.invalidate(player_id)
  if not player_id then return end
  if stats[player_id] then
    stats[player_id].ts = 0
  end
end

function M.clear(player_id)
  if not player_id then return end
  stats[player_id] = nil
end

-- Clear all cached telemetry without rebinding the local table.
-- This preserves any references (present or future).
function M.clear_all()
  for k in pairs(stats) do
    stats[k] = nil
  end
end

--=====================================================
-- DEBUG
--=====================================================

function M._dbg_set(player_id, rec)
  -- Only print telemetry spam when BOTH:
  --   - debug level is verbose
  --   - telemetry flag is enabled
  if not (C and C.dbg_enabled and C.dbg_enabled(3)) then return end
  if not (C.DEBUG and C.DEBUG.telemetry) then return end

  C.dbg_print(3, "telemetry", string.format(
    "[%s] set atk=%s cmult=%s speed=%s folder_score=%s chip_count=%s hash=%s ts=%s",
    tostring(player_id),
    tostring(rec and rec.buster_attack),
    tostring(rec and rec.charged_attack_multiplier),
    tostring(rec and rec.speed),
    tostring(rec and rec.folder_score),
    tostring(rec and rec.chip_count),
    tostring(rec and rec.folder_hash),
    tostring(rec and rec.ts)
  ))
end

return M
