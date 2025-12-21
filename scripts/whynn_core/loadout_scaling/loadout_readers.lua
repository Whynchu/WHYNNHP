--=====================================================
-- loadout_readers.lua
--
-- Purpose:
--   Resolve buster and folder telemetry for scaling by checking sources
--   in a strict priority order:
--
--   BUSTER priority:
--     0) Fresh client telemetry (player_telemetry)       -> "client_report" / "client_clamped"
--     1) Server-trusted package registry (package_stats) -> "package"
--     2) Legacy ezmemory keys                            -> "ezmemory"
--     3) Stub baseline                                   -> "stub"
--
--   FOLDER priority:
--     0) Fresh client telemetry (player_telemetry)       -> "client_report" / "client_clamped"
--     1) Legacy ezmemory key                             -> "ezmemory"
--     2) Stub baseline                                   -> "stub"
--
-- Notes:
--   - "client_clamped" means values were out-of-range and clamped.
--     Downstream systems may trust-weight it lower.
--   - Buster "speed" here means firing rate/rapid, NOT movement speed.
--=====================================================

local helpers   = require('scripts/ezlibs-scripts/helpers')
local telemetry = require('scripts/whynn_core/loadout_scaling/player_telemetry')
local C         = require('scripts/whynn_core/loadout_scaling/scaling_config')

local M = {}

--=====================================================
-- Small helpers
--=====================================================

local function safe_call(fn, ...)
  if type(fn) ~= "function" then return false, nil end
  local ok, res = pcall(fn, ...)
  if not ok then return false, nil end
  return true, res
end

local function limits()
  return (C and C.TELEMETRY_LIMITS) or {}
end

local function clamp_num(x, lo, hi, fallback)
  local n = tonumber(x)
  if n == nil then return fallback, false end
  if lo ~= nil and n < lo then return lo, true end
  if hi ~= nil and n > hi then return hi, true end
  return n, false
end

local function telemetry_enabled()
  -- Gate telemetry at the master config:
  --   USE_CLIENT_LOADOUT = overall system gate
  --   TELEMETRY.trust_client = accept cached client stats
  if C and C.USE_CLIENT_LOADOUT ~= true then return false end
  if C and C.TELEMETRY and C.TELEMETRY.trust_client == false then return false end
  return true
end

local function max_age_s()
  if C and C.TELEMETRY and C.TELEMETRY.max_age_s ~= nil then
    return tonumber(C.TELEMETRY.max_age_s) or 15
  end
  return 15
end

--=====================================================
-- ezmemory helpers (legacy keys support)
--=====================================================

local function get_mem(ezmemory, player_id)
  if not ezmemory or type(ezmemory.get_player_memory) ~= "function" then
    return nil
  end

  local safe = helpers.get_safe_player_secret(player_id)
  local mem = ezmemory.get_player_memory(safe)
  if type(mem) ~= "table" then
    return nil
  end

  return mem
end

local function mem_get_key(ezmemory, player_id, key)
  local mem = get_mem(ezmemory, player_id)
  if not mem then return nil end
  return mem[key]
end

--=====================================================
-- Package registry helpers
--=====================================================

local function get_package_id(Net, player_id)
  local ok, v = safe_call(Net and Net.get_player_package_id, player_id)
  if ok then return v end
  return nil
end

local function try_package_registry(pkg_id)
  if not pkg_id then return nil end

  local ok, reg = pcall(require, "scripts/whynn_core/loadout_scaling/package_stats")
  if not ok or type(reg) ~= "table" then return nil end

  return reg[pkg_id]
end

--=====================================================
-- Telemetry parse helpers
--=====================================================

local function parse_buster_from_telemetry(t)
  local L = limits()

  local raw_atk =
    t.attack_level or
    t.buster_attack or
    t.atk

  local raw_cmult =
    t.charged_attack_multiplier or
    t.charge_multiplier or
    t.cmult

  local raw_spd =
    t.speed or
    t.buster_speed

  local atk, c1 = clamp_num(raw_atk, L.atk_min, L.atk_max, 1)
  local cmult, c2 = clamp_num(raw_cmult, L.cmult_min, L.cmult_max, 10)
  local spd, c3 = clamp_num(raw_spd, L.spd_min, L.spd_max, 1.0)

  local clamped = (c1 or c2 or c3) == true
  local src = clamped and "client_clamped" or "client_report"

  return {
    attack_level = atk,
    charged_attack_multiplier = cmult,
    speed = spd, -- buster rapid, NOT movement
    source = src,
    updated_at = t.ts,
  }, src, clamped
