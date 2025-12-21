--=====================================================
-- my_base_stats.lua
--
-- Aesthetic / intent (matches loadout_scaling style):
--   - Small, single-purpose helpers
--   - Clear "what we trust" vs "what we observe"
--   - Debug output is gated + non-spammy by default
--
-- Purpose (current reality):
--   - Maintain HP correctness with HPMem (server-side truth via ezmemory)
--   - Cache client telemetry (future use; 2.5 will allow real read)
--   - Provide small helpers for overcap ratio / tier
--
-- IMPORTANT CHANGES vs old version:
--   1) No Net:on hooks inside this module.
--      custom.lua is the single wiring entrypoint.
--      This module exposes handlers for custom.lua to dispatch into.
--   2) Uses unified debug protocol from scaling_config.lua:
--      C.dbg_enabled / C.dbg_print / C.dbg_player
--   3) Debug helpers are at the bottom (house style).
--=====================================================

local ezmemory  = require('scripts/ezlibs-scripts/ezmemory')
local telemetry = require('scripts/whynn_core/loadout_scaling/player_telemetry')
local C         = require('scripts/whynn_core/loadout_scaling/scaling_config')

print("[my_base_stats] LOADED")

local plugin = {}
plugin.id = "my_base_stats"

--=====================================================
-- Config (truth baseline)
--=====================================================

local BASE_HP     = C.BASE_HP or 100
local HPMEM_ITEM  = "HPMem"
local HPMEM_BONUS = C.HPMEM_BONUS or 20

--=====================================================
-- Forward-declare debug helpers (defined at bottom)
--=====================================================

local dbg_enabled
local dbg_verbose
local dbg_telemetry_verbose
local dbg_sniff
local dbg_print
local dbg_player

--=====================================================
-- Async helper
--=====================================================

local function run_async(fn)
  Async.promisify(coroutine.create(fn))
end

--=====================================================
-- Table dump (diagnostics only)
--=====================================================

local function dump_table(t, indent, seen)
  indent = indent or ""
  seen = seen or {}
  if type(t) ~= "table" then return indent .. tostring(t) end
  if seen[t] then return indent .. "<cycle>" end
  seen[t] = true

  local out = {}
  for k, v in pairs(t) do
    local kk = tostring(k)
    if type(v) == "table" then
      out[#out+1] = indent .. kk .. " = {\n" .. dump_table(v, indent.."  ", seen) .. "\n" .. indent .. "}"
    else
      out[#out+1] = indent .. kk .. " = " .. tostring(v) .. " ("..type(v)..")"
    end
  end
  table.sort(out)
  return table.concat(out, "\n")
end

--=====================================================
-- ezmemory / HPMem helpers
--=====================================================

local function ensure_hpmem_item_exists()
  if ezmemory and ezmemory.get_or_create_item then
    ezmemory.get_or_create_item(HPMEM_ITEM, "Increases max HP by 20.", true)
  end
end

local function count_hpmem(player_id)
  if ezmemory and ezmemory.count_player_item then
    return ezmemory.count_player_item(player_id, HPMEM_ITEM) or 0
  end
  return 0
end

local function compute_want_max_hp(player_id)
  local hpmem = count_hpmem(player_id) or 0
  local want = BASE_HP + (HPMEM_BONUS * hpmem)
  if want < 1 then want = 1 end
  return want, hpmem
end

--=====================================================
-- HP enforcement (non-spammy)
--=====================================================

local function apply_hpmem_max_hp(player_id, why)
  why = tostring(why or "unknown")
  if not player_id then return false end

  if not Net or type(Net.get_player_max_health) ~= "function" then
    if dbg_verbose() then
      dbg_print(3, "apply NO-OP (no Net.get_player_max_health) player=%s why=%s",
        tostring(player_id), why)
    end
    return false
  end

  local want, hpmem = compute_want_max_hp(player_id)
  local have = tonumber(Net.get_player_max_health(player_id)) or 0

  if have == want then
    if dbg_verbose() then
      dbg_print(3, "apply NO-OP player=%s hpmem=%d want=%d have=%d why=%s",
        tostring(player_id), tonumber(hpmem) or 0, want, have, why)
    end
    return false
  end

  local applied = false

  -- 1) Prefer explicit setter if supported
  if type(Net.set_player_max_health) == "function" then
    local ok = pcall(function()
      Net.set_player_max_health(player_id, want)
    end)
    applied = ok

  -- 2) Fallback: avatar mutate (ONLY if safe)
  elseif type(Net.get_player_avatar) == "function" and type(Net.set_player_avatar) == "function" then
    local ok_get, av = pcall(function()
      return Net.get_player_avatar(player_id)
    end)

    if ok_get and type(av) == "table" then
      if type(av.name) == "string" and type(av.texture_path) == "string" and type(av.animation_path) == "string" then
        local ok_set = pcall(function()
          av.max_health = want
          Net.set_player_avatar(player_id, av)
        end)
        applied = ok_set
      else
        -- warn at lifecycle level (not spammy)
        dbg_print(2, "avatar set skipped (missing required fields) player=%s why=%s",
          tostring(player_id), why)
      end
    end
  end

  -- Clamp current HP down if needed
  if applied and type(Net.get_player_health) == "function" and type(Net.set_player_health) == "function" then
    local cur = tonumber(Net.get_player_health(player_id)) or want
    if cur > want then
      pcall(function()
        Net.set_player_health(player_id, want)
      end)
    end
  end

  local now_have = have
  if type(Net.get_player_max_health) == "function" then
    now_have = tonumber(Net.get_player_max_health(player_id)) or have
  end

  -- Log only when we applied (or verbose)
  if applied or dbg_verbose() then
    dbg_print(2, "apply player=%s hpmem=%d want=%d have=%d now=%d applied=%s why=%s",
      tostring(player_id),
      tonumber(hpmem) or 0,
      tonumber(want) or 0,
      tonumber(have) or 0,
      tonumber(now_have) or 0,
      tostring(applied),
      why
    )
  end

  return applied
