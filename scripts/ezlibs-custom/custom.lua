--=====================================================
-- ezlibs-custom/custom.lua
--
-- Purpose:
--   Single entrypoint for ezlibs-custom "glue" scripts.
--
-- Rules:
--   - This file is allowed to wire Net events (via ezlibs dispatcher hooks).
--   - Feature modules should be required here and kept in a plugin list.
--   - One bad plugin should NOT break the dispatcher.
--
-- Logging:
--   - Prefix: [ezlibs-custom]
--   - Debug gate + sink uses whynn_core/loadout_scaling/scaling_config.lua
--     (C.dbg_enabled + C.dbg_print)
--
-- Notes:
--   - custom.lua is ALSO allowed to wire raw Net:on(...) events (centralized).
--     Plugins must NOT call Net:on directly; they expose handlers instead.
--=====================================================

print("[ezlibs-custom] LOADING custom.lua")

local C = require("scripts/whynn_core/loadout_scaling/scaling_config")

--=====================================================
-- Small helpers
--=====================================================

local function safe_require(path)
  local ok, mod = pcall(require, path)

  -- Treat "ok but nil" as failure too (module returned nothing).
  if not ok or mod == nil then
    print(string.format(
      "[ezlibs-custom] safe_require FAIL path=%s err=%s",
      tostring(path),
      tostring(mod)
    ))
    return nil
  end

  return mod
end

local function dbg_enabled(level)
  return C and type(C.dbg_enabled) == "function" and C.dbg_enabled(level)
end

local function dbg_print(level, fmt, ...)
  if not dbg_enabled(level) then return end

  -- Keep our required prefix, but route through unified debug sink if available.
  local msg = string.format("[ezlibs-custom] " .. fmt, ...)

  if C and type(C.dbg_print) == "function" then
    C.dbg_print("ezlibs-custom", msg)
  else
    -- Failsafe if config helpers are missing.
    print(msg)
  end
end

local function safe_call(plugin, fn_name, ...)
  local fn = plugin and plugin[fn_name]
  if type(fn) ~= "function" then
    -- Level 3 only: helps refactors without spamming normal logs.
    dbg_print(3, "no handler plugin=%s fn=%s",
      tostring(plugin and (plugin.id or plugin.__name or plugin.name) or "?"),
      tostring(fn_name)
    )
    return false
  end

  local ok, err = pcall(fn, ...)
  if not ok then
    local plugin_name = tostring(plugin.id or plugin.__name or plugin.name or "?")

    -- Traceback is extremely helpful for plugin crashes.
    local trace = ""
    if debug and type(debug.traceback) == "function" then
      trace = "\n" .. debug.traceback()
    end

    print(string.format(
      "[ezlibs-custom] plugin handler FAIL plugin=%s fn=%s err=%s%s",
      plugin_name,
      tostring(fn_name),
      tostring(err),
      trace
    ))
    return false
  end

  return true
end

--=====================================================
-- Plugin registry
--=====================================================

-- Add plugins here. Order matters if you rely on side effects.
local PLUGIN_PATHS = {
  "scripts/ezlibs-custom/my_base_stats",
  "scripts/ezlibs-custom/loadout_stats_sender",
}

local plugins = {}

local function load_plugins()
  for _, path in ipairs(PLUGIN_PATHS) do
    local mod = safe_require(path)
    if mod then
      -- Optional name markers for logging + stable ids for future toggles.
      if type(mod) == "table" then
        if mod.__name == nil then mod.__name = path end
        if mod.id == nil then mod.id = path end
      end

      plugins[#plugins+1] = mod
      dbg_print(2, "loaded plugin=%s", tostring(path))
    else
      dbg_print(2, "skipped plugin=%s (failed require)", tostring(path))
    end
  end

  dbg_print(2, "plugins loaded count=%d", #plugins)
end

-- Optional sidecar scripts (best-effort, never fatal)
local function load_optional()
  local ok, err = pcall(require, "scripts/bot/hpmem_shop_bot")
  if not ok then
    dbg_print(2, "optional require failed scripts/bot/hpmem_shop_bot err=%s", tostring(err))
  else
    dbg_print(2, "optional loaded scripts/bot/hpmem_shop_bot")
  end
end

-- === force-load ezencounters (temporary hard enable) ===
print("[ezlibs-custom] loading ezencounters...")

local ok, ezencounters = pcall(require, "scripts/ezlibs-scripts/ezencounters/main")
print(string.format("[ezlibs-custom] ezencounters require ok=%s mod=%s", tostring(ok), tostring(ezencounters)))

if ok and ezencounters and type(ezencounters.init) == "function" then
  local ok2, err = pcall(function() ezencounters.init() end)
  print(string.format("[ezlibs-custom] ezencounters.init ok=%s err=%s", tostring(ok2), tostring(err)))
else
  print("[ezlibs-custom] ezencounters missing or has no init()")
end

--=====================================================
-- Dispatcher implementation (ezlibs expects this object)
--=====================================================

local dispatcher = {}

local function dispatch(fn_name, ...)
  -- Level 3 only (spam)
  dbg_print(3, "dispatch fn=%s plugins=%d", tostring(fn_name), #plugins)

  for _, p in ipairs(plugins) do
    safe_call(p, fn_name, ...)
  end
end

-- NOTE:
-- These function names are aligned with your ezlibs dispatcher expectations.
-- Keep them stable; plugins implement matching handlers.

function dispatcher.handle_player_join(player_id)
  dispatch("handle_player_join", player_id)
end

function dispatcher.handle_player_transfer(player_id)
  dispatch("handle_player_transfer", player_id)
end

function dispatcher.handle_player_avatar_change(player_id, details)
  dispatch("handle_player_avatar_change", player_id, details)
end

function dispatcher.handle_battle_results(player_id, stats)
  dispatch("handle_battle_results", player_id, stats)
end

--=====================================================
-- Central Net wiring (raw Net:on hooks live HERE only)
--=====================================================

local function wire_net_events()
  if type(Net) ~= "table" or type(Net.on) ~= "function" then
    dbg_print(2, "Net:on not available; skipping Net event wiring")
    return
  end

  -- Telemetry packets / client custom messages
  pcall(function()
    Net:on("custom_message", function(e)
      dispatch("handle_custom_message", e)
    end)
    dbg_print(2, "wired Net:on custom_message => handle_custom_message")
  end)

  -- Optional: battle end variants (some builds use different names)
  local function hook_battle_end(evname)
    pcall(function()
      Net:on(evname, function(e)
        dispatch("handle_battle_end_event", evname, e)
      end)
      dbg_print(3, "wired Net:on %s => handle_battle_end_event", tostring(evname))
    end)
  end

  hook_battle_end("battle_end")
  hook_battle_end("battle_complete")
  hook_battle_end("battle_finish")
end

--=====================================================
-- Boot
--=====================================================

load_plugins()
load_optional()
wire_net_events()

print(string.format("[ezlibs-custom] LOADED custom.lua plugins=%d", #plugins))

return dispatcher
