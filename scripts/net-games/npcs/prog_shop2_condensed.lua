--=====================================================
-- prog_shop2_condensed.lua
-- Example: PROG shop NPC (condensed, preset-driven)
--=====================================================

local Talk        = require("scripts/net-games/npcs/talk")
local Presets     = require("scripts/net-games/npcs/talk_presets")
local MenuOptions = require("scripts/net-games/npcs/menu_options")

local PRICE_PER = 125000
local UI = "/server/assets/net-games/ui/"

local function qty_from_choice_id(choice_id)
  local n = tostring(choice_id):match("^HPMEM_(%d+)$")
  return tonumber(n) or 0
end

local function ensure_hpmem_item()
  if not Net.create_item then return end
  local ok, items = pcall(function() return Net.list_items and Net.list_items() end)
  if ok and items and items["HPMem"] then return end

  pcall(function()
    Net.create_item("HPMem", {
      name = "HPMem",
      description = "Increase max HP.",
      icon_texture = "/server/assets/net-games/ui/card_shop_hpmem1.png",
    })
  end)
end

Talk.npc({
  area_id = "default",
  object  = "ProgShop2Condensed", -- Tiled object name
  name    = "SAPPHIRE PROG",

  texture_path   = "/server/assets/ow/prog/prog_ow_sapphire.png",
  animation_path = "/server/assets/ow/prog/prog_ow.animation",

  on_interact = function(player_id, _bot_id, bot_name)
    local layout = Presets.get_vert_menu_layout("prog_prompt_shop")
    layout.monies_amount_text = Talk.fmt_money(Talk.safe_money(player_id))
    layout.frame = Presets.frames.sapphire

    Talk.vert_menu(player_id, bot_name, {
      mug = "prog_sapphire",
      nameplate = "prog",
      frame = "sapphire",
    }, {
      open_question = "Hey!{p_1} Wanna check out my shop?!",
      intro_text    = "Just let me know if you see anything you like.",

      assets = "prog_shop",
      layout = layout,

      sfx  = "card_desc",
      flow = "prog_prompt",

      options = MenuOptions.hpmem_shop({
        max = 14,
        price_per = PRICE_PER,
        images = {
          [1] = UI .. "card_shop_hpmem1.png",
          [2] = UI .. "card_shop_hpmem2.png",
          [3] = UI .. "card_shop_hpmem3.png",
        },
      }),

      on_select = function(ctx)
        if ctx.choice_id == "exit" then return end

        local qty = qty_from_choice_id(ctx.choice_id)
        if qty <= 0 then
          return { post_text = "Huh? That item is busted." }
        end

        local cost  = PRICE_PER * qty
        local money = Talk.safe_money(ctx.player_id)

        if money < cost then
          Talk.play_sfx(ctx.player_id, "card_error")
          return {
            post_text = "Sorry pal,{p_0.5} you don't have enough monies!",
            suppress_confirm_sfx = true,
            after_branch = "no",
          }
        end

        ensure_hpmem_item()
        Talk.spend_money_persistent(ctx.player_id, cost, money)

        -- If ezmemory is installed, this gives the items.
        local ok_ez, ezmemory = pcall(require, "scripts/ezlibs-scripts/ezmemory")
        if ok_ez and ezmemory and type(ezmemory.give_player_item) == "function" then
          for _ = 1, qty do
            ezmemory.give_player_item(ctx.player_id, "HPMem", 1)
          end
        end

        -- Live money refresh
        local new_money = Talk.safe_money(ctx.player_id)
        if ctx.menu and ctx.menu.layout then
          ctx.menu.layout.monies_amount_text = Talk.fmt_money(new_money)
          if ctx.menu.render_menu_contents then
            ctx.menu:render_menu_contents(true)
          end
        end

        return { post_text = ("Bought %dx HPMem!"):format(qty) }
      end,
    })
  end,
})
