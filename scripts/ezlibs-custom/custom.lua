-- server/scripts/ezlibs-custom/custom.lua
-- Custom plugin dispatcher for ezlibs-scripts/main.lua
-- Loads custom modules and forwards events to them safely.

local helpers = require("scripts/ezlibs-scripts/helpers")

local M = {}

local subs = {}

local function add_plugin(name, mod)
  if type(mod) == "table" then
    subs[#subs + 1] = mod
    print(string.format("[ezlibs-custom] plugin OK: %s", tostring(name)))
    return true
  end

  if mod == nil or mod == false then
    print(string.format("[ezlibs-custom] plugin SKIP: %s (nil/false)", tostring(name)))
    return false
  end

  -- Catch the bug you're seeing: boolean/string/function/etc in the plugin list
  print(string.format("[ezlibs-custom] plugin BAD: %s type=%s value=%s",
    tostring(name), type(mod), tostring(mod)))
  return false
end

-- Load modules with safe_require so missing files don't brick the server
add_plugin("my_base_stats", helpers.safe_require("scripts/ezlibs-custom/my_base_stats"))

-- OPTIONAL:
-- Do NOT load hpmem_shop_bot here if it already registers Net:on(...) itself.
-- Only include it if you specifically rewrote it as a "forwarded plugin" (table return with handlers).
-- add_plugin("hpmem_shop_bot", helpers.safe_require("scripts/ezlibs-custom/hpmem_shop_bot"))

print(string.format("[ezlibs-custom] LOADED custom.lua plugins=%d", #subs))

local function call_all(fn, ...)
  for _, p in ipairs(subs) do
    -- extra safety: never assume list entries are valid
    if type(p) == "table" then
      local f = p[fn]
      if type(f) == "function" then
        local ok, err = pcall(f, ...)
        if not ok then
          print(string.format("[ezlibs-custom] %s failed: %s", tostring(fn), tostring(err)))
        end
      end
    else
      print(string.format("[ezlibs-custom] INTERNAL: non-table in subs type=%s value=%s",
        type(p), tostring(p)))
    end
  end
end

-- Forward whatever handlers you actually use
function M.on_tick(delta_time)                   call_all("on_tick", delta_time) end
function M.handle_player_join(player_id)         call_all("handle_player_join", player_id) end
function M.handle_player_disconnect(player_id)   call_all("handle_player_disconnect", player_id) end
function M.handle_player_transfer(player_id)     call_all("handle_player_transfer", player_id) end
function M.handle_player_avatar_change(player_id, details)
  call_all("handle_player_avatar_change", player_id, details)
end
function M.handle_battle_results(player_id, stats)
  call_all("handle_battle_results", player_id, stats)
end
function M.handle_shop_purchase(player_id, item_name)
  call_all("handle_shop_purchase", player_id, item_name)
end
function M.handle_shop_close(player_id)
  call_all("handle_shop_close", player_id)
end
function M.handle_actor_interaction(player_id, actor_id, button)
  call_all("handle_actor_interaction", player_id, actor_id, button)
end
function M.handle_object_interaction(player_id, object_id, button)
  call_all("handle_object_interaction", player_id, object_id, button)
end
function M.handle_tile_interaction(player_id, x, y, z, button)
  call_all("handle_tile_interaction", player_id, x, y, z, button)
end
function M.handle_player_move(player_id, x, y, z)
  call_all("handle_player_move", player_id, x, y, z)
end
function M.handle_player_request(player_id, data)
  call_all("handle_player_request", player_id, data)
end
function M.handle_post_selection(player_id, post_id)
  call_all("handle_post_selection", player_id, post_id)
end
function M.handle_board_close(player_id)
  call_all("handle_board_close", player_id)
end
function M.handle_custom_warp(player_id, object_id)
  call_all("handle_custom_warp", player_id, object_id)
end

return M
