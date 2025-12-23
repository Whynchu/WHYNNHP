--=====================================================
-- hpmem_shop_bot.lua
--
-- Purpose:
--   Sell "HPMem" as a TRUE ezmemory ITEM (vanilla behavior).
--   Purchase:
--     - spends zenny persistently via ezmemory
--     - gives Nx HPMem item (persistent, server-side)
--     - immediately increases current MaxHP by +20 * N (HUD updates now)
--
-- Notes:
--   - We do NOT require ezmemory_patch.
--   - We do NOT recompute MaxHP from a fixed BASE_HP.
--   - If vanilla already applies MaxHP from items on grant, we avoid double-apply.
--
-- Fixes:
--   - Do NOT unlock input before opening the menu (prevents held-button re-trigger).
--   - Unlock input if question dialog returns nil (disconnect / abort).
--   - Optional: busy-guard to prevent re-entry spam while menu/dialog is active.
--=====================================================

local Direction   = require("scripts/libs/direction")
local ezmemory    = require("scripts/ezlibs-scripts/ezmemory")
local simple_menu = require("scripts/whynn_core/ui/simple_menu")

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

local PRICE_PER = 50
local HPMEM_ITEM  = "HPMem"
local HPMEM_BONUS = 20

--=====================================================
-- Busy guard (prevents re-open spam while still holding buttons)
--=====================================================

local shop_busy = {} -- player_id -> true

local function busy_get(player_id)
  return shop_busy[player_id] == true
end

local function busy_set(player_id, v)
  if v then shop_busy[player_id] = true else shop_busy[player_id] = nil end
end

Net:on("player_disconnect", function(event)
  shop_busy[event.player_id] = nil
end)

--=====================================================
-- Helpers
--=====================================================

local function dbg(msg)
  print("[hpmem_shop_bot] " .. msg)
end

local function unlock(player_id)
  pcall(function() Net.unlock_player_input(player_id) end)
end

local function fmt_m(n)
  return tostring(tonumber(n) or 0) .. "m"
end

local function safe_money(player_id)
  -- Prefer persistent server-side money from ezmemory if available
  if ezmemory and type(ezmemory.get_player_money) == "function" then
    local m = ezmemory.get_player_money(player_id)
    if type(m) == "number" then return m end
  end

  -- Fallback to engine money
  local m = Net.get_player_money(player_id)
  if type(m) ~= "number" then return 0 end
  return m
end

local function ensure_hpmem_item()
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

local function spend_money_persistent(player_id, cost, money_now)
  local ok = false
  if type(ezmemory.spend_player_money) == "function" then
    ok = ezmemory.spend_player_money(player_id, cost) == true
  elseif type(ezmemory.set_player_money) == "function" then
    ezmemory.set_player_money(player_id, (tonumber(money_now) or 0) - cost)
    ok = true
  end
  return ok
end

--=====================================================
-- Shop menu data
--=====================================================

local function build_items()
  return {
    { id = "HPMEM_1", label = ("HPMem  %d+"):format(PRICE_PER * 1) },
    { id = "HPMEM_2", label = ("HPMem2 %d+"):format(PRICE_PER * 2) },
    { id = "HPMEM_3", label = ("HPMem3 %d+"):format(PRICE_PER * 3) },
    { id = "HPMEM_4", label = ("HPMem4 %d+"):format(PRICE_PER * 4) },
    { id = "HPMEM_5", label = ("HPMem5 %d+"):format(PRICE_PER * 5) },
  }
end

local function qty_from_item_id(id)
  if id == "HPMEM_1" then return 1 end
  if id == "HPMEM_2" then return 2 end
  if id == "HPMEM_3" then return 3 end
  if id == "HPMEM_4" then return 4 end
  if id == "HPMEM_5" then return 5 end
  return 1
end

--=====================================================
-- Interaction
--=====================================================

Net:on("actor_interaction", function(event)
  local player_id = event.player_id

  local interacted_id = event.actor_id or event.bot_id or event.entity_id
  if interacted_id ~= bot_id then return end

  -- Prevent re-entry spam while dialog/menu is active.
  if busy_get(player_id) then
    return
  end
  busy_set(player_id, true)

  -- lock input for the yes/no question dialog
  Net.lock_player_input(player_id)

  local player_pos = Net.get_player_position(player_id)
  Net.set_bot_direction(bot_id, Direction.from_points(bot_pos, player_pos))

  Async.question_player(
    player_id,
    "Wanna take a look?",
    mug_texture_path,
    mug_animation_path
  ).and_then(function(res)
    if res == nil then
      unlock(player_id)
      busy_set(player_id, false)
      return
    end

    if res ~= 1 then
      Net.message_player(player_id, "Maybe later.", mug_texture_path, mug_animation_path)
      unlock(player_id)
      busy_set(player_id, false)
      return
    end

    -- IMPORTANT:
    -- DO NOT unlock here.
    -- The menu manages lock/unlock during its lifetime.
    simple_menu.open(player_id, {
      title = "PROG_SHOP",
      money = fmt_m(safe_money(player_id)),
      items = build_items(),
      max_visible = 4
    }, function(result)
      -- Always clear busy when the menu ends.
      if result == nil then
        busy_set(player_id, false)
        return
      end

      if result.cancelled then
        busy_set(player_id, false)
        return
      end

      local pick = result.item
      local qty  = qty_from_item_id(pick.id)
      local cost = PRICE_PER * qty

      local money = safe_money(player_id)
      if money < cost then
        Net.message_player(player_id, "Not enough zenny.", mug_texture_path, mug_animation_path)
        busy_set(player_id, false)
        return
      end

      ensure_hpmem_item()

      local ok_spend = spend_money_persistent(player_id, cost, money)
      if not ok_spend then
        Net.message_player(player_id, "Shop error: couldn't spend money.", mug_texture_path, mug_animation_path)
        busy_set(player_id, false)
        return
      end

      if type(ezmemory.give_player_item) ~= "function" then
        Net.message_player(player_id, "Shop error: item system missing.", mug_texture_path, mug_animation_path)
        busy_set(player_id, false)
        return
      end

      local before_max   = tonumber(Net.get_player_max_health(player_id)) or 100
      local before_count = count_hpmem(player_id)

      ezmemory.give_player_item(player_id, HPMEM_ITEM, qty)

      local after_count = count_hpmem(player_id)
      local mid_max     = tonumber(Net.get_player_max_health(player_id)) or before_max

      -- If vanilla didn't bump max HP immediately, apply +20*qty now for instant HUD feedback.
      if mid_max <= before_max then
        apply_plus_max_hp_now(player_id, HPMEM_BONUS * qty)
      end

      local after_max = tonumber(Net.get_player_max_health(player_id)) or before_max

      Net.message_player(
        player_id,
        ("Sold %dx HPMem for %dm. Total=%d. MaxHP=%d."):format(qty, cost, tonumber(after_count) or 0, tonumber(after_max) or 0),
        mug_texture_path,
        mug_animation_path
      )

      dbg(string.format(
        "sale player=%s cost=%d qty=%d count=%d->%d max=%d->%d",
        tostring(player_id), cost, qty,
        tonumber(before_count) or 0, tonumber(after_count) or 0,
        tonumber(before_max) or 0, tonumber(after_max) or 0
      ))

      busy_set(player_id, false)
    end)
  end)
end)

print("[hpmem_shop_bot] LOADED bot_id=" .. tostring(bot_id))
