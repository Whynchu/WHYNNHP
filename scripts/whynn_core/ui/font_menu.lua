--=====================================================
-- font_menu.lua
-- Menu/title/money/list font renderer (bold_white)
-- Uses shared font_core.lua
--=====================================================

local FontCore = require("scripts/whynn_core/ui/font_core")

local function to_state(ch)
  if ch == "+" then return "PLUS" end
  if ch == "*" then return "STAR" end
  if ch == " " then return "SP" end

  local b = string.byte(ch)
  if b and b >= 97 and b <= 122 then
    return "LOW_" .. string.char(b - 32) -- a-z -> LOW_A..
  end

  return ch -- A-Z, 0-9, punctuation if your anim has it
end

return FontCore.new({
  TEX  = "/server/assets/ui/fonts/bn6/bold_white.png",
  ANIM = "/server/assets/ui/fonts/bn6/bold_white.animation",

  INIT_STATE = "A",
  FALLBACK_STATE = "A",

  ADV = 8,
  SPACE_ADV = 8,

  DEBUG = false,
  CAPTURE_POSITIONS = true,
  DEBUG_PRINT_LIMIT = 200,

  to_state = to_state,
})