end

--=====================================================
-- Finite burst ensure (no watchdog loops)
--=====================================================

local function burst_ensure_hp(player_id, why)
  run_async(function()
    if ezmemory and ezmemory.wait_until_loaded then
      await(ezmemory.wait_until_loaded())
    end

    ensure_hpmem_item_exists()

    for i = 1, 4 do
      apply_hpmem_max_hp(player_id, tostring(why or "ensure") .. ":burst" .. tostring(i))
      await(Async.sleep(0.6))
    end
  end)
end

--=====================================================
-- Telemetry intake (cache only for now)
--
-- IMPORTANT:
--   This module no longer installs Net:on("custom_message") directly.
--   custom.lua should forward that event into:
--     plugin.handle_custom_message(event)
--=====================================================

function plugin.handle_custom_message(e)
  local player_id = e and (e.player_id or e.sender_id or e.player)
  local msg = e and (e.message or e.data or e.payload)
  if not player_id then return end
  if type(msg) ~= "table" then return end
  if msg.type ~= "player_stats" then return end

  telemetry.set(player_id, msg)

  if dbg_telemetry_verbose() then
    dbg_print(3, "telemetry recv player=%s atk=%s cmult=%s speed=%s folder_score=%s chip_count=%s hash=%s",
      tostring(player_id),
      tostring(msg.buster_attack or msg.attack_level or msg.atk),
      tostring(msg.charged_attack_multiplier or msg.charge_multiplier or msg.cmult),
      tostring(msg.speed),
      tostring(msg.folder_score),
      tostring(msg.chip_count),
      tostring(msg.folder_hash)
    )
  end
end

--=====================================================
-- Public helpers (used by encounters / scaling)
--=====================================================

local function fair_allowed_max_hp(player_id)
  return BASE_HP + (HPMEM_BONUS * count_hpmem(player_id))
end

