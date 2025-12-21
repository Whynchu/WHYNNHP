--=====================================================
-- ezmemory_harden.lua
--
-- Purpose:
--   Keep vanilla ezmemory behavior, but harden legacy JSON shapes so
--   mem.items / mem.meta / mem.area_memory are always tables.
--   This prevents join/avatar_change crashes in ezmemory.lua.
--=====================================================

local ezmemory = require('scripts/ezlibs-scripts/ezmemory')

print("[ezmemory_harden] LOADED")

local _get_player_memory = ezmemory.get_player_memory

ezmemory.get_player_memory = function(safe_secret)
  local mem = _get_player_memory(safe_secret)

  if type(mem) ~= "table" then mem = {} end

  if type(mem.items) ~= "table" then mem.items = {} end
  if type(mem.money) ~= "number" then mem.money = tonumber(mem.money) or 0 end

  if type(mem.meta) ~= "table" then mem.meta = {} end
  if type(mem.meta.joins) ~= "number" then mem.meta.joins = tonumber(mem.meta.joins) or 0 end

  if type(mem.area_memory) ~= "table" then mem.area_memory = {} end

  return mem
end

return true
