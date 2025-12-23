--=====================================================
-- prog_shop_ui.lua
--
-- Real custom UI shop using the new Sprite Draw API + virtual_input.
-- Pinned screen-space UI, color, cursor movement, confirm/cancel.
--
-- Requirements (assets you provide):
--   /server/assets/ui/prog_shop.png        (window background)
--   /server/assets/ui/cursor.png           (cursor/selector)
--
-- Text approach (simple, no font):
--   Pre-render the 5 menu rows as images, e.g.:
--     /server/assets/ui/shop_row_1.png  (HPMem x1  50z)
--     /server/assets/ui/shop_row_2.png  (HPMem x2 100z)
--     ...
--     /server/assets/ui/shop_row_5.png  (HPMem x5 250z)
--
-- Money display approach (simple):
--   Pre-render a label like "Zenny:" as image, plus digits 0-9 sprites.
--   OR skip money on UI and just message it. (But you wanted real UI.)
--
-- This starter implements:
--   - window + 5 row sprites + cursor
--   - virtual input: Up/Down/Confirm/Cancel
--   - ezmemory purchase logic (persistent) with immediate max HP bump
--   - clean teardown so input always returns
--=====================================================

local ezmemory  = require("scripts/ezlibs-scripts/ezmemory")
local enums     = require("scripts/libs/enums")
local InputState = enums.InputState

local M = {}

--=====================================================
-- Config
--=====================================================

local PRICE_PER   = 50
local HPMEM_ITEM  = "HPMem"
local HPMEM_BONUS = 20

-- UI layout (screen-space pixels)
local UI = {
  x = 12,  -- top-left of window
  y = 10,
  z = 50,  -- draw order; higher = on top
  row_start_x = 24,
  row_start_y = 22,
  row_gap_y   = 18,

  cursor_x = 16,
  cursor_y = 24,
}

-- Sprite assets
local ASSETS = {
  window_tex = "/server/assets/ui/prog_shop.png",
  cursor_tex = "/server/assets/ui/select_cursor.png",

  -- pre-rendered row textures:
  row_tex = {
    "/server/assets/ui/shop_row_1.png",
    "/server/assets/ui/shop_row_2.png",
    "/server/assets/ui/shop_row_3.png",
    "/server/assets/ui/shop_row_4.png",
    "/server/assets/ui/shop_row_5.png",
  },

  -- OPTIONAL: digit sprites for money display
  -- (If you don’t have these yet, set SHOW_MONEY=false below.)
  zenny_label_tex = "/server/assets/ui/zenny_label.png", -- like "Zenny"
  digit_tex = {
    [0]="/server/assets/ui/digits/0.png",
    [1]="/server/assets/ui/digits/1.png",
    [2]="/server/assets/ui/digits/2.png",
    [3]="/server/assets/ui/digits/3.png",
    [4]="/server/assets/ui/digits/4.png",
    [5]="/server/assets/ui/digits/5.png",
    [6]="/server/assets/ui/digits/6.png",
    [7]="/server/assets/ui/digits/7.png",
    [8]="/server/assets/ui/digits/8.png",
    [9]="/server/assets/ui/digits/9.png",
  }
}

local SHOW_MONEY = true
local MONEY = {
  label_x = 140,
  label_y = 14,
  digits_x = 182, -- start of digits to the right of label
  digits_y = 14,
  digit_gap = 8,
}

--=====================================================
-- State per player
--=====================================================

local state = {} -- state[player_id] = { open=true, sel=1, sprites={...}, input_names={...} }

--=====================================================
-- Helpers
--=====================================================

local function safe_money(player_id)
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
  if delta == 0 then return end

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
end

local function spend_money_persistent(player_id, amount)
  if type(ezmemory.spend_player_money) == "function" then
    return ezmemory.spend_player_money(player_id, amount) == true
  end
  if type(ezmemory.set_player_money) == "function" then
    local cur = safe_money(player_id)
    if cur < amount then return false end
    ezmemory.set_player_money(player_id, cur - amount)
    return true
  end
  return false
end

