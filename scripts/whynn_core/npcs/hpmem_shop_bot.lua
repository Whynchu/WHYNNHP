--=====================================================
-- hpmem_shop_bot.lua
--
-- BN SHOP using simple_menu + sprite-dialog overlay
-- UPDATED for latest API:
--   - Net.message_player has NO callback / NO options
--   - Use Net.virtual_input + our own sprite prompt BEFORE opening menu
--
-- Flow:
--   Interact -> PRE-PROMPT (textbox: Confirm=Yes / Cancel=No)
--            -> if Yes: open full shop menu
--            -> if No : unlock + clear busy
--=====================================================

local Direction    = require("scripts/libs/direction")
local ezmemory     = require("scripts/ezlibs-scripts/ezmemory")
local simple_menu  = require("scripts/whynn_core/ui/simple_menu")
local font_dialog  = require("scripts/whynn_core/ui/font_dialog")

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
local shop_busy     = {}  -- player_id -> true
local exit_cd_until = {}  -- player_id -> os.clock timestamp

local function busy_get(pid) return shop_busy[pid] == true end
local function busy_set(pid, v) if v then shop_busy[pid] = true else shop_busy[pid] = nil end end

local function in_exit_cooldown(pid)
  local t = exit_cd_until[pid]
  return (t ~= nil) and (os.clock() < t)
