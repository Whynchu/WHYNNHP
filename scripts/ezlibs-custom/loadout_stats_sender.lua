--=====================================================
-- client/plugins/loadout_stats_sender.lua
--
-- Purpose:
--   Client-side telemetry sender for Loadout-Truth Scaling.
--   - Responds to server pings ("[server] stats_request"/"stats_refresh")
--   - Sends a stub payload (safe defaults) until 2.5 client getters exist
--   - Uses best-effort Net send probing (build-dependent)
--   - Optional startup burst to help initial sync
--
-- Rules:
--   - Quiet by default (debug gated)
--   - No hard dependency on any specific Net function/event name
--   - Never crash the client if a hook/send method is missing
--
-- Logging:
--   - Prefix: [loadout_stats_sender]
--=====================================================

local plugin = {}
plugin.id = "loadout_stats_sender"

--=====================================================
-- Config
--=====================================================

local CFG = {
  DEBUG = {
    enabled = true,
    level = 1,
    -- 1 = decisions (send ok/fail, ping received)
    -- 2 = lifecycle (hooks installed, init)
    -- 3 = verbose (payload dumps, per-candidate spam)
  },

  -- Server strings that request stats (exact match)
  PINGS = {
    "[server] stats_request",
    "[server] stats_refresh",
  },

  -- Optional user command typed in chat
  MANUAL_CMD = "/stats",

  -- Outbound Net send candidates (build-dependent)
  -- We try both dot and colon calling styles.
  SEND_CANDIDATES = {
    "send_custom_message",
    "send_custom",
    "custom_message",
    "send",
  },

  -- Inbound event candidates (build-dependent)
  -- We hook these and extract text from the event.
  INBOUND_EVENTS = {
    "message",
    "chat_message",
    "server_message",
    "system_message",
    "custom_message",
  },

  -- Startup burst
  BURST = {
    enabled = true,
    sends = 5,
    every_s = 3,
  },
}

--=====================================================
-- Small helpers
--=====================================================

local function safe_text(x)
  return (type(x) == "string") and x or nil
end

local function safe_num(x, fallback)
  local n = tonumber(x)
  if n == nil then return fallback end
  return n
end

local function in_list(list, value)
  if type(list) ~= "table" then return false end
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local function has_net()
  return type(_G.Net) == "table"
end

local function has_net_on()
  return has_net() and type(_G.Net.on) == "function"
end

--=====================================================
-- Stats source (stub for now)
--=====================================================

local function read_stats_stub()
  -- TODO (2.5+):
  --   replace with real client getters.
  --   * read_buster_from_client()
  --   * read_folder_from_client()

  local buster_attack = 1
  local charged_attack_multiplier = 10
  local speed = 1.0

  local folder_score = 1.0
  local chip_count = 30
  local folder_hash = "stub"

  return {
    type = "player_stats",

    buster_attack = buster_attack,
    charged_attack_multiplier = charged_attack_multiplier,
    speed = speed,

    folder_score = folder_score,
    chip_count = chip_count,
    folder_hash = folder_hash,
  }
end

--=====================================================
-- Outbound send (best-effort)
--=====================================================

local function try_send_via(name, payload)
  local fn = _G.Net and _G.Net[name]
  if type(fn) ~= "function" then return false end

  -- Dot call: Net.fn(payload)
  do
    local ok = pcall(function() fn(payload) end)
    if ok then
      plugin._dbg_print(1, "send OK via Net.%s (dot)", tostring(name))
      return true
    elseif plugin._dbg_enabled(3) then
      plugin._dbg_print(3, "send try Net.%s (dot) FAIL", tostring(name))
    end
  end

  -- Colon-style emulation: Net:fn(payload)
  do
    local ok = pcall(function() _G.Net[name](_G.Net, payload) end)
    if ok then
      plugin._dbg_print(1, "send OK via Net:%s (colon)", tostring(name))
      return true
    elseif plugin._dbg_enabled(3) then
      plugin._dbg_print(3, "send try Net:%s (colon) FAIL", tostring(name))
    end
  end

  return false