local function give_hpmem(player_id, qty)
  if type(ezmemory.give_player_item) ~= "function" then return false end
  ezmemory.give_player_item(player_id, HPMEM_ITEM, qty)
  return true
end

--=====================================================
-- Sprite utilities
--=====================================================

local function alloc_sprite(player_id, sprite_id, texture_path, anim_path, anim_state)
  Net.player_alloc_sprite(player_id, sprite_id, {
    texture_path = texture_path,
    anim_path = anim_path,
    anim_state = anim_state
  })
end

local function draw(player_id, sprite_id, obj_id, x, y, z)
  Net.player_draw_sprite(player_id, sprite_id, {
    id = obj_id,
    x = x,
    y = y,
    z = z
  })
end

local function erase(player_id, obj_id)
  pcall(function() Net.player_erase_sprite(player_id, obj_id) end)
end

local function dealloc(player_id, sprite_id)
  pcall(function() Net.player_dealloc_sprite(player_id, sprite_id) end)
end

--=====================================================
-- Money drawing (digits)
--=====================================================

local function draw_money(player_id)
  if not SHOW_MONEY then return end
  if not state[player_id] then return end

  local s = state[player_id]
  local zenny = safe_money(player_id)
  local str = tostring(zenny)

  -- label
  draw(player_id, "shop_money_label", "shop.money.label",
    UI.x + MONEY.label_x, UI.y + MONEY.label_y, UI.z + 3)

  -- digits
  -- clear previous digit objects
  if s.money_digit_objs then
    for _, obj_id in ipairs(s.money_digit_objs) do
      erase(player_id, obj_id)
    end
  end
  s.money_digit_objs = {}

  local dx = UI.x + MONEY.digits_x
  local dy = UI.y + MONEY.digits_y

  for i = 1, #str do
    local ch = str:sub(i,i)
    local d = tonumber(ch)
    if d ~= nil and ASSETS.digit_tex[d] then
      local obj_id = "shop.money.d" .. tostring(i)
      local spr_id = "shop_digit_" .. tostring(d)
      draw(player_id, spr_id, obj_id, dx, dy, UI.z + 3)
      table.insert(s.money_digit_objs, obj_id)
      dx = dx + MONEY.digit_gap
    end
  end
end

--=====================================================
-- Render / update cursor position
--=====================================================

local function update_cursor(player_id)
  local s = state[player_id]
  if not s then return end
  local y = UI.y + UI.cursor_y + (s.sel - 1) * UI.row_gap_y
  draw(player_id, "shop_cursor", "shop.cursor", UI.x + UI.cursor_x, y, UI.z + 5)
end

--=====================================================
-- Open / Close UI
--=====================================================

function M.open(player_id)
  if state[player_id] and state[player_id].open then return end

  -- lock input so virtual_input events start coming
  pcall(function() Net.lock_player_input(player_id) end)

  state[player_id] = {
    open = true,
    sel = 1,
    money_digit_objs = {}
  }

  -- Allocate sprites (window/cursor/rows/money assets)
  alloc_sprite(player_id, "shop_window", ASSETS.window_tex)
  alloc_sprite(player_id, "shop_cursor", ASSETS.cursor_tex)

  for i = 1, 5 do
    alloc_sprite(player_id, "shop_row_" .. i, ASSETS.row_tex[i])
  end

  if SHOW_MONEY then
    alloc_sprite(player_id, "shop_money_label", ASSETS.zenny_label_tex)
    for d = 0, 9 do
      alloc_sprite(player_id, "shop_digit_" .. d, ASSETS.digit_tex[d])
    end
  end

  -- Draw window
  draw(player_id, "shop_window", "shop.window", UI.x, UI.y, UI.z)

  -- Draw rows
  for i = 1, 5 do
    local rx = UI.x + UI.row_start_x
    local ry = UI.y + UI.row_start_y + (i - 1) * UI.row_gap_y
    draw(player_id, "shop_row_" .. i, "shop.row." .. i, rx, ry, UI.z + 2)
  end

  -- Draw cursor + money
  update_cursor(player_id)
  draw_money(player_id)
end

