--=====================================================
-- simple_menu.lua
-- BN-style menu + dialogue overlay (2x scale)
-- FIX: dialog redraw is DIRTY-ONLY (no per-tick spam)
-- FIX: dialog tint removed (prevents black block tiles)
--=====================================================

local M = {}

--=====================================================
-- Requires
--=====================================================
local font_menu   = require("scripts/whynn_core/ui/font_menu")
local font_dialog = require("scripts/whynn_core/ui/font_dialog")

--=====================================================
-- Assets
--=====================================================
local PANEL_TEX  = "/server/assets/ui/prog_shop_2.png"
local CURSOR_TEX = "/server/assets/ui/select_cursor.png"
local SCROLL_THUMB_TEX = "/server/assets/ui/scrollbar.png"

local DIALOG_TEX  = "/server/assets/ui/textbox.png"
local DIALOG_ANIM = "/server/assets/ui/textbox.animation"
local NEXT_TEX    = "/server/assets/ui/textbox_next.png"
local MUG_TEX     = "/server/assets/ow/prog/prog_mug.png"
local MUG_ANIM    = "/server/assets/ow/prog/prog_mug.animation"



--=====================================================
-- Scale
--=====================================================
local UI_SCALE = 2.0

local TINT_BLACK = { r = 24, g = 24, b = 40 }
-- optional “BN dark ink” instead of pure black:
-- local TINT_INK = { r = 24, g = 24, b = 40 }

--=====================================================
-- Debug
--=====================================================
local DEBUG = true
local DEBUG_GLYPH_MARKERS = false
local DEBUG_GLYPH_PRINT_SUMMARY = false

local function dbg(msg)
  if not DEBUG then return end
  print("[simple_menu] " .. msg)
end

dbg(("font_menu TEX=%s ANIM=%s ADV=%s SPACE=%s"):format(
  tostring(font_menu.TEX), tostring(font_menu.ANIM), tostring(font_menu.ADV), tostring(font_menu.SPACE_ADV)
))
dbg(("font_dialog TEX=%s ANIM=%s ADV=%s SPACE=%s LINE_DY=%s"):format(
  tostring(font_dialog.TEX), tostring(font_dialog.ANIM), tostring(font_dialog.ADV), tostring(font_dialog.SPACE_ADV), tostring(font_dialog.LINE_DY)
))

--=====================================================
-- Menu Font packing
--=====================================================
local FONT_ADV   = 8
local SPACE_ADV  = 8
local TITLE_ADV  = FONT_ADV

--=====================================================
-- Layout
--=====================================================
local PANEL_X, PANEL_Y = 0, 0
local Z_BASE = 5000

local TITLE_OX, TITLE_OY = 65, 5
local MONEY_OY = 5
local MONEY_BOX_RIGHT_OX = 224

local LIST_OX,  LIST_OY  = 36, 26
local LIST_DY_BASE       = 16

local SCURSOR_OX        = 18
local SCURSOR_OY_OFFSET = 2

local SCROLL_OX     = 228
local SCROLL_PAD_Y  = 0
local THUMB_H_BASE  = 16

--=====================================================
-- Dialogue layout
--=====================================================
local DIALOG_X, DIALOG_Y = 4, 255
local DIALOG_Z = Z_BASE + 20

local MUG_OX, MUG_OY  = 3, -23
local TEXT_OX, TEXT_OY = 62, -14

local DIALOG_TEXT_MAX_W = 164
local DIALOG_LINES      = 2
local DIALOG_MAX_GLYPHS = 64

local NEXT_OX, NEXT_OY = 214, 42
local NEXT_BLINK_SEC   = 0.30

--=====================================================
-- Timing
--=====================================================
local OPEN_WARMUP_SEC   = 0.20
local CLOSE_TIMEOUT_SEC = 0.35
local MOVE_REPEAT_SEC   = 0.12

--=====================================================
-- State
--=====================================================
local ui_state = {} -- player_id -> state

--=====================================================
-- Helpers
--=====================================================
local function alloc(player_id, sprite_id, tex, anim, state)
  local params = { texture_path = tex }
  if anim ~= nil then
    params.anim_path  = anim
    params.anim_state = state or "A"
  end

  local ok, err = pcall(function()
    Net.player_alloc_sprite(player_id, sprite_id, params)
  end)

  if not ok then
    print(("[simple_menu] ALLOC FAIL sprite=%s tex=%s anim=%s state=%s err=%s")
      :format(tostring(sprite_id), tostring(tex), tostring(anim), tostring(state), tostring(err)))
  end