function plugin.get_overcap_ratio(player_id)
  local allowed = fair_allowed_max_hp(player_id)
  local have = (Net and Net.get_player_max_health and Net.get_player_max_health(player_id)) or allowed

  allowed = tonumber(allowed) or 1
  have    = tonumber(have) or allowed

  if allowed <= 0 then return 1 end
  if have <= 0 then return 1 end

  local ratio = have / allowed
  if ratio < 1 then ratio = 1 end
  return ratio
end

function plugin.get_difficulty_tier(player_id)
  local ratio = plugin.get_overcap_ratio(player_id)
  if ratio < 1.25 then return 0 end
  if ratio < 1.75 then return 1 end
  if ratio < 2.50 then return 2 end
  return 3
end

--=====================================================
-- Lifecycle hooks (called by custom.lua dispatcher)
--=====================================================

function plugin.handle_player_join(player_id)
  dbg_print(2, "handle_player_join player=%s", tostring(player_id))

  -- Default telemetry placeholder until the client reports real stats
  telemetry.set(player_id, { folder_score = 1.0 })

  -- Ask client to send stats (best-effort)
  if Net and Net.message_player then
    Net:message_player(player_id, "[server] stats_request")
  end

  burst_ensure_hp(player_id, "join")
end

function plugin.handle_player_transfer(player_id)
  dbg_print(2, "handle_player_transfer player=%s", tostring(player_id))
  burst_ensure_hp(player_id, "transfer")
end

function plugin.handle_player_avatar_change(player_id, details)
  dbg_print(2, "handle_player_avatar_change player=%s", tostring(player_id))

  if dbg_verbose() and type(details) == "table" then
    dbg_print(3, "avatar_change details:\n%s", dump_table(details))
  end

  burst_ensure_hp(player_id, "avatar_change")
end

--=====================================================
-- Opportunistic battle-end hooks (best-effort)
--
-- IMPORTANT:
--   This module no longer installs Net:on(...) for battle end variants.
--   custom.lua should forward battle-end events to:
--     plugin.handle_battle_results(player_id, stats)
--   and/or add more forwarders if your ezlibs dispatcher supports them.
--=====================================================

function plugin.handle_battle_results(player_id, stats)
  -- Keep it quiet; HP enforcement does the logging when it actually changes things.
  burst_ensure_hp(player_id, "event:battle_results")
end

--=====================================================
-- Optional: encounters can call this before generating battles
--=====================================================

function plugin.ensure_player_hp_is_correct(player_id, why)
  why = tostring(why or "ensure")

  local ok = pcall(function()
    ensure_hpmem_item_exists()
    apply_hpmem_max_hp(player_id, why)
  end)

  if not ok then
    burst_ensure_hp(player_id, why .. ":deferred")
  end
end

--=====================================================
-- DEBUG (unified protocol)  [keep at bottom]
--=====================================================

function dbg_enabled(level)
  return C and type(C.dbg_enabled) == "function" and C.dbg_enabled(level)
end

function dbg_verbose()
  -- For base_stats, "verbose" means: level >= 3
  return dbg_enabled(3)
end

function dbg_telemetry_verbose()
  -- Only print telemetry spam when BOTH:
  --   - global debug allows verbose
  --   - telemetry flag is enabled
  return dbg_enabled(3) and (C.DEBUG and C.DEBUG.telemetry)
end

function dbg_sniff()
  return dbg_enabled(3) and (C.DEBUG and C.DEBUG.sniff_events)
end

function dbg_print(level, fmt, ...)
  if not dbg_enabled(level) then return end
  local body = string.format(fmt, ...)
  local msg = string.format("[my_base_stats] %s", body)

  -- Route through unified sink if present; fallback to print.
  if C and type(C.dbg_print) == "function" then
    C.dbg_print("my_base_stats", msg)
  else
    print(msg)
  end
end

function dbg_player(player_id, msg)
  if not dbg_enabled(2) then return end
  if C and type(C.dbg_player) == "function" then
    C.dbg_player(player_id, tostring(msg))
  elseif Net and Net.message_player then
    Net:message_player(player_id, tostring(msg))
  end
end

return plugin