function M.close(player_id)
  local s = state[player_id]
  if not s then
    pcall(function() Net.unlock_player_input(player_id) end)
    return
  end

  -- erase objects
  erase(player_id, "shop.window")
  erase(player_id, "shop.cursor")
  for i = 1, 5 do
    erase(player_id, "shop.row." .. i)
  end

  if s.money_digit_objs then
    for _, obj_id in ipairs(s.money_digit_objs) do
      erase(player_id, obj_id)
    end
  end
  erase(player_id, "shop.money.label")

  -- dealloc sprites
  dealloc(player_id, "shop_window")
  dealloc(player_id, "shop_cursor")
  for i = 1, 5 do
    dealloc(player_id, "shop_row_" .. i)
  end

  if SHOW_MONEY then
    dealloc(player_id, "shop_money_label")
    for d = 0, 9 do
      dealloc(player_id, "shop_digit_" .. d)
    end
  end

  state[player_id] = nil
  pcall(function() Net.unlock_player_input(player_id) end)
end

--=====================================================
-- Purchase selection
--=====================================================

local function try_buy(player_id)
  local s = state[player_id]
  if not s then return end

  local qty = s.sel
  local cost = PRICE_PER * qty

  if safe_money(player_id) < cost then
    Net.message_player(player_id, "Not enough zenny.")
    return
  end

  ensure_hpmem_item()

  if not spend_money_persistent(player_id, cost) then
    Net.message_player(player_id, "Shop error: couldn't spend money.")
    return
  end

  local before_max = tonumber(Net.get_player_max_health(player_id)) or 100
  local before_count = count_hpmem(player_id)

  if not give_hpmem(player_id, qty) then
    Net.message_player(player_id, "Shop error: couldn't give item.")
    return
  end

  -- HUD feedback: if item didn't auto-apply, apply manually
  local mid_max = tonumber(Net.get_player_max_health(player_id)) or before_max
  if mid_max <= before_max then
    apply_plus_max_hp_now(player_id, HPMEM_BONUS * qty)
  end

  local after_count = count_hpmem(player_id)
  local after_max   = tonumber(Net.get_player_max_health(player_id)) or before_max

  Net.message_player(player_id,
    string.format("Bought HPMem x%d! Total=%d MaxHP=%d", qty, after_count, after_max))

  -- update money display
  draw_money(player_id)
end

--=====================================================
-- Input handling
--=====================================================

-- IMPORTANT:
-- We don't know your exact virtual key names yet.
-- This handler supports common names AND prints unknown presses so you can map them.
local function is_pressed(input, name)
  return input and input.name == name and input.state == InputState.PRESSED
end

Net:on("virtual_input", function(event)
  local player_id = event.player_id
  local s = state[player_id]
  if not s or not s.open then return end

  for _, input in ipairs(event.events or {}) do
    -- Common mappings (one of these will match your client)
    local up      = is_pressed(input, "Up")      or is_pressed(input, "MoveUp")    or is_pressed(input, "up")
    local down    = is_pressed(input, "Down")    or is_pressed(input, "MoveDown")  or is_pressed(input, "down")
    local confirm = is_pressed(input, "Confirm") or is_pressed(input, "Interact")  or is_pressed(input, "A") or is_pressed(input, "OK")
    local cancel  = is_pressed(input, "Cancel")  or is_pressed(input, "B")         or is_pressed(input, "Back")

    if up then
      s.sel = s.sel - 1
      if s.sel < 1 then s.sel = 5 end
      update_cursor(player_id)

    elseif down then
      s.sel = s.sel + 1
      if s.sel > 5 then s.sel = 1 end
      update_cursor(player_id)

    elseif confirm then
      try_buy(player_id)

    elseif cancel then
      M.close(player_id)

    else
      -- Debug: learn what names your client is actually sending
      -- Comment this out once you know your key names.
      print(string.format("[prog_shop_ui] virtual_input name=%s state=%s",
        tostring(input.name), tostring(input.state)))
    end
  end
end)

Net:on("player_disconnect", function(event)
  local player_id = event.player_id
  if state[player_id] then
    M.close(player_id)
  end
end)

return M