end

local function provide(player_id, path)
  local ok, err = pcall(function()
    Net.provide_asset_for_player(player_id, path)
  end)
  if not ok then
    print(("[simple_menu] PROVIDE FAIL path=%s err=%s"):format(tostring(path), tostring(err)))
  end
end

local function draw(player_id, sprite_id, obj)
  Net.player_draw_sprite(player_id, sprite_id, obj)
end

local function erase(player_id, obj_id)
  pcall(function() Net.player_erase_sprite(player_id, obj_id) end)
end

local function dealloc(player_id, sprite_id)
  pcall(function() Net.player_dealloc_sprite(player_id, sprite_id) end)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function set_anim_state(player_id, sprite_id, tex, anim, state)
  -- safest way: dealloc + alloc with new anim_state
  pcall(function() Net.player_dealloc_sprite(player_id, sprite_id) end)
  alloc(player_id, sprite_id, tex, anim, state)
end

local function build_event_map(ev)
  local m = {}
  for i = 1, #ev do
    m[ev[i].name] = ev[i].state
  end
  return m
end

local function ensure_key_state(st)
  if not st.key_state then st.key_state = {} end
end

local function edge_pressed(st, evmap, name)
  ensure_key_state(st)
  local prev = st.key_state[name]
  if prev == nil then prev = 0 end

  local cur = evmap[name]
  if cur == nil then
    return false
  end

  if cur == 0 then cur = 1 end

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

local function any_action_held(evmap)
  local function held(name)
    local s = evmap[name]
    return s == 0 or s == 1
  end

  return held("Confirm") or held("Interact") or held("Use Card")
      or held("Cancel")  or held("Back")
      or held("Cust Menu") or held("Run")
end

local function measure_text_px(text, adv, space_adv)
  text = tostring(text or "")
  local w = 0
  for i = 1, #text do
    local ch = text:sub(i,i)
    if ch == " " then
      w = w + space_adv
    else
      w = w + adv
    end
  end
  return w
end

