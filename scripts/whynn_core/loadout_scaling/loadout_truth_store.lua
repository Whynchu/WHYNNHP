--=====================================================
-- loadout_truth_store.lua
--
-- Purpose:
--   Persist "loadout truth" into ezmemory under a dedicated namespace.
--
-- What is "loadout truth"?
--   Server-preferred, long-lived loadout stats that can survive:
--     * disconnects
--     * server restarts
--     * missing telemetry
--
-- Stored under:
--   mem.loadout_truth = { buster = {...}, folder = {...} }
--
-- Key rule:
--   Trusted sources should not be overwritten by untrusted ones.
--=====================================================

local helpers = require('scripts/ezlibs-scripts/helpers')

local M = {}

--=====================================================
-- Small helpers
--=====================================================

local function now()
  return os.time()
end

-- Retrieve ezmemory player record using safe secret.
-- Returns: safe_secret, memory_table (or nil)
local function get_mem(ezmemory, player_id)
  if not ezmemory or type(ezmemory.get_player_memory) ~= "function" then
    return nil, nil
  end

  local safe = helpers.get_safe_player_secret(player_id)
  local mem = ezmemory.get_player_memory(safe)

  if type(mem) ~= "table" then
    return safe, nil
  end

  return safe, mem
end

local function save_mem(ezmemory, safe)
  if ezmemory and type(ezmemory.save_player_memory) == "function" then
    ezmemory.save_player_memory(safe)
  end
end

-- Ensure we have a dedicated namespace for this system.
local function ensure_ns(mem)
  if type(mem.loadout_truth) ~= "table" then
    mem.loadout_truth = {}
  end
  return mem.loadout_truth
end

--=====================================================
-- Trust model
--=====================================================

-- Trusted sources represent server-known data.
-- Untrusted sources represent client-derived data or unknown origins.
local function is_trusted_source(src)
  src = tostring(src or "")
  return (src == "net" or src == "package" or src == "server_capture")
end

M.is_trusted_source = is_trusted_source

-- Decide whether an incoming write should overwrite existing data.
-- Rules:
--   * force=true bypasses all checks
--   * optional min_age_s prevents rapid overwrites
--   * trusted existing data is protected from untrusted overwrites
local function should_write(existing, payload)
  payload = payload or {}

  if payload.force == true then
    return true
  end

  -- If nothing exists, allow write.
  if type(existing) ~= "table" then
    return true
  end

  -- Optional anti-spam: don't overwrite if last update was "recent"
  local min_age_s = tonumber(payload.min_age_s)
  if min_age_s and min_age_s > 0 then
    local age = now() - (tonumber(existing.updated_at) or 0)
    if age < min_age_s then
      return false
    end
  end

  -- Protect trusted sources from being overwritten by untrusted sources.
  local existing_src = tostring(existing.source or "")
  local incoming_src = tostring(payload.source or "")

  if is_trusted_source(existing_src) and not is_trusted_source(incoming_src) then
    return false
  end

  return true
end

--=====================================================
-- Public API: setters
--=====================================================

-- payload:
--   { attack_level, charged_attack_multiplier, speed, source, force?, min_age_s? }
function M.set_buster(player_id, deps, payload)
  local ezmemory = deps and deps.ezmemory
  local safe, mem = get_mem(ezmemory, player_id)
  if not mem then
    return false, "no_mem"
  end

  local ns = ensure_ns(mem)
  local existing = ns.buster

  if not should_write(existing, payload) then
    return false, "skipped"
  end

  ns.buster = {
    attack_level = tonumber(payload and payload.attack_level) or 1,
    charged_attack_multiplier = tonumber(payload and payload.charged_attack_multiplier) or 10,
    speed = tonumber(payload and payload.speed) or 1.0,

    source = tostring((payload and payload.source) or "unknown"),
    updated_at = now(),
  }

  save_mem(ezmemory, safe)
  return true
end

-- payload:
--   { folder_score, source, force?, min_age_s? }
function M.set_folder(player_id, deps, payload)
  local ezmemory = deps and deps.ezmemory
  local safe, mem = get_mem(ezmemory, player_id)
  if not mem then
    return false, "no_mem"
  end

  local ns = ensure_ns(mem)
  local existing = ns.folder

  if not should_write(existing, payload) then
    return false, "skipped"
  end

  ns.folder = {
    folder_score = tonumber(payload and payload.folder_score) or 1.0,

    source = tostring((payload and payload.source) or "unknown"),
    updated_at = now(),
  }

  save_mem(ezmemory, safe)
  return true
end

--=====================================================
-- Public API: seed helpers
--=====================================================
-- Seed helpers write only if missing (never overwrites).
-- Uses force=true internally after verifying "missing".

function M.seed_buster(player_id, deps, payload)
  local ezmemory = deps and deps.ezmemory
  local safe, mem = get_mem(ezmemory, player_id)
  if not mem then
    return false, "no_mem"
  end

  local ns = ensure_ns(mem)
  if type(ns.buster) == "table" then
    return false, "exists"
  end

  payload = payload or {}
  payload.force = true
  return M.set_buster(player_id, deps, payload)
end

function M.seed_folder(player_id, deps, payload)
  local ezmemory = deps and deps.ezmemory
  local safe, mem = get_mem(ezmemory, player_id)
  if not mem then
    return false, "no_mem"
  end

  local ns = ensure_ns(mem)
  if type(ns.folder) == "table" then
    return false, "exists"
  end

  payload = payload or {}
  payload.force = true
  return M.set_folder(player_id, deps, payload)
end

--=====================================================
-- Public API: getters (debug-friendly)
--=====================================================

function M.get_buster(player_id, deps)
  local ezmemory = deps and deps.ezmemory
  local _, mem = get_mem(ezmemory, player_id)
  if not mem or type(mem.loadout_truth) ~= "table" then return nil end
  return mem.loadout_truth.buster
end

function M.get_folder(player_id, deps)
  local ezmemory = deps and deps.ezmemory
  local _, mem = get_mem(ezmemory, player_id)
  if not mem or type(mem.loadout_truth) ~= "table" then return nil end
  return mem.loadout_truth.folder
end

return M
