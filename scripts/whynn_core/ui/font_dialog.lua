--=====================================================
-- font_dialog.lua
-- Dialogue textbox font renderer (bn_textbox_v2)
-- Uses shared font_core.lua
--=====================================================

local FontCore = require("scripts/whynn_core/ui/font_core")

local function to_state(ch)
  -- Brace token strings (if your dialog parser passes these)
  if ch == "SP" or ch == "{SP}" then return "SP" end
  if ch == "EX" or ch == "{EX}" then return "EX" end
  if ch == "MB" or ch == "{MB}" then return "MB" end

  -- Common semantic tokens
  if ch == "Confirm" then return "SP" end
  if ch == "Cancel"  then return "EX" end

  -- Single-character specials -> SAFE state names
  if ch == "+" then return "PLUS" end
  if ch == "*" then return "STAR" end
  if ch == "!" then return "BANG" end
  if ch == "?" then return "QMARK" end
  if ch == "." then return "DOT" end
  if ch == "=" then return "EQUAL" end
  if ch == "(" then return "LPAREN" end
  if ch == ")" then return "RPAREN" end
  if ch == "/" then return "SLASH" end
  if ch == "\\" then return "BSLASH" end
  if ch == "_" then return "_" end

  local b = string.byte(ch)

  -- digits 0-9 (states are "0".."9")
  if b and b >= 48 and b <= 57 then
    return ch
  end

  -- lowercase a-z (states are LOW_A..LOW_Z)
  if b and b >= 97 and b <= 122 then
    return "LOW_" .. string.char(b - 32)
  end

  -- uppercase A-Z (states are "A".."Z")
  if b and b >= 65 and b <= 90 then
    return ch
  end

  return "EX"
end

return FontCore.new({
  TEX  = "/server/assets/ui/fonts/bn6/bn_textbox_v2.png",
  ANIM = "/server/assets/ui/fonts/bn6/bn_textbox_v2.animation",

  INIT_STATE     = "A",
  FALLBACK_STATE = "EX",

  -- Dialog metrics
  ADV       = 6,
  SPACE_ADV = 3,
  LINE_DY   = 9,

  DEBUG = false,
  CAPTURE_POSITIONS = true,
  DEBUG_PRINT_LIMIT = 200,

  to_state = to_state,
})