-- This wrapper expects adv/space_adv in the SAME UNITS as max_w_px.
local function wrap_lines(text, max_w_px, adv, space_adv, max_lines)
  max_lines = max_lines or 2
  text = tostring(text or ""):gsub("\r\n", "\n")

  local words = {}
  for w in text:gmatch("%S+") do
    words[#words+1] = w
  end

  local lines = {}
  local cur = ""

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

  if #lines < max_lines and cur ~= "" then
    lines[#lines+1] = cur
  end

  while #lines < max_lines do
    lines[#lines+1] = ""
  end

  return lines
end

--=====================================================
-- Scrollbar math (fixed-size thumb; slides only)
--=====================================================
local function compute_scroll_thumb_y(st, list_y0, list_h, sy)
  if #st.items <= st.max_visible then
    return nil
  end

  local total = #st.items
  local visible = st.max_visible
  local max_scroll = total - visible
  if max_scroll < 1 then max_scroll = 1 end

  local thumb_h = THUMB_H_BASE * sy
  if thumb_h > list_h then thumb_h = list_h end

  local t = (st.scroll or 0) / max_scroll
  if t < 0 then t = 0 end
  if t > 1 then t = 1 end

  return list_y0 + (list_h - thumb_h) * t
end

--=====================================================
-- DEBUG markers
--=====================================================
local function draw_glyph_markers(player_id, st)
  if not DEBUG_GLYPH_MARKERS then return end

  local ms = 0.25 * UI_SCALE
  local mz = Z_BASE + 999

  local function mark(prefix, get_positions_fn)
    local pts = get_positions_fn(player_id, prefix)
    if not pts then return end

    for i = 1, #pts do
      local p = pts[i]
      local id = "dbg_" .. prefix .. "_" .. i
      draw(player_id, st.sprite_cursor, {
        id = id,
        x = p.x,
        y = p.y,
        z = mz,
        sx = ms,
        sy = ms,
        a = 180,
      })
    end

    if DEBUG_GLYPH_PRINT_SUMMARY and pts[1] then
      dbg(("first: ch='%s' state=%s at (%.1f,%.1f)"):format(tostring(pts[1].ch), tostring(pts[1].state), pts[1].x, pts[1].y))
    end
  end

  mark(st.obj_dline .. "_1", font_dialog.get_positions)
  mark(st.obj_dline .. "_2", font_dialog.get_positions)
end

--=====================================================
-- Render
--=====================================================
local function render(player_id)
  local st = ui_state[player_id]
  if not st or st.closing then return end

  local now = os.clock()
  local sx, sy = UI_SCALE, UI_SCALE

  local title_x = PANEL_X + TITLE_OX * sx
  local title_y = PANEL_Y + TITLE_OY * sy

  local money_y = PANEL_Y + MONEY_OY * sy
  local money_right_x = PANEL_X + MONEY_BOX_RIGHT_OX * sx

  local list_x  = PANEL_X + LIST_OX * sx
  local list_y0 = PANEL_Y + LIST_OY * sy
  local list_dy = LIST_DY_BASE * sy
  local list_h  = (st.max_visible * list_dy) + (SCROLL_PAD_Y * sy)

  local cursor_x  = PANEL_X + SCURSOR_OX * sx
  local cursor_y0 = list_y0 + SCURSOR_OY_OFFSET * sy

  local scroll_x = PANEL_X + SCROLL_OX * sx

  -- Panel always
  draw(player_id, st.sprite_panel, {
    id = st.obj_panel,
    x = PANEL_X, y = PANEL_Y, z = Z_BASE,
    sx = sx, sy = sy,
    a = 255
  })

  -- Title
  if st.menu_dirty then
    font_menu.erase(player_id, st.obj_title, 32)
    font_menu.draw(player_id, st.sprite_font_menu, st.obj_title, st.title, title_x, title_y, Z_BASE + 2, sx, sy, TITLE_ADV, SPACE_ADV)
  end

  -- Money (only when changed)
  if st.money_dirty then
    font_menu.erase(player_id, st.obj_money, 16)
    if st.money and st.money ~= "" then
      local w = measure_text_px(st.money, FONT_ADV, SPACE_ADV) * sx
      local money_x = money_right_x - w
      font_menu.draw(player_id, st.sprite_font_menu, st.obj_money, st.money, money_x, money_y, Z_BASE + 2, sx, sy, FONT_ADV, SPACE_ADV)
    end
  end

  -- Items (redraw if menu_dirty OR selection/scroll changed)
  if st.items_dirty then
    for i = 1, st.max_visible do
      local idx = st.scroll + i
      local item = st.items[idx]
      local prefix = st.obj_item .. "_" .. i

      font_menu.erase(player_id, prefix, 32)
      if item then
        font_menu.draw(player_id, st.sprite_font_menu, prefix, item.label, list_x, list_y0 + (i-1) * list_dy, Z_BASE + 2, sx, sy, FONT_ADV, SPACE_ADV)
      end
    end
    st.items_dirty = false
  end

  -- Cursor (always, cheap)
  erase(player_id, st.obj_cursor)
  if st.focus == "menu" then
    local row = st.selected - st.scroll
    draw(player_id, st.sprite_cursor, {
      id = st.obj_cursor,
      x = cursor_x,
      y = cursor_y0 + (row-1) * list_dy,
      z = Z_BASE + 3,
      sx = sx, sy = sy,
      a = 255
    })
  end

  -- Scroll thumb (always)
  erase(player_id, st.obj_scroll_thumb)
  local thumb_y = compute_scroll_thumb_y(st, list_y0, list_h, sy)
  if thumb_y then
    draw(player_id, st.sprite_scroll_thumb, {
      id = st.obj_scroll_thumb,
      x = scroll_x,
      y = thumb_y,
      z = Z_BASE + 4,
      sx = sx, sy = sy,
      a = 255
    })
  end

  --=====================================================
  -- Dialogue overlay
  --=====================================================
  if st.dialog_open then
    local dx, dy = DIALOG_X, DIALOG_Y

   draw(player_id, st.sprite_dialog, {
  id = st.obj_dialog,
  x = dx, y = dy, z = DIALOG_Z,
  sx = sx, sy = sy,
  a = 255
})

draw(player_id, st.sprite_mug, {
  id = st.obj_mug,
  x = dx + (MUG_OX * sx),
  y = dy + (MUG_OY * sy),
  z = DIALOG_Z + 1,
  sx = sx, sy = sy,
  a = 255
})


    -- Only erase+draw dialog glyphs when text changed
    if st.dialog_dirty then
      local adv_px = (font_dialog.ADV or FONT_ADV) * sx
      local sp_px  = (font_dialog.SPACE_ADV or SPACE_ADV) * sx
      local max_w_px = (DIALOG_TEXT_MAX_W * sx)

      local lines = wrap_lines(st.dialog_text, max_w_px, adv_px, sp_px, DIALOG_LINES)

      font_dialog.erase(player_id, st.obj_dline .. "_1", DIALOG_MAX_GLYPHS)
      font_dialog.erase(player_id, st.obj_dline .. "_2", DIALOG_MAX_GLYPHS)

      local tx = dx + (TEXT_OX * sx)
      local ty = dy + (TEXT_OY * sy)
      local line_dy = (font_dialog.LINE_DY or 9) * sy

font_dialog.draw(
  player_id, st.sprite_font_dialog, st.obj_dline .. "_1",
  lines[1], tx, ty, DIALOG_Z + 2,
  sx, sy,
  nil, nil,
  TINT_BLACK
)

font_dialog.draw(
  player_id, st.sprite_font_dialog, st.obj_dline .. "_2",
  lines[2], tx, ty + line_dy, DIALOG_Z + 2,
  sx, sy,
  nil, nil,
  TINT_BLACK
)

      st.dialog_dirty = false
    end

    erase(player_id, st.obj_next)

    if st.dialog_show_next then
      if now >= (st.dialog_next_blink_at or 0) then
        st.dialog_next_blink_at = now + NEXT_BLINK_SEC
        st.dialog_next_visible = not st.dialog_next_visible
      end

      if st.dialog_next_visible then
        draw(player_id, st.sprite_next, {
          id = st.obj_next,
          x = dx + (NEXT_OX * sx),
          y = dy + (NEXT_OY * sy),
          z = DIALOG_Z + 3,
          sx = sx, sy = sy,
          a = 255
        })
      end
    end

    draw_glyph_markers(player_id, st)
  else
    erase(player_id, st.obj_dialog)
    erase(player_id, st.obj_mug)
    erase(player_id, st.obj_next)
    font_dialog.erase(player_id, st.obj_dline .. "_1", DIALOG_MAX_GLYPHS)
    font_dialog.erase(player_id, st.obj_dline .. "_2", DIALOG_MAX_GLYPHS)
  end

  -- clear “one-shot” dirties
  st.menu_dirty = false
  st.money_dirty = false
end

--=====================================================
-- Close visuals now, unlock later
--=====================================================
local function erase_ui(player_id, st)
  erase(player_id, st.obj_panel)
  erase(player_id, st.obj_cursor)
  erase(player_id, st.obj_scroll_thumb)

  font_menu.erase(player_id, st.obj_title, 32)
  font_menu.erase(player_id, st.obj_money, 16)
  for i = 1, st.max_visible do
    font_menu.erase(player_id, st.obj_item .. "_" .. i, 32)
  end

  erase(player_id, st.obj_dialog)
  erase(player_id, st.obj_mug)
  erase(player_id, st.obj_next)
  font_dialog.erase(player_id, st.obj_dline .. "_1", DIALOG_MAX_GLYPHS)
  font_dialog.erase(player_id, st.obj_dline .. "_2", DIALOG_MAX_GLYPHS)

  if DEBUG_GLYPH_MARKERS then
    for i = 1, 200 do
      erase(player_id, "dbg_" .. st.obj_dline .. "_1_" .. i)
      erase(player_id, "dbg_" .. st.obj_dline .. "_2_" .. i)
    end
  end

  dealloc(player_id, st.sprite_panel)
  dealloc(player_id, st.sprite_cursor)
  dealloc(player_id, st.sprite_scroll_thumb)

  dealloc(player_id, st.sprite_dialog)
  dealloc(player_id, st.sprite_mug)
  dealloc(player_id, st.sprite_next)

  font_menu.dealloc(player_id, st.sprite_font_menu)
  font_dialog.dealloc(player_id, st.sprite_font_dialog)
end

local function finalize_close(player_id, st)
  dbg("finalize_close player=" .. tostring(player_id))

  ui_state[player_id] = nil
  pcall(function() Net.unlock_player_input(player_id) end)

  if st.callback_already_fired then return end
  st.callback_already_fired = true

  local cb = st.on_done
  local pending = st.pending_result
  st.pending_result = nil

  pcall(function()
    cb(pending)
  end)
end

--=====================================================
-- Public API
--=====================================================
function M.open(player_id, opts, on_done)
  opts = opts or {}
  on_done = on_done or function() end

  if ui_state[player_id] then
    return
  end

  local items = opts.items or {}
  if #items == 0 then
    on_done({ cancelled = true })
    return
  end

  dbg("open player=" .. tostring(player_id) ..
      " title=" .. tostring(opts.title) ..
      " items=" .. tostring(#items))

  Net.lock_player_input(player_id)

  pcall(function()
    provide(player_id, PANEL_TEX)
    provide(player_id, CURSOR_TEX)
    provide(player_id, SCROLL_THUMB_TEX)

    provide(player_id, DIALOG_TEX)
    provide(player_id, DIALOG_ANIM)
    provide(player_id, NEXT_TEX)
    provide(player_id, MUG_TEX)
    provide(player_id, MUG_ANIM)
  end)

  local sprite_font_menu   = "ui_font_menu_" .. player_id
  local sprite_font_dialog = "ui_font_dialog_" .. player_id

  font_menu.ensure(player_id, sprite_font_menu)
  font_dialog.ensure(player_id, sprite_font_dialog)

  local now = os.clock()

  local st = {
    block_until_release = false,
    block_started_at = 0,
    block_timeout_sec = 0.60,
    block_seen_held = false,
    block_min_sec = 0.12,

    title = opts.title or "MENU",
    money = opts.money,
    items = items,
    max_visible = opts.max_visible or 4,

    selected = 1,
    scroll = 0,

    next_move_at = 0,
    ready_at = now + OPEN_WARMUP_SEC,

    key_state = {},

    focus = opts.focus or "menu",

    dialog_open = opts.dialog_open or false,
    dialog_text = opts.dialog_text or "",
    dialog_mug_state = opts.dialog_mug_state or "IDLE",
    dialog_show_next = opts.dialog_show_next or false,
    dialog_next_blink_at = now + NEXT_BLINK_SEC,
    dialog_next_visible = true,

    on_dialog_confirm = nil,
    on_dialog_cancel  = nil,

    closing = false,
    close_started_at = 0,
    pending_result = nil,

    callback_already_fired = false,

    -- DIRTY FLAGS
    menu_dirty = true,
    money_dirty = true,
    items_dirty = true,
    dialog_dirty = true,

    sprite_panel        = "ui_panel_" .. player_id,
    sprite_cursor       = "ui_cursor_" .. player_id,
    sprite_scroll_thumb = "ui_scroll_thumb_" .. player_id,

    sprite_dialog = "ui_dialog_" .. player_id,
    sprite_mug    = "ui_mug_" .. player_id,
    sprite_next   = "ui_next_" .. player_id,

    sprite_font_menu   = sprite_font_menu,
    sprite_font_dialog = sprite_font_dialog,

    obj_panel        = "ui_panel_obj_" .. player_id,
    obj_cursor       = "ui_cursor_obj_" .. player_id,
    obj_title        = "ui_title_" .. player_id,
    obj_money        = "ui_money_" .. player_id,
    obj_item         = "ui_item_" .. player_id,
    obj_scroll_thumb = "ui_scroll_thumb_obj_" .. player_id,

    obj_dialog = "ui_dialog_obj_" .. player_id,
    obj_mug    = "ui_mug_obj_" .. player_id,
    obj_next   = "ui_next_obj_" .. player_id,
    obj_dline  = "ui_dline_" .. player_id,

    on_done = on_done,
  }

  ui_state[player_id] = st

  alloc(player_id, st.sprite_panel,  PANEL_TEX)
  alloc(player_id, st.sprite_cursor, CURSOR_TEX)
  alloc(player_id, st.sprite_scroll_thumb, SCROLL_THUMB_TEX)

  alloc(player_id, st.sprite_dialog, DIALOG_TEX, DIALOG_ANIM, "OPEN")
  alloc(player_id, st.sprite_mug,    MUG_TEX,    MUG_ANIM,    st.dialog_mug_state or "IDLE")
  alloc(player_id, st.sprite_next,   NEXT_TEX)

  render(player_id)
end

function M.block_inputs_until_release(player_id, timeout_sec, min_sec)
  local st = ui_state[player_id]
  if not st then return end
  st.block_until_release = true
  st.block_started_at = os.clock()
  st.block_timeout_sec = timeout_sec or 0.60
  st.block_min_sec = min_sec or 0.12
  st.block_seen_held = false
  st.key_state = {}
end

function M.set_money(player_id, money_str)
  local st = ui_state[player_id]
  if not st then return end
  money_str = tostring(money_str or "")
  if st.money == money_str then return end
  st.money = money_str
  st.money_dirty = true
  render(player_id)
end

function M.set_focus(player_id, focus)
  local st = ui_state[player_id]
  if not st then return end
  if focus ~= "menu" and focus ~= "dialog" then return end
  st.focus = focus
  st.key_state = {}
  st.next_move_at = os.clock() + OPEN_WARMUP_SEC
  st.ready_at = os.clock() + OPEN_WARMUP_SEC
  render(player_id)
end

function M.dialog_open(player_id, text, show_next, mug_state)
  local st = ui_state[player_id]
  if not st then return end
  st.dialog_open = true
  st.dialog_text = tostring(text or "")
  st.dialog_show_next = (show_next == true)
  st.dialog_mug_state = mug_state or "IDLE"
  st.dialog_next_visible = true
  st.dialog_next_blink_at = os.clock() + NEXT_BLINK_SEC
  st.dialog_dirty = true
  render(player_id)
end

function M.dialog_set_text(player_id, text)
  local st = ui_state[player_id]
  if not st then return end
  text = tostring(text or "")
  if st.dialog_text == text then return end
  st.dialog_text = text
  st.dialog_dirty = true
  render(player_id)
end

function M.dialog_set_next(player_id, show_next)
  local st = ui_state[player_id]
  if not st then return end
  st.dialog_show_next = (show_next == true)
  if st.dialog_show_next then
    st.dialog_next_visible = true
    st.dialog_next_blink_at = os.clock() + NEXT_BLINK_SEC
  end
  render(player_id)
end

function M.dialog_set_mug_state(player_id, mug_state)
  local st = ui_state[player_id]
  if not st then return end
  mug_state = mug_state or "IDLE"
  if st.dialog_mug_state == mug_state then return end

  st.dialog_mug_state = mug_state

  -- change animation ONLY on change (prevents restart spam)
  set_anim_state(player_id, st.sprite_mug, MUG_TEX, MUG_ANIM, mug_state)

  render(player_id)
end


function M.dialog_set_handlers(player_id, on_confirm, on_cancel)
  local st = ui_state[player_id]
  if not st then return end
  st.on_dialog_confirm = on_confirm
  st.on_dialog_cancel  = on_cancel
end

function M.dialog_close(player_id)
  local st = ui_state[player_id]
  if not st then return end
  st.dialog_open = false
  st.dialog_text = ""
  st.dialog_show_next = false
  st.on_dialog_confirm = nil
  st.on_dialog_cancel  = nil
  st.dialog_dirty = true
  render(player_id)
end

function M.close(player_id, result)
  local st = ui_state[player_id]
  if not st then return end
  st.pending_result = result or { cancelled = true }
  st.closing = true
  st.close_started_at = os.clock()
  erase_ui(player_id, st)
end

--=====================================================
-- Input handling
--=====================================================
Net:on("virtual_input", function(event)
  local player_id = event.player_id
  local st = ui_state[player_id]
  if not st then return end

  local ev = event.events or {}
  local evmap = build_event_map(ev)
  local now = os.clock()

  if st.block_until_release then
    local held = any_action_held(evmap)
    if held then
      st.block_seen_held = true
    end

    local elapsed = now - (st.block_started_at or now)
    local min_ok = elapsed >= (st.block_min_sec or 0.12)
    local timed_out = elapsed > (st.block_timeout_sec or 0.60)

    local can_clear = timed_out or (min_ok and st.block_seen_held and (not held))

    -- Allow Up/Down while blocking Confirm/Cancel
    if st.focus == "menu" then
      local can_move = now >= (st.next_move_at or 0)

      local up_edge =
          edge_pressed(st, evmap, "UI Up") or
          edge_pressed(st, evmap, "Move Up") or
          edge_pressed(st, evmap, "Up")

      local down_edge =
          edge_pressed(st, evmap, "UI Down") or
          edge_pressed(st, evmap, "Move Down") or
          edge_pressed(st, evmap, "Down")

      if can_move and up_edge then
        st.selected = clamp(st.selected - 1, 1, #st.items)
        st.next_move_at = now + MOVE_REPEAT_SEC
      elseif can_move and down_edge then
        st.selected = clamp(st.selected + 1, 1, #st.items)
        st.next_move_at = now + MOVE_REPEAT_SEC
      end

      local old_scroll = st.scroll
      if st.selected <= st.scroll then
        st.scroll = st.selected - 1
      elseif st.selected > st.scroll + st.max_visible then
        st.scroll = st.selected - st.max_visible
      end
      if st.scroll < 0 then st.scroll = 0 end

      if old_scroll ~= st.scroll then st.items_dirty = true end
      render(player_id)
    end

    if can_clear then
      st.block_until_release = false
      st.block_seen_held = false
      st.key_state = {}
      st.ready_at = now + OPEN_WARMUP_SEC
      st.next_move_at = now + OPEN_WARMUP_SEC
      render(player_id)
    end
    return
  end

  if st.ready_at and now < st.ready_at then
    return
  end

  if st.closing then
    local held = any_action_held(evmap)
    if (not held) or (now - st.close_started_at) > CLOSE_TIMEOUT_SEC then
      finalize_close(player_id, st)
    end
    return
  end

  local confirm_edge =
      edge_pressed(st, evmap, "Confirm") or
      edge_pressed(st, evmap, "Interact") or
      edge_pressed(st, evmap, "Use Card")

  local back_edge =
      edge_pressed(st, evmap, "Cancel") or
      edge_pressed(st, evmap, "Back") or
      edge_pressed(st, evmap, "Cust Menu") or
      edge_pressed(st, evmap, "Run")

  if st.focus == "dialog" then
    if confirm_edge and type(st.on_dialog_confirm) == "function" then
      pcall(function() st.on_dialog_confirm() end)
      return
    end
    if back_edge and type(st.on_dialog_cancel) == "function" then
      pcall(function() st.on_dialog_cancel() end)
      return
    end
    return
  end

  local can_move = now >= (st.next_move_at or 0)

  local up_edge =
      edge_pressed(st, evmap, "UI Up") or
      edge_pressed(st, evmap, "Move Up") or
      edge_pressed(st, evmap, "Up")

  local down_edge =
      edge_pressed(st, evmap, "UI Down") or
      edge_pressed(st, evmap, "Move Down") or
      edge_pressed(st, evmap, "Down")

  local old_sel = st.selected
  local old_scroll = st.scroll

  if can_move and up_edge then
    st.selected = clamp(st.selected - 1, 1, #st.items)
    st.next_move_at = now + MOVE_REPEAT_SEC

  elseif can_move and down_edge then
    st.selected = clamp(st.selected + 1, 1, #st.items)
    st.next_move_at = now + MOVE_REPEAT_SEC

  elseif confirm_edge then
    local idx = st.selected
    local res = { cancelled = false, index = idx, item = st.items[idx] }

    local action = nil
    pcall(function() action = st.on_done(res) end)

    if type(action) == "table" and action.keep_open then
      -- caller may have updated money; keep menu open
      render(player_id)
      return
    end

    st.pending_result = res
    st.closing = true
    st.close_started_at = now
    erase_ui(player_id, st)
    return

  elseif back_edge then
    local res = { cancelled = true }

    local action = nil
    pcall(function() action = st.on_done(res) end)

    if type(action) == "table" and action.keep_open then
      render(player_id)
      return
    end

    st.pending_result = res
    st.closing = true
    st.close_started_at = now
    erase_ui(player_id, st)
    return
  end

  if st.selected <= st.scroll then
    st.scroll = st.selected - 1
  elseif st.selected > st.scroll + st.max_visible then
    st.scroll = st.selected - st.max_visible
  end
  if st.scroll < 0 then st.scroll = 0 end

  if st.selected ~= old_sel or st.scroll ~= old_scroll then
    st.items_dirty = true
  end

  render(player_id)
end)

Net:on("player_disconnect", function(event)
  local player_id = event.player_id
  local st = ui_state[player_id]
  if not st then return end

  pcall(function()
    erase_ui(player_id, st)
  end)

  ui_state[player_id] = nil
end)

return M
