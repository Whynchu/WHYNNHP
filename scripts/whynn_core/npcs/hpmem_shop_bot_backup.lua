--=====================================================
-- hpmem_shop_bot.lua
--
-- BN SHOP using simple_menu + sprite-dialog overlay (NO widget dialogs)
-- - NPC textbox stays open while browsing
-- - Confirm/Cancel prompts are handled in-dialog (focus="dialog")
-- - No Async.message_player / Async.question_player
-- - No button swapping; clean state machine
--=====================================================

local Direction   = require("scripts/libs/direction")
local ezmemory    = require("scripts/ezlibs-scripts/ezmemory")
local simple_menu = require("scripts/whynn_core/ui/simple_menu")

local DEBUG = true
local function dbg(msg)
  if not DEBUG then return end
  print("[hpmem_shop_bot] " .. msg)
end

--=====================================================
-- Area / placement
--=====================================================
local area_id = "default"

local bot_pos = Net.get_object_by_name(area_id, "ShopHPMem")
assert(bot_pos, "[hpmem_shop_bot] Missing Tiled object named 'ShopHPMem' in area: " .. tostring(area_id))

local bot_id = Net.create_bot({
  name = "HP Mem",
  area_id = area_id,
texture_path = "/server/assets/ow/prog/prog_ow.png",
animation_path = "/server/assets/ow/prog/prog_ow.animation",

  x = bot_pos.x,
  y = bot_pos.y,
  z = bot_pos.z,
  solid = true
})

--=====================================================
-- Tuning
--=====================================================
local PRICE_PER   = 50
local HPMEM_ITEM  = "HPMem"
local HPMEM_BONUS = 20

--=====================================================
-- Guards
--=====================================================
local shop_busy      = {}  -- player_id -> true
local exit_cd_until  = {}  -- player_id -> os.clock timestamp

local function busy_get(pid) return shop_busy[pid] == true end
local function busy_set(pid, v) if v then shop_busy[pid] = true else shop_busy[pid] = nil end end

local function in_exit_cooldown(pid)
  local t = exit_cd_until[pid]
  return (t ~= nil) and (os.clock() < t)
end

Net:on("player_disconnect", function(event)
  local pid = event.player_id
  shop_busy[pid] = nil
  exit_cd_until[pid] = nil
end)

--=====================================================
-- Money + ezmemory helpers
--=====================================================
local function fmt_m(n)
  return tostring(tonumber(n) or 0) .. "m"
end

local function safe_money(player_id)
  if ezmemory and type(ezmemory.get_player_money) == "function" then
    local m = ezmemory.get_player_money(player_id)
    if type(m) == "number" then return m end
  end
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

local function apply_plus_max_hp_now(player_id, delta)
  delta = tonumber(delta) or 0
  if delta == 0 then return nil end

  local before_max = tonumber(Net.get_player_max_health(player_id)) or 100
  local before_hp  = tonumber(Net.get_player_health(player_id)) or before_max

  local want = before_max + delta
  if want < 1 then want = 1 end

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
-- Shop items
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
-- Per-player shop state machine
--=====================================================
local shop_state = {} -- player_id -> { phase, pending_qty, pending_cost, closing }

local function sget(pid)
  if not shop_state[pid] then
    shop_state[pid] = { phase = "NONE", closing = false }
  end
  return shop_state[pid]
end

local function sreset(pid)
  shop_state[pid] = { phase = "NONE", closing = false }
end

local function close_shop(pid)
  local st = sget(pid)
  if st.closing then return end
  st.closing = true

  -- cooldown BEFORE close to avoid immediate re-interact
  exit_cd_until[pid] = os.clock() + 0.90

  simple_menu.close(pid, { cancelled = true })
  busy_set(pid, false)
  shop_state[pid] = nil
end

local function goto_list(pid, text)
  local st = sget(pid)
  st.phase = "LIST"
  simple_menu.set_focus(pid, "menu")
  simple_menu.dialog_open(pid, text or "See anything you like?", false, "TALK")
  simple_menu.dialog_set_handlers(pid, nil, nil)
  simple_menu.block_inputs_until_release(pid, 0.40, 0.14)
end

local function show_info(pid, text, on_ok)
  local st = sget(pid)
  st.phase = "INFO"
  simple_menu.set_focus(pid, "dialog")
  simple_menu.dialog_open(pid, text or "", true, "TALK")

  simple_menu.dialog_set_handlers(pid,
    function()
      -- Confirm on info page
      simple_menu.dialog_set_next(pid, false)
      simple_menu.block_inputs_until_release(pid, 0.35, 0.12)
      if type(on_ok) == "function" then on_ok() end
    end,
    function()
      -- Cancel on info page behaves same as Confirm (optional)
      simple_menu.dialog_set_next(pid, false)
      simple_menu.block_inputs_until_release(pid, 0.35, 0.12)
      if type(on_ok) == "function" then on_ok() end
    end
  )
end

