--=====================================================
-- hpmem_shop_bot.lua
--
-- Purpose:
--   Sell "HPMem" as a TRUE ezmemory ITEM (vanilla behavior).
--   Purchase:
--     - spends zenny persistently via ezmemory
--     - gives 1x HPMem item (persistent, server-side)
--     - immediately increases current MaxHP by +20 (HUD updates now)
--
-- Notes:
--   - We do NOT require ezmemory_patch.
--   - We do NOT recompute MaxHP from a fixed BASE_HP.
--   - Option 2 assumption:
--       On reconnect, vanilla eznpcs/ezmemory will recompute MaxHP from items.
--=====================================================

local Direction = require("scripts/libs/direction")
local ezmemory  = require("scripts/ezlibs-scripts/ezmemory")

print("[hpmem_shop_bot] LOADING ezmemory=" .. tostring(ezmemory))

--=====================================================
-- Area / placement
--=====================================================

local area_id = "default"

local bot_pos = Net.get_object_by_name(area_id, "ShopHPMem")
assert(bot_pos, "[hpmem_shop_bot] Missing Tiled object named 'ShopHPMem' in area: " .. tostring(area_id))

local bot_id = Net.create_bot({
  name = "HP Mem",
  area_id = area_id,
  texture_path = "/server/assets/prog.png",
  animation_path = "/server/assets/prog.animation",
  x = bot_pos.x,
  y = bot_pos.y,
  z = bot_pos.z,
  solid = true
})

local mug_texture_path   = "resources/ow/prog/prog_mug.png"
local mug_animation_path = "resources/ow/prog/prog_mug.animation"

--=====================================================
-- Tuning
--=====================================================

local PRICE       = 50
local HPMEM_ITEM  = "HPMem"
local HPMEM_BONUS = 20

--=====================================================
-- Helpers
--=====================================================

local function dbg(msg)
  print("[hpmem_shop_bot] " .. msg)
end

local function unlock(player_id)
  pcall(function() Net.unlock_player_input(player_id) end)
end

local function safe_money(player_id)
  local m = Net.get_player_money(player_id)
  if type(m) ~= "number" then return 0 end
  return m
end

local function ensure_hpmem_item()
  -- Create the item definition if missing
  if ezmemory and type(ezmemory.get_or_create_item) == "function" then
    ezmemory.get_or_create_item(HPMEM_ITEM, "Increases max HP by 20.", true)
  elseif ezmemory and type(ezmemory.create_or_update_item) == "function" then
    ezmemory.create_or_update_item(HPMEM_ITEM, "Increases max HP by 20.", true)
  end
end

local function count_hpmem(player_id)
  if ezmemory and type(ezmemory.count_player_item) == "function" then
    return tonumber(ezmemory.count_player_item(player_id, HPMEM_ITEM)) or 0
  end
  return 0
end

local function apply_plus_max_hp_now(player_id, delta)
  delta = tonumber(delta) or 0
  if delta == 0 then return nil end

  local before_max = tonumber(Net.get_player_max_health(player_id)) or 100
  local before_hp  = tonumber(Net.get_player_health(player_id)) or before_max

  local want = before_max + delta
  if want < 1 then want = 1 end

  -- Preserve "missing HP" so we don't heal for free.
  local missing = before_max - before_hp
  if missing < 0 then missing = 0 end

  local new_hp = want - missing
  if new_hp < 1 then new_hp = 1 end
  if new_hp > want then new_hp = want end

  pcall(function()
    Net.set_player_max_health(player_id, want, false)
    Net.set_player_health(player_id, new_hp)
  end)

  return want
end

--=====================================================
-- Interaction
--=====================================================

Net:on("actor_interaction", function(event)
  local player_id = event.player_id

  -- Only react when THIS bot is interacted with.
  local interacted_id = event.actor_id or event.bot_id or event.entity_id
  if interacted_id ~= bot_id then return end

  Net.lock_player_input(player_id)

  local player_pos = Net.get_player_position(player_id)
  Net.set_bot_direction(bot_id, Direction.from_points(bot_pos, player_pos))

  Async.question_player(
    player_id,
    ("HPMem costs %dz. Buy 1?"):format(PRICE),
    mug_texture_path,
    mug_animation_path
  ).and_then(function(res)
    if res == nil then
      -- player disconnected
      return
    end

    if res ~= 1 then
      Net.message_player(player_id, "Maybe later.", mug_texture_path, mug_animation_path)
      unlock(player_id)
      return
    end

    local money = safe_money(player_id)
    if money < PRICE then
      Net.message_player(player_id, "Not enough zenny.", mug_texture_path, mug_animation_path)
      unlock(player_id)
      return
    end

    ensure_hpmem_item()

    -- Spend (persistent)
    local ok_spend = false
    if type(ezmemory.spend_player_money) == "function" then
      ok_spend = ezmemory.spend_player_money(player_id, PRICE) == true
    elseif type(ezmemory.set_player_money) == "function" then
      ezmemory.set_player_money(player_id, money - PRICE)
      ok_spend = true
    end

    if not ok_spend then
      Net.message_player(player_id, "Shop error: couldn't spend money.", mug_texture_path, mug_animation_path)
      unlock(player_id)
      return
    end

    -- Give the ITEM (persistent)
    if type(ezmemory.give_player_item) ~= "function" then
      Net.message_player(player_id, "Shop error: item system missing.", mug_texture_path, mug_animation_path)
      unlock(player_id)
      return
    end
local before_max = tonumber(Net.get_player_max_health(player_id)) or 100

-- Count before -> give -> count after (for accurate message)
local before_count = count_hpmem(player_id)
ezmemory.give_player_item(player_id, HPMEM_ITEM, 1)
local after_count = count_hpmem(player_id)

-- If vanilla already applied the +20 as a side-effect of giving the item,
-- do NOT apply again. If it didn't, we apply +20 for instant HUD feedback.
local mid_max = tonumber(Net.get_player_max_health(player_id)) or before_max
if mid_max <= before_max then
  apply_plus_max_hp_now(player_id, HPMEM_BONUS)
end

local after_max = tonumber(Net.get_player_max_health(player_id)) or before_max

    Net.message_player(
      player_id,
      ("Sold 1 HPMem. Total=%d. MaxHP=%d."):format(tonumber(after_count) or 0, tonumber(after_max) or 0),
      mug_texture_path,
      mug_animation_path
    )

    dbg(string.format(
      "sale player=%s cost=%d count=%d->%d max=%d->%d",
      tostring(player_id), PRICE,
      tonumber(before_count) or 0, tonumber(after_count) or 0,
      tonumber(before_max) or 0, tonumber(after_max) or 0
    ))

    unlock(player_id)
  end)
end)

print("[hpmem_shop_bot] LOADED bot_id=" .. tostring(bot_id))
