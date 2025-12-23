--=====================================================
-- simple_menu.lua
--
-- BN-style menu with:
--  - 2x scale (panel + cursor + text + scrollbar)
--  - tight font packing (because glyphs live inside padded 16x16 frames)
--  - header money rendered inside the dark box to the right of the title
--    and RIGHT-ALIGNED so it grows left as digits increase
--  - vertical scrollbar THUMB that reflects scroll position
--    WITHOUT stretching (constant aspect; slides only)
--
-- IMPORTANT:
--  - Scrollbar track is baked into your panel texture.
--  - We only draw the thumb sprite from /server/assets/ui/scrollbar.png
--=====================================================

local M = {}

--=====================================================
-- Assets
--=====================================================
local PANEL_TEX  = "/server/assets/ui/prog_shop.png"
local CURSOR_TEX = "/server/assets/ui/select_cursor.png"

local FONT_TEX   = "/server/assets/ui/fonts/bn6/bold_white.png"
local FONT_ANIM  = "/server/assets/ui/fonts/bn6/bold_white.animation"

-- Scrollbar thumb (track is baked into panel)
local SCROLL_THUMB_TL = "/server/assets/ui/scrollbar.png"

--=====================================================
-- Scale
--=====================================================
local UI_SCALE = 2.0

--=====================================================
-- Font packing
--=====================================================
-- Atlas is 16x16 frames, but glyph artwork is padded inside each frame.
-- We keep glyph size the same, but advance less than 16px.
local FONT_ADV   = 8     -- tighten/loosen: 7..10
local SPACE_ADV  = 8
local TITLE_ADV  = FONT_ADV

--=====================================================
-- Layout (BASE offsets; scaled at draw-time)
--=====================================================
local PANEL_X, PANEL_Y = 0, 36
local Z_BASE = 5000

-- Title should sit over baked "PROGSHOP"
local TITLE_OX, TITLE_OY = 13, 5

-- Money Y in the dark header box
local MONEY_OY = 5

-- RIGHT edge inside the dark money box (so money anchors right)
-- TUNE THIS ONCE if needed.
local MONEY_BOX_RIGHT_OX = 180

-- List
local LIST_OX,  LIST_OY  = 36, 34
local LIST_DY_BASE       = 16

-- Cursor
local SCURSOR_OX          = 18
local SCURSOR_OY_OFFSET   = 2

-- Scrollbar thumb placement (X only; thumb slides vertically)
local SCROLL_OX = 225
local SCROLL_PAD_Y = 0

