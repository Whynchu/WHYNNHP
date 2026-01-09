-- server/scripts/whynn_core/loadout_scaling/mob_hp_hook.lua
-- Net-safe module for use from package contexts (package_build).
-- Key rule: NEVER require ezmemory at top-level, because Net may be nil during package load.

local M = {}

-- ------------------------------------------------------------
-- Small helpers
-- ------------------------------------------------------------
local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function get_Net()
  -- Net is a global injected by the engine (may be nil during package load)
  return rawget(_G, "Net")
end

local function get_config()
  -- Avoid hard-requiring config; keep it optional
  local ok, mod = pcall(require, 'scripts/whynn_core/loadout_scaling/scaling_config')
  if ok then return mod end
  return nil
end

local function dbg(msg)
  local C = get_config()
  if C and C.DEBUG and C.DEBUG.enabled then
    print("[mob_hp_hook] " .. tostring(msg))
  end
end

local function dump_keys(tbl, limit)
  if type(tbl) ~= "table" then return tostring(tbl) end
  local out, n = {}, 0
  for k,_ in pairs(tbl) do
    n = n + 1
    if limit and n > limit then out[#out+1] = "..." break end
    out[#out+1] = tostring(k)
  end
  return table.concat(out, ",")
end

-- ------------------------------------------------------------
-- Data -> player_id discovery (best-effort, no assumptions)
-- ------------------------------------------------------------
local function pick_player_id(data)
  if type(data) ~= "table" then return nil end
  if data.player_id then return data.player_id end
  if data.initiator_id then return data.initiator_id end

  if type(data.player_ids) == "table" and data.player_ids[1] then
    return data.player_ids[1]
  end

  if type(data.players) == "table" and data.players[1] then
    local p = data.players[1]
    if type(p) == "table" and p.id then return p.id end
    if type(p) == "string" then return p end
  end

  return nil
end

-- ------------------------------------------------------------
-- Lazy ezmemory access (ONLY when Net exists)
-- ------------------------------------------------------------
local function get_ezmemory()
  if not get_Net() then
    -- Net not ready yet (package load time)
    return nil
  end

  local ok, mod = pcall(require, 'scripts/ezlibs-scripts/ezmemory')
  if ok then return mod end

  dbg("ezmemory require failed: " .. tostring(mod))
  return nil
end

local function get_player_max_hp(player_id)
  if not player_id then return nil end

  -- If the caller already passed max HP in data, prefer that (no Net/ezmemory needed).
  -- (Handled in compute_multiplier; kept here as fallback if you want to extend later.)

  local ezmemory = get_ezmemory()
  if not ezmemory then return nil end

  -- Based on your log, these exist:
  -- ezmemory.get_player_max_health
  -- ezmemory.calculate_player_modified_max_hp
  local max_hp = nil

  if ezmemory.get_player_max_health then
    local ok, v = pcall(ezmemory.get_player_max_health, player_id)
    if ok then max_hp = tonumber(v) end
  end

  if not max_hp and ezmemory.calculate_player_modified_max_hp then
    local ok, v = pcall(ezmemory.calculate_player_modified_max_hp, player_id)
    if ok then max_hp = tonumber(v) end
  end

  return max_hp
end

local function hp_mult_from_player(player_max_hp)
  local base = 100
  local raw = player_max_hp / base
  return clamp(raw, 0.75, 2.50)
end

-- ------------------------------------------------------------
-- Enemy HP mutation (best-effort, API-discovery style)
-- ------------------------------------------------------------
local function call_if(obj, fname, ...)
  local f = obj and obj[fname]
  if type(f) == "function" then
    return pcall(f, obj, ...)
  end
  return false, "no_fn"
end

local function apply_enemy_hp(enemy, mult)
  if enemy == nil then return false end

  local base_hp = nil

  do
    local ok, v = call_if(enemy, "get_max_health")
    if ok then base_hp = tonumber(v) end
  end

  if not base_hp then
    local ok, v = call_if(enemy, "get_max_hp")
    if ok then base_hp = tonumber(v) end
  end

  if (not base_hp or base_hp <= 0) and enemy.max_health then
    base_hp = tonumber(enemy.max_health)
  end

  if not base_hp or base_hp <= 0 then
    dbg("could not read enemy base max HP; skipping")
    return false
  end

  local new_hp = math.floor(base_hp * mult + 0.5)

  local okMax =
    select(1, call_if(enemy, "set_max_health", new_hp)) or
    select(1, call_if(enemy, "set_max_hp", new_hp))

  local okCur =
    select(1, call_if(enemy, "set_health", new_hp)) or
    select(1, call_if(enemy, "set_hp", new_hp))

  if okMax or okCur then
    dbg("applied enemy hp scale base=" .. tostring(base_hp) .. " new=" .. tostring(new_hp))
    return true
  end

  dbg("enemy has no max/health setters; cannot apply scaling")
  return false
end

-- ------------------------------------------------------------
-- Public API
-- ------------------------------------------------------------
function M.compute_multiplier(data)
  -- This is safe even during package load, but typically called during package_build.
  if type(data) == "table" then
    dbg("compute_multiplier data keys: " .. dump_keys(data, 12))
  end

  -- If caller passes max hp directly, use it (this is the cleanest long-term)
  if type(data) == "table" and data.player_max_hp then
    local hp = tonumber(data.player_max_hp)
    if hp and hp > 0 then
      local mult = hp_mult_from_player(hp)
      dbg(string.format("player_max_hp=%d mult=%.2f (from data)", hp, mult))
      return mult
    end
  end

  local player_id = pick_player_id(data)
  if not player_id then
    dbg("no player_id found; mult=1.0")
    return 1.0
  end

  local hp = get_player_max_hp(player_id)
  if not hp then
    dbg("could not read player max HP (Net/ezmemory not ready?); mult=1.0")
    return 1.0
  end

  local mult = hp_mult_from_player(hp)
  dbg(string.format("player_id=%s max_hp=%d mult=%.2f", tostring(player_id), hp, mult))
  return mult
end

function M.spawn_scaled(mob, package_id, rank, x, y, mult)
  local spawner = mob:create_spawner(package_id, rank)
  local enemy = spawner:spawn_at(x, y)

  dbg("spawn_at returned type=" .. tostring(type(enemy)) .. " value=" .. tostring(enemy))

  if enemy ~= nil then
    apply_enemy_hp(enemy, mult)
  else
    dbg("spawn_at returned nil; cannot apply scaling without handle")
  end

  return enemy
end

return M
