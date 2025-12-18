local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local helpers  = require('scripts/ezlibs-scripts/helpers')

print("[ezmemory_patch] LOADED")

-- Harden memory shape (prevents pairs(nil) crash)
local _get_player_memory = ezmemory.get_player_memory
ezmemory.get_player_memory = function(safe_secret)
  local mem = _get_player_memory(safe_secret)
  if mem.items == nil then mem.items = {} end
  if mem.money == nil then mem.money = 0 end
  if mem.meta == nil then mem.meta = {} end
  if mem.meta.joins == nil then mem.meta.joins = 0 end
  if mem.area_memory == nil then mem.area_memory = {} end
  return mem
end

-- FIX: persist new max hp correctly (library bug workaround)
local _set_player_max_health = ezmemory.set_player_max_health
ezmemory.set_player_max_health = function(player_id, new_max_health, should_heal_by_increase)
  local safe_secret = helpers.get_safe_player_secret(player_id)
  local mem = ezmemory.get_player_memory(safe_secret)

  local current_health = Net.get_player_health(player_id)
  local old_max = Net.get_player_max_health(player_id)

  local new_health = current_health
  if new_max_health > old_max and should_heal_by_increase then
    new_health = current_health + (new_max_health - old_max)
  end
  new_health = math.min(new_health, new_max_health)

  Net.set_player_max_health(player_id, new_max_health, false)
  Net.set_player_health(player_id, new_health)

  mem.max_health = new_max_health
  mem.health = new_health
  ezmemory.save_player_memory(safe_secret)

  -- let ezmemory apply any area rules after
  -- (if you later enable Forced Base HP / Honor Saved HP etc)
end

return true