-- Thumb art height at 1x (DON'T stretch; used only for positioning/clamping)
-- If your scrollbar.png thumb is not 16px tall, set this correctly.
local THUMB_H_BASE = 16

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
-- Debug
--=====================================================
local function dbg(msg)
  print("[simple_menu] " .. msg)
end

--=====================================================
-- Helpers
--=====================================================
local function alloc(player_id, sprite_id, tex, anim, state)
  local params = { texture_path = tex }
  if anim ~= nil then
    params.anim_path  = anim
    params.anim_state = state or "A"
  end
  Net.player_alloc_sprite(player_id, sprite_id, params)
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

local function font_sprite_id(player_id)
  return "ui_font_" .. player_id
end

local function to_state(ch)
  if ch == "+" then return "PLUS" end
  if ch == "*" then return "STAR" end
  if ch == " " then return "SP" end

  local b = string.byte(ch)
  if b and b >= 97 and b <= 122 then
    return "LOW_" .. string.char(b - 32)
  end

  return ch
end





local function draw_text(player_id, prefix, text, x, y, z, sx, sy, adv, space_adv)
  sx = sx or 1
  sy = sy or 1
  adv = adv or FONT_ADV
  space_adv = space_adv or SPACE_ADV

  local cx = x
  local gi = 0

  for i = 1, #text do
    local ch = text:sub(i,i)
    if ch == " " then
      cx = cx + (space_adv * sx)
    else
      gi = gi + 1
      draw(player_id, font_sprite_id(player_id), {
        id = prefix .. "_" .. gi,
        x = cx, y = y, z = z,
        sx = sx, sy = sy,
        anim_state = to_state(ch),
        a = 255
      })
      cx = cx + (adv * sx)
    end
  end
end

local function erase_text(player_id, prefix, max)
  for i = 1, max do
    erase(player_id, prefix .. "_" .. i)
  end
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
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

-- edge detect: not-held -> held counts as "pressed"
-- virtual_input states: 0 pressed, 1 held, 2 released
local function edge_pressed(st, evmap, name)
  ensure_key_state(st)
  local prev = st.key_state[name]
  if prev == nil then prev = 0 end

  local cur = evmap[name]
  if cur == nil then
    return false
  end

  -- Treat 'pressed' as 'held' for the purpose of tracking "down-ness"
  if cur == 0 then cur = 1 end

  -- Released -> clear
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

-- Measure width in BASE pixels (1x), using the same advances draw_text uses.
local function measure_text_px(text, adv, space_adv)
  adv = adv or FONT_ADV
  space_adv = space_adv or SPACE_ADV

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
-- Render
--=====================================================
local function render(player_id)
  local st = ui_state[player_id]
  if not st or st.closing then return end

  local sx, sy = UI_SCALE, UI_SCALE

  -- title
  local title_x = PANEL_X + TITLE_OX * sx
  local title_y = PANEL_Y + TITLE_OY * sy

  -- money right-anchored inside header box
  local money_y = PANEL_Y + MONEY_OY * sy
  local money_right_x = PANEL_X + MONEY_BOX_RIGHT_OX * sx

  -- list geometry
  local list_x  = PANEL_X + LIST_OX * sx
  local list_y0 = PANEL_Y + LIST_OY * sy
  local list_dy = LIST_DY_BASE * sy
  local list_h  = (st.max_visible * list_dy) + (SCROLL_PAD_Y * sy)

  -- cursor
  local cursor_x  = PANEL_X + SCURSOR_OX * sx
  local cursor_y0 = list_y0 + SCURSOR_OY_OFFSET * sy

  -- scrollbar
  local scroll_x = PANEL_X + SCROLL_OX * sx

  -- panel
  draw(player_id, st.sprite_panel, {
    id = st.obj_panel,
    x = PANEL_X, y = PANEL_Y, z = Z_BASE,
    sx = sx, sy = sy,
    a = 255
  })

  -- title
  erase_text(player_id, st.obj_title, 32)
  draw_text(player_id, st.obj_title, st.title, title_x, title_y, Z_BASE + 2, sx, sy, TITLE_ADV, SPACE_ADV)

  -- money (RIGHT-ALIGNED)
  erase_text(player_id, st.obj_money, 16)
  if st.money and st.money ~= "" then
    local w = measure_text_px(st.money, FONT_ADV, SPACE_ADV) * sx
    local money_x = money_right_x - w
    draw_text(player_id, st.obj_money, st.money, money_x, money_y, Z_BASE + 2, sx, sy, FONT_ADV, SPACE_ADV)
  end

  -- list items
  for i = 1, st.max_visible do
    local idx = st.scroll + i
    local item = st.items[idx]
    local prefix = st.obj_item .. "_" .. i

    erase_text(player_id, prefix, 32)
    if item then
      draw_text(
        player_id,
        prefix,
        item.label,
        list_x,
        list_y0 + (i-1) * list_dy,
        Z_BASE + 2,
        sx, sy,
        FONT_ADV, SPACE_ADV
      )
    end
  end

  -- cursor
  local row = st.selected - st.scroll
  draw(player_id, st.sprite_cursor, {
    id = st.obj_cursor,
    x = cursor_x,
    y = cursor_y0 + (row-1) * list_dy,
    z = Z_BASE + 3,
    sx = sx, sy = sy,
    a = 255
  })

  -- scrollbar thumb (fixed size; slides only)
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
end

--=====================================================
-- Close visuals now, unlock later
--=====================================================
local function erase_ui(player_id, st)
  erase(player_id, st.obj_panel)
  erase(player_id, st.obj_cursor)
  erase(player_id, st.obj_scroll_thumb)

  erase_text(player_id, st.obj_title, 32)
  erase_text(player_id, st.obj_money, 16)
  for i = 1, st.max_visible do
    erase_text(player_id, st.obj_item .. "_" .. i, 32)
  end

  dealloc(player_id, st.sprite_panel)
  dealloc(player_id, st.sprite_cursor)
  dealloc(player_id, st.sprite_font)
  dealloc(player_id, st.sprite_scroll_thumb)
end

local function finalize_close(player_id, st)
  ui_state[player_id] = nil
  pcall(function() Net.unlock_player_input(player_id) end)

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
    return -- already open
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
    Net.provide_asset_for_player(player_id, PANEL_TEX)
    Net.provide_asset_for_player(player_id, CURSOR_TEX)
    Net.provide_asset_for_player(player_id, FONT_TEX)
    Net.provide_asset_for_player(player_id, FONT_ANIM)
    Net.provide_asset_for_player(player_id, SCROLL_THUMB_TL)
  end)

  local now = os.clock()

  local st = {
    title = opts.title or "MENU",
    money = opts.money, -- string like "176m"
    items = items,
    max_visible = opts.max_visible or 4,

    selected = 1,
    scroll = 0,

    next_move_at = 0,
    ready_at = now + OPEN_WARMUP_SEC,

    key_state = {},
    closing = false,
    close_started_at = 0,
    pending_result = nil,

    sprite_panel        = "ui_panel_" .. player_id,
    sprite_cursor       = "ui_cursor_" .. player_id,
    sprite_font         = font_sprite_id(player_id),
    sprite_scroll_thumb = "ui_scroll_thumb_" .. player_id,

    obj_panel        = "ui_panel_obj_" .. player_id,
    obj_cursor       = "ui_cursor_obj_" .. player_id,
    obj_title        = "ui_title_" .. player_id,
    obj_money        = "ui_money_" .. player_id,
    obj_item         = "ui_item_" .. player_id,
    obj_scroll_thumb = "ui_scroll_thumb_obj_" .. player_id,

    on_done = on_done
  }

  ui_state[player_id] = st

  alloc(player_id, st.sprite_panel,  PANEL_TEX)
  alloc(player_id, st.sprite_cursor, CURSOR_TEX)
  alloc(player_id, st.sprite_font,   FONT_TEX, FONT_ANIM, "A")
  alloc(player_id, st.sprite_scroll_thumb, SCROLL_THUMB_TL)

  render(player_id)
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

  -- Warmup window: swallow any carried button presses from dialog.
  if st.ready_at and now < st.ready_at then
    return
  end

  -- If closing: wait for action buttons to be released, then unlock+callback.
  if st.closing then
    local held = any_action_held(evmap)
    if (not held) or (now - st.close_started_at) > CLOSE_TIMEOUT_SEC then
      finalize_close(player_id, st)
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

  local confirm_edge =
      edge_pressed(st, evmap, "Confirm") or
      edge_pressed(st, evmap, "Interact") or
      edge_pressed(st, evmap, "Use Card")

  local back_edge =
      edge_pressed(st, evmap, "Cancel") or
      edge_pressed(st, evmap, "Back") or
      edge_pressed(st, evmap, "Cust Menu") or
      edge_pressed(st, evmap, "Run")

  if can_move and up_edge then
    st.selected = clamp(st.selected - 1, 1, #st.items)
    st.next_move_at = now + MOVE_REPEAT_SEC
  elseif can_move and down_edge then
    st.selected = clamp(st.selected + 1, 1, #st.items)
    st.next_move_at = now + MOVE_REPEAT_SEC
  elseif confirm_edge then
    local idx = st.selected
    st.pending_result = { cancelled = false, index = idx, item = st.items[idx] }
    st.closing = true
    st.close_started_at = now
    erase_ui(player_id, st)
    return
  elseif back_edge then
    st.pending_result = { cancelled = true }
    st.closing = true
    st.close_started_at = now
    erase_ui(player_id, st)
    return
  else
    return
  end

  -- Keep scroll window in sync
  if st.selected <= st.scroll then
    st.scroll = st.selected - 1
  elseif st.selected > st.scroll + st.max_visible then
    st.scroll = st.selected - st.max_visible
  end
  if st.scroll < 0 then st.scroll = 0 end

  render(player_id)
end)

--=====================================================
-- Disconnect cleanup
--=====================================================
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
