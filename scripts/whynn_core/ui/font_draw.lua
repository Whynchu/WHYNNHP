--=====================================================
-- font_draw.lua
--
-- Draw BN6-style text using bold_white.animation
-- Handles:
--   - normal chars
--   - +  -> PLUS
--   - *  -> STAR
--   - tokens: {SP} {EX} {MB}
--
-- Uses Net.player_alloc_sprite + Net.player_draw_sprite
--=====================================================

local M = {}

local FONT_SPRITE_ID = "font_bold_white"

local FONT_TEXTURE = "/server/assets/ui/fonts/bn6/bold_white.png"
local FONT_ANIM     = "/server/assets/ui/fonts/bn6/bold_white.animation"

local CELL_W = 16

--=====================================================
-- internal helpers
--=====================================================

local function normalize_state(token)
  if token == "+" then return "PLUS" end
  if token == "*" then return "STAR" end
  return token
end

-- Tokenizer:
-- "HP {SP} 50+"
-- ? { "H","P"," ","SP"," ","5","0","PLUS" }
local function tokenize(text)
  local out = {}
  local i = 1

  while i <= #text do
    local ch = text:sub(i,i)

    if ch == "{" then
      local close = text:find("}", i)
      if close then
        local token = text:sub(i+1, close-1)
        table.insert(out, token)
        i = close + 1
      else
        i = i + 1
      end
    else
      table.insert(out, normalize_state(ch))
      i = i + 1
    end
  end

  return out
end

--=====================================================
-- public API
--=====================================================

function M.alloc(player_id)
  Net.player_alloc_sprite(player_id, FONT_SPRITE_ID, {
    texture_path = FONT_TEXTURE,
    anim_path    = FONT_ANIM,
    anim_state   = "A"
  })
end

function M.dealloc(player_id)
  pcall(function()
    Net.player_dealloc_sprite(player_id, FONT_SPRITE_ID)
  end)
end

function M.draw_text(player_id, base_id, x, y, text, z)
  local tokens = tokenize(text)
  local cx = x

  for i = 1, #tokens do
    local t = tokens[i]

    if t == " " then
      cx = cx + CELL_W
    else
      Net.player_draw_sprite(player_id, FONT_SPRITE_ID, {
        id = base_id .. "_" .. i,
        x = cx,
        y = y,
        z = z or 20,
        anim_state = t
      })
      cx = cx + CELL_W
    end
  end
end

function M.erase_text(player_id, base_id, max_chars)
  for i = 1, max_chars do
    pcall(function()
      Net.player_erase_sprite(player_id, base_id .. "_" .. i)
    end)
  end
end

return M