end

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
local shop_state = {} -- player_id -> { phase, closing }

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
      simple_menu.dialog_set_next(pid, false)
      simple_menu.block_inputs_until_release(pid, 0.35, 0.12)
      if type(on_ok) == "function" then on_ok() end
    end,
    function()
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
-- Open shop menu (full UI)
--=====================================================
local function open_shop_menu(pid)
  sreset(pid)

  simple_menu.open(pid, {
    title = "PROG_SHOP",
    money = fmt_m(safe_money(pid)),
    items = build_items(),
    max_visible = 4,
    focus = "menu",
    dialog_open = true,
    dialog_text = "See anything you like?",
    dialog_show_next = false,
    dialog_mug_state = "TALK"
  }, function(result)
    local st = sget(pid)
    if st.closing then
      return { keep_open = true }
    end

    st.phase = "LIST"

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

  goto_list(pid, "See anything you like?")
end

--=====================================================
-- PRE-MENU PROMPT (sprite textbox, uses Net.virtual_input)
--=====================================================
local PROMPT = {
  TEX  = "/server/assets/ui/textbox.png",
  ANIM = "/server/assets/ui/textbox.animation",
  MUG_TEX  = "/server/assets/ow/prog/prog_mug.png",
  MUG_ANIM = "/server/assets/ow/prog/prog_mug.animation",
}

local PROMPT_X, PROMPT_Y = 4, 255
local PROMPT_Z = 9000
local UI_SCALE = 2.0

local PROMPT_MUG_OX, PROMPT_MUG_OY = 3, -23
local PROMPT_TEXT_OX, PROMPT_TEXT_OY = 62, -14
local PROMPT_TEXT_MAX_W = 164
local PROMPT_LINES = 2
local PROMPT_MAX_GLYPHS = 64

local TINT_BLACK = { r = 24, g = 24, b = 40 }

local pre_prompt = {} -- pid -> state

local function provide(pid, path)
  pcall(function() Net.provide_asset_for_player(pid, path) end)
end

local function alloc(pid, sprite_id, tex, anim, state)
  local params = { texture_path = tex }
  if anim then
    params.anim_path = anim
    params.anim_state = state or "A"
  end
  pcall(function() Net.player_alloc_sprite(pid, sprite_id, params) end)
end

local function draw(pid, sprite_id, obj)
  Net.player_draw_sprite(pid, sprite_id, obj)
end

local function erase(pid, obj_id)
  pcall(function() Net.player_erase_sprite(pid, obj_id) end)
end

local function dealloc(pid, sprite_id)
  pcall(function() Net.player_dealloc_sprite(pid, sprite_id) end)
end

local function measure_text_px(text, adv, space_adv)
  text = tostring(text or "")
  local w = 0
  for i = 1, #text do
    local ch = text:sub(i,i)
    if ch == " " then w = w + space_adv else w = w + adv end
  end
  return w
end

local function wrap_lines(text, max_w_px, adv, space_adv, max_lines)
  max_lines = max_lines or 2
  text = tostring(text or ""):gsub("\r\n", "\n")

  local words = {}
  for w in text:gmatch("%S+") do words[#words+1] = w end

  local lines, cur = {}, ""
  local function wpx(s) return measure_text_px(s, adv, space_adv) end

  for i = 1, #words do
    local w = words[i]
    local candidate = (cur == "") and w or (cur .. " " .. w)
    if wpx(candidate) <= max_w_px or cur == "" then
      cur = candidate
    else
      lines[#lines+1] = cur
      cur = w
      if #lines >= max_lines then break end
    end
  end
  if #lines < max_lines and cur ~= "" then lines[#lines+1] = cur end
  while #lines < max_lines do lines[#lines+1] = "" end
  return lines
end

local function ensure_key_state(st)
  if not st.key_state then st.key_state = {} end
end

local function edge_pressed(st, evmap, name)
  ensure_key_state(st)
  local prev = st.key_state[name]
  if prev == nil then prev = 0 end

  local cur = evmap[name]
  if cur == nil then return false end

  if cur == 0 then cur = 1 end -- treat Pressed as Held for edge logic

  if cur == 2 then
    st.key_state[name] = 0
    return false
  end

  if cur == 1 then
    st.key_state[name] = 1
    return prev == 0
  end

  return false
end

local function build_event_map(ev)
  local m = {}
  for i = 1, #ev do
    m[ev[i].name] = ev[i].state
  end
  return m
end

local function pre_prompt_close(pid)
  local st = pre_prompt[pid]
  if not st then return end
  pre_prompt[pid] = nil

  erase(pid, st.obj_box)
  erase(pid, st.obj_mug)
  font_dialog.erase(pid, st.obj_line .. "_1", PROMPT_MAX_GLYPHS)
  font_dialog.erase(pid, st.obj_line .. "_2", PROMPT_MAX_GLYPHS)

  dealloc(pid, st.sprite_box)
  dealloc(pid, st.sprite_mug)
  font_dialog.dealloc(pid, st.sprite_font)
end

local function pre_prompt_render(pid)
  local st = pre_prompt[pid]
  if not st then return end

  local sx, sy = UI_SCALE, UI_SCALE
  local dx, dy = PROMPT_X, PROMPT_Y

  -- NO anim_state here -> prevents restart spam
  draw(pid, st.sprite_box, {
    id = st.obj_box,
    x = dx, y = dy, z = PROMPT_Z,
    sx = sx, sy = sy,
    a = 255
  })

  draw(pid, st.sprite_mug, {
    id = st.obj_mug,
    x = dx + (PROMPT_MUG_OX * sx),
    y = dy + (PROMPT_MUG_OY * sy),
    z = PROMPT_Z + 1,
    sx = sx, sy = sy,
    a = 255
  })

  local adv_px = (font_dialog.ADV or 6) * sx
  local sp_px  = (font_dialog.SPACE_ADV or 3) * sx
  local max_w  = PROMPT_TEXT_MAX_W * sx

  local lines = wrap_lines(st.text, max_w, adv_px, sp_px, PROMPT_LINES)

  font_dialog.erase(pid, st.obj_line .. "_1", PROMPT_MAX_GLYPHS)
  font_dialog.erase(pid, st.obj_line .. "_2", PROMPT_MAX_GLYPHS)

  local tx = dx + (PROMPT_TEXT_OX * sx)
  local ty = dy + (PROMPT_TEXT_OY * sy)
  local line_dy = (font_dialog.LINE_DY or 9) * sy

  font_dialog.draw(pid, st.sprite_font, st.obj_line .. "_1",
    lines[1], tx, ty, PROMPT_Z + 2,
    sx, sy, nil, nil, TINT_BLACK
  )

  font_dialog.draw(pid, st.sprite_font, st.obj_line .. "_2",
    lines[2], tx, ty + line_dy, PROMPT_Z + 2,
    sx, sy, nil, nil, TINT_BLACK
  )
end

local function pre_prompt_open(pid, text, on_yes, on_no)
  -- Lock input so we receive virtual_input events
  pcall(function() Net.lock_player_input(pid) end)

  provide(pid, PROMPT.TEX)
  provide(pid, PROMPT.ANIM)
  provide(pid, PROMPT.MUG_TEX)
  provide(pid, PROMPT.MUG_ANIM)

  local sprite_font = "pre_font_" .. pid
  font_dialog.ensure(pid, sprite_font)

  local st = {
    text = tostring(text or "Wanna take a look? (Confirm=Yes / Cancel=No)"),
    key_state = {},
    on_yes = on_yes,
    on_no  = on_no,

    sprite_box  = "pre_box_" .. pid,
    sprite_mug  = "pre_mug_" .. pid,
    sprite_font = sprite_font,

    obj_box  = "pre_box_obj_" .. pid,
    obj_mug  = "pre_mug_obj_" .. pid,
    obj_line = "pre_line_" .. pid,
  }

  pre_prompt[pid] = st

  -- Set anim_state ONCE at alloc time
  alloc(pid, st.sprite_box, PROMPT.TEX, PROMPT.ANIM, "OPEN")
  alloc(pid, st.sprite_mug, PROMPT.MUG_TEX, PROMPT.MUG_ANIM, "TALK")

  pre_prompt_render(pid)
end

-- Handle pre-prompt input
Net:on("virtual_input", function(event)
  local pid = event.player_id
  local st = pre_prompt[pid]
  if not st then return end

  local evmap = build_event_map(event.events or {})

  local confirm_edge =
      edge_pressed(st, evmap, "Confirm") or
      edge_pressed(st, evmap, "Interact") or
      edge_pressed(st, evmap, "Use Card")

  local cancel_edge =
      edge_pressed(st, evmap, "Cancel") or
      edge_pressed(st, evmap, "Back") or
      edge_pressed(st, evmap, "Cust Menu") or
      edge_pressed(st, evmap, "Run")

  if confirm_edge then
    local yes_cb = st.on_yes
    pre_prompt_close(pid) -- keep input locked; menu will use it
    if type(yes_cb) == "function" then yes_cb() end
    return
  end

  if cancel_edge then
    local no_cb = st.on_no
    pre_prompt_close(pid)
    pcall(function() Net.unlock_player_input(pid) end)
    if type(no_cb) == "function" then no_cb() end
    return
  end
end)

--=====================================================
-- Disconnect cleanup
--=====================================================
Net:on("player_disconnect", function(event)
  local pid = event.player_id
  shop_busy[pid] = nil
  exit_cd_until[pid] = nil
  shop_state[pid] = nil

  if pre_prompt[pid] then
    pre_prompt_close(pid)
    pcall(function() Net.unlock_player_input(pid) end)
  end
end)

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

  -- If pre-prompt already open, ignore repeat interactions
  if pre_prompt[player_id] then
    dbg("interaction ignored: pre-prompt already open")
    return
  end

  busy_set(player_id, true)

  local player_pos = Net.get_player_position(player_id)
  Net.set_bot_direction(bot_id, Direction.from_points(bot_pos, player_pos))

  dbg("pre-prompt before opening shop")

  pre_prompt_open(player_id,
    "Wanna take a look? (Confirm=Yes / Cancel=No)",
    function()
      dbg("player accepted; opening shop UI")
      open_shop_menu(player_id) -- menu takes over while input remains locked
    end,
    function()
      dbg("player declined; not opening shop")
      busy_set(player_id, false)
    end
  )
end)

print("[hpmem_shop_bot] LOADED bot_id=" .. tostring(bot_id))