end

local function parse_folder_from_telemetry(t)
  local L = limits()

  local raw_score = t.folder_score
  local raw_chips =
    t.chip_count or
    t.folder_count or
    t.chips

  local score, c1 = clamp_num(raw_score, L.folder_score_min, L.folder_score_max, 1.0)

  local chips = nil
  local c2 = false
  if raw_chips ~= nil then
    chips, c2 = clamp_num(raw_chips, L.chip_count_min, L.chip_count_max, nil)
  end

  local clamped = (c1 or c2) == true
  local src = clamped and "client_clamped" or "client_report"

  return {
    folder_score = score,
    chip_count = chips,
    source = src,
    updated_at = t.ts,
  }, src, clamped
end

--=====================================================
-- Public API: BUSTER
--=====================================================
-- Returns:
--   { attack_level, charged_attack_multiplier, speed, source, updated_at? }, src

function M.read_buster(player_id, deps)
  local Net      = deps and deps.Net
  local ezmemory = deps and deps.ezmemory

  -- 0) Fresh telemetry (preferred if enabled)
  if telemetry_enabled() then
    local t = telemetry.get_fresh(player_id, max_age_s())
    if type(t) == "table" then
      return parse_buster_from_telemetry(t)
    end
  end

  -- 1) Server-trusted package registry (optional)
  do
    local pkg_id = get_package_id(Net, player_id)
    M._dbg_pkg_lookup(player_id, pkg_id)

    local st = try_package_registry(pkg_id)
    if type(st) == "table" then
      return {
        attack_level = tonumber(st.attack_level or st.atk) or 1,
        charged_attack_multiplier = tonumber(st.charged_attack_multiplier or st.cmult) or 10,
        speed = tonumber(st.speed) or 1.0,
        source = "package",
      }, "package"
    end
  end

  -- 2) Legacy ezmemory keys (optional)
  do
    local atk   = mem_get_key(ezmemory, player_id, "BUSTER_ATK")
    local cmult = mem_get_key(ezmemory, player_id, "BUSTER_CMULT")
    local spd   = mem_get_key(ezmemory, player_id, "BUSTER_SPEED")

    if atk ~= nil or cmult ~= nil or spd ~= nil then
      return {
        attack_level = tonumber(atk) or 1,
        charged_attack_multiplier = tonumber(cmult) or 10,
        speed = tonumber(spd) or 1.0,
        source = "ezmemory",
      }, "ezmemory"
    end
  end

  -- 3) Stub baseline (safe fallback)
  return {
    attack_level = 1,
    charged_attack_multiplier = 10,
    speed = 1.0,
    source = "stub",
  }, "stub"
end

--=====================================================
-- Public API: FOLDER
--=====================================================
-- Returns:
--   { folder_score, chip_count?, source, updated_at? }, src

function M.read_folder(player_id, deps)
  local ezmemory = deps and deps.ezmemory

  -- 0) Fresh telemetry (preferred if enabled)
  if telemetry_enabled() then
    local t = telemetry.get_fresh(player_id, max_age_s())
    if type(t) == "table" and t.folder_score ~= nil then
      return parse_folder_from_telemetry(t)
    end
  end

  -- 1) Legacy ezmemory key (optional)
  do
    local s = mem_get_key(ezmemory, player_id, "FOLDER_SCORE")
    if s ~= nil then
      return {
        folder_score = tonumber(s) or 1.0,
        source = "ezmemory",
      }, "ezmemory"
    end
  end

  -- 2) Stub baseline (safe fallback)
  return {
    folder_score = 1.0,
    source = "stub",
  }, "stub"
end

--=====================================================
-- DEBUG
--=====================================================

function M._dbg_loaded()
  C.dbg_print(2, "readers", string.format(
    "LOADED read_buster=%s read_folder=%s",
    tostring(M.read_buster),
    tostring(M.read_folder)
  ))
end

function M._dbg_pkg_lookup(player_id, pkg_id)
  -- Only show package lookup chatter when sniff is enabled AND verbose.
  if not (C.DEBUG and C.DEBUG.sniff_events) then return end
  if not C.dbg_enabled(3) then return end

  C.dbg_print(3, "readers", string.format(
    "[%s] pkg_id=%s",
    tostring(player_id),
    tostring(pkg_id)
  ))
end

M._dbg_loaded()

return M