local function prompt_yesno(pid, text, on_yes, on_no)
  local st = sget(pid)
  st.phase = "PROMPT"
  simple_menu.set_focus(pid, "dialog")
  simple_menu.dialog_open(pid, text or "", false, "TALK")

  simple_menu.dialog_set_handlers(pid,
    function()
      simple_menu.block_inputs_until_release(pid, 0.45, 0.14)
      if type(on_yes) == "function" then on_yes() end
    end,
    function()
      simple_menu.block_inputs_until_release(pid, 0.45, 0.14)
      if type(on_no) == "function" then on_no() end
    end
  )
end

local function do_purchase(pid, qty, cost)
  local money = safe_money(pid)
  dbg("purchase attempt money=" .. tostring(money) .. " cost=" .. tostring(cost) .. " qty=" .. tostring(qty))

  if money < cost then
    show_info(pid, "Not enough zenny.", function()
      goto_list(pid, "Anything else?")
    end)
    return
  end

  ensure_hpmem_item()

  local ok_spend = spend_money_persistent(pid, cost, money)
  dbg("spend ok=" .. tostring(ok_spend))
  if not ok_spend then
    show_info(pid, "Shop error: couldn't spend money.", function()
      goto_list(pid, "Anything else?")
    end)
    return
  end

  if type(ezmemory.give_player_item) ~= "function" then
    show_info(pid, "Shop error: item system missing.", function()
      goto_list(pid, "Anything else?")
    end)
    return
  end

  local before_max   = tonumber(Net.get_player_max_health(pid)) or 100
  local before_count = count_hpmem(pid)

  ezmemory.give_player_item(pid, HPMEM_ITEM, qty)

  local after_count = count_hpmem(pid)
  local mid_max     = tonumber(Net.get_player_max_health(pid)) or before_max
  if mid_max <= before_max then
    apply_plus_max_hp_now(pid, HPMEM_BONUS * qty)
  end

  local after_max = tonumber(Net.get_player_max_health(pid)) or before_max

  simple_menu.set_money(pid, fmt_m(safe_money(pid)))

  show_info(pid, ("Purchased %dx HPMem. Total=%d. MaxHP=%d."):format(qty, after_count or 0, after_max or 0),
    function()
      goto_list(pid, "Anything else?")
    end
  )

  dbg(string.format(
    "sale player=%s cost=%d qty=%d count=%d->%d max=%d->%d",
    tostring(pid), cost, qty,
    tonumber(before_count) or 0, tonumber(after_count) or 0,
    tonumber(before_max) or 0, tonumber(after_max) or 0
  ))
end

--=====================================================
-- Open shop flow
--=====================================================
local function open_shop_menu(pid)
  sreset(pid)

  simple_menu.open(pid, {
    title = "PROG_SHOP",
    money = fmt_m(safe_money(pid)),
    items = build_items(),
    max_visible = 4,
    focus = "dialog",        -- start in dialog (greet)
    dialog_open = true,
    dialog_text = "See anything you like?",
    dialog_show_next = false,
    dialog_mug_state = "TALK"
  }, function(result)
    local st = sget(pid)
    if st.closing then
      return { keep_open = true }
    end

    -- If we're not in menu focus, ignore list events (safety)
    if st.phase ~= "LIST" then
      return { keep_open = true }
    end

    -- Cancel from menu -> leave confirm
    if result and result.cancelled then
      prompt_yesno(pid, "Leaving so soon? (Confirm=Yes / Cancel=No)",
        function()
          show_info(pid, "Come again!", function()
            close_shop(pid)
          end)
        end,
        function()
          goto_list(pid, "Anything else?")
        end
      )
      return { keep_open = true }
    end

    -- Confirm on item -> buy confirm prompt
    local pick = result and result.item
    if not pick then
      return { keep_open = true }
    end

    local qty  = qty_from_item_id(pick.id)
    local cost = PRICE_PER * qty

    prompt_yesno(pid, ("Buy %dx HPMem for %dm? (Confirm=Yes / Cancel=No)"):format(qty, cost),
      function()
        do_purchase(pid, qty, cost)
      end,
      function()
        goto_list(pid, "See anything you like?")
      end
    )

    return { keep_open = true }
  end)

  -- greet prompt handlers (dialog focus)
  prompt_yesno(pid, "Wanna take a look? (Confirm=Yes / Cancel=No)",
    function()
      goto_list(pid, "See anything you like?")
    end,
    function()
      show_info(pid, "Maybe later.", function()
        close_shop(pid)
      end)
    end
  )
end

--=====================================================
-- Interaction
--=====================================================
Net:on("actor_interaction", function(event)
  local player_id = event.player_id
  local interacted_id = event.actor_id or event.bot_id or event.entity_id
  if interacted_id ~= bot_id then return end

  if in_exit_cooldown(player_id) then
    dbg("interaction ignored: exit cooldown")
    return
  end

  if busy_get(player_id) then
    dbg("interaction ignored: busy")
    return
  end
  busy_set(player_id, true)

  local player_pos = Net.get_player_position(player_id)
  Net.set_bot_direction(bot_id, Direction.from_points(bot_pos, player_pos))

  dbg("opening shop UI")
  open_shop_menu(player_id)
end)

print("[hpmem_shop_bot] LOADED bot_id=" .. tostring(bot_id))