end

local function send_custom(payload)
  if not has_net() then
    plugin._dbg_print(1, "send FAIL (Net missing)")
    return false
  end

  for _, name in ipairs(CFG.SEND_CANDIDATES) do
    if try_send_via(name, payload) then
      return true
    end
  end

  plugin._dbg_print(1, "send FAIL (no matching Net sender)")
  return false
end

local function send_stats(reason)
  local payload = read_stats_stub()
  plugin._dbg_print(1, "send_stats reason=%s", tostring(reason or "?"))

  local ok = send_custom(payload)

  if (not ok) and plugin._dbg_enabled(3) then
    plugin._dbg_print(3, "payload atk=%s cmult=%s speed=%s folder_score=%s chip_count=%s hash=%s",
      tostring(payload.buster_attack),
      tostring(payload.charged_attack_multiplier),
      tostring(payload.speed),
      tostring(payload.folder_score),
      tostring(payload.chip_count),
      tostring(payload.folder_hash)
    )
  end

  return ok
end

--=====================================================
-- Inbound messages (server ping + manual command)
--=====================================================

local function extract_text(e)
  -- Some builds pass raw strings; others pass tables.
  if type(e) == "string" then return e end
  if type(e) ~= "table" then return nil end

  local text =
    safe_text(e.message) or
    safe_text(e.text) or
    safe_text(e.msg)

  if not text and type(e.data) == "string" then text = e.data end
  if not text and type(e.payload) == "string" then text = e.payload end

  return safe_text(text)
end

local function handle_inbound(e)
  local text = extract_text(e)
  if not text then return end

  -- Server pings
  if in_list(CFG.PINGS, text) then
    plugin._dbg_print(1, "recv ping: %s", text)
    send_stats(text)
    return
  end

  -- Manual command
  if CFG.MANUAL_CMD and text == CFG.MANUAL_CMD then
    plugin._dbg_print(1, "manual cmd: %s", text)
    send_stats("manual")
  end
end

local function hook_inbound_messages()
  if not has_net_on() then
    plugin._dbg_print(2, "Net.on not available; relying on burst only")
    return false
  end

  for _, ev in ipairs(CFG.INBOUND_EVENTS) do
    local ok = pcall(function()
      _G.Net:on(ev, handle_inbound)
    end)

    plugin._dbg_print(2, "hook %s => %s", tostring(ev), ok and "OK" or "FAIL")
  end

  return true
end

--=====================================================
-- Startup burst
--=====================================================

local function start_burst_sender()
  if not (CFG.BURST and CFG.BURST.enabled) then return end

  local sends = safe_num(CFG.BURST.sends, 0)
  local every = safe_num(CFG.BURST.every_s, 3)

  if sends <= 0 then return end

  if _G.Async and type(_G.Async.sleep) == "function" then
    plugin._dbg_print(2, "burst enabled sends=%d every=%.2fs", sends, every)

    Async.promisify(coroutine.create(function()
      for i = 1, sends do
        send_stats("burst_" .. tostring(i))
        await(Async.sleep(every))
      end
    end))

    return
  end

  -- No timer api: send once on init
  plugin._dbg_print(2, "no timer api; sending once on init")
  send_stats("init")
end

--=====================================================
-- Public API
--=====================================================

function plugin.init()
  plugin._dbg_print(2, "init")
  hook_inbound_messages()
  start_burst_sender()
end

--=====================================================
-- DEBUG
--=====================================================

function plugin._dbg_enabled(level)
  if not (CFG.DEBUG and CFG.DEBUG.enabled) then return false end
  local lvl = safe_num(CFG.DEBUG.level, 0)
  return lvl >= safe_num(level, 1)
end

function plugin._dbg_print(level, fmt, ...)
  if not plugin._dbg_enabled(level) then return end
  local msg = string.format(fmt, ...)
  print(string.format("[loadout_stats_sender] %s", msg))
end

return plugin
