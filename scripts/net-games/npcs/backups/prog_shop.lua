--=====================================================
-- prog_shop.lua
-- Default PROG shop NPC:
-- - Default OW sprite + default mug
-- - No frame dye (uses default look)
-- - Uses shop UI skin for the vertical menu window
--=====================================================

local Talk = require("scripts/net-games/npcs/talk")
local ezmemory = require("scripts/ezlibs-scripts/ezmemory")
local presets  = require("scripts/net-games/npcs/talk_presets")

Talk.npc({
  area_id = "default",
  object  = "ProgShop", -- add this object name in Tiled
  name    = "SHOP PROG",

  -- Default PROG overworld sprite + animation
  texture_path   = "/server/assets/ow/prog/prog_ow.png",
  animation_path = "/server/assets/ow/prog/prog_ow.animation",

  -- Default “prog prompt” pack visuals (no frame dye)
  preset   = "prog_prompt",
  mug      = "prog",
  nameplate = "prog",

  on_interact = function(player_id, _bot_id, bot_name)
local function fmt_m(n)
  return tostring(tonumber(n) or 0) .. "$"
end

local function safe_money(pid)
  if ezmemory and type(ezmemory.get_player_money) == "function" then
    local m = ezmemory.get_player_money(pid)
    if type(m) == "number" then return m end
  end
  local m = Net.get_player_money(pid)
  if type(m) ~= "number" then return 0 end
  return m
end

local layout = presets.get_vert_menu_layout("prog_prompt_shop")
layout.monies_amount_text = fmt_m(safe_money(player_id))
    
  Talk.vert_menu(player_id, bot_name, {
      area_id = "default",
      object  = "ProgShop",
      preset  = "prog_prompt",
      mug     = "prog",
      nameplate = "prog",
      -- NOTE: intentionally no `frame = ...`
    }, {
      -- Options spec: count + auto Exit
      options = { count = 99, prefix = "Item ", pad = 2, exit_text = "Exit", exit_id = "exit" },

      -- Slightly different vibe (still PROG, just shop-y)
      texts = {
        open_question = "Yo! Wanna browse what I've got?",
        intro_text    = "No rush. Look around and pretend you're rich.",
        decline_open  = "All good. Come back when your wallet stops crying.",

        confirm_format     = 'Buy "%s"?',
        post_select_format = 'You bought "%s".',

        after_yes    = "Nice pick.{p_1} Want anything else?",
        after_no     = "Fair.{p_1} Wanna check something else?",
        exit_goodbye = "Thanks for stoppin' by!",
      },

      -- Shop menu skin (menu window visuals only; NPC stays default PROG)
      assets = {
        menu_bg       = "/server/assets/net-games/ui/prompt_vert_menu_shop_an.png",
        menu_bg_anim  = "/server/assets/net-games/ui/prompt_vert_menu_an.animation",
        menu_bg_frame = "/server/assets/net-games/ui/prompt_vert_menu_shop_an_frame.png",
        highlight     = "/server/assets/net-games/ui/highlight_shop.png",
      },

      sfx   = "card_desc",
      flow  = "prog_prompt",
      layout = layout,
    })
  end,
})
