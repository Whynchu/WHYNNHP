--=====================================================
-- prog_shop.lua
-- Default PROG shop NPC (using Talk.vert_menu + shop skin)
-- Now wired to sell HPMem items with real money checks (ezmemory)
--=====================================================

local Talk    = require("scripts/net-games/npcs/talk")
local ezmemory = require("scripts/ezlibs-scripts/ezmemory")
local Presets  = require("scripts/net-games/npcs/talk_presets")

local PRICE_PER = 50

local ERROR_SFX_PATH = "/server/assets/net-games/sfx/card_error.ogg"

local function play_error_sfx(player_id)
  Net.provide_asset_for_player(player_id, ERROR_SFX_PATH)
  if Net.play_sound_for_player then
    pcall(function() Net.play_sound_for_player(player_id, ERROR_SFX_PATH) end)
  elseif Net.play_sound then
    pcall(function() Net.play_sound(player_id, ERROR_SFX_PATH) end)
  end
end


local function fmt_m(n)
  return tostring(tonumber(n) or 0) .. "$"
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

local function spend_money_persistent(player_id, amount, have_money)
  if ezmemory and type(ezmemory.spend_money_persistent) == "function" then
    return ezmemory.spend_money_persistent(player_id, amount, have_money)
  end
  Net.set_player_money(player_id, (have_money or safe_money(player_id)) - amount)
end

local function ensure_hpmem_item()
  if not Net.create_item then return end
  local ok, exists = pcall(function() return Net.list_items and Net.list_items()["HPMem"] end)
  if ok and exists then return end

  -- Very small "safe create": if it already exists, create_item may error, so pcall.
  pcall(function()
    Net.create_item("HPMem", {
      name = "HPMem",
      description = "Increase max HP.",
      icon_texture = "/server/assets/items/bn6/hpmem.png",
    })
  end)
end

local function apply_plus_max_hp_now(player_id, amount)
  amount = tonumber(amount) or 0
  if amount <= 0 then return end

  local max_hp = Net.get_player_max_health(player_id) or 0
  local hp     = Net.get_player_health(player_id) or max_hp
  local want   = max_hp + amount

  pcall(function()
    Net.set_player_max_health(player_id, want, false)
    Net.set_player_health(player_id, hp + amount)
  end)
end

local function qty_from_choice_id(choice_id)
  -- choice ids are "HPMEM_1" .. "HPMEM_5"
  local n = tostring(choice_id):match("^HPMEM_(%d+)$")
  return tonumber(n) or 0
end

local function build_hpmem_options()
  return {
    { id = "HPMEM_1", text = ("HPMem  %d$"):format(PRICE_PER * 1) },
    { id = "HPMEM_2", text = ("HPMem2 %d$"):format(PRICE_PER * 2) },
    { id = "HPMEM_3", text = ("HPMem3 %d$"):format(PRICE_PER * 3) },
    { id = "HPMEM_4", text = ("HPMem4 %d$"):format(PRICE_PER * 4) },
    { id = "HPMEM_5", text = ("HPMem5 %d$"):format(PRICE_PER * 5) },
    { id = "HPMEM_6", text = ("HPMem6 %d$"):format(PRICE_PER * 6) },
    { id = "HPMEM_7", text = ("HPMem7 %d$"):format(PRICE_PER * 7) },
    { id = "HPMEM_8", text = ("HPMem8 %d$"):format(PRICE_PER * 8) },
    { id = "HPMEM_9", text = ("HPMem9 %d$"):format(PRICE_PER * 9) },
    { id = "HPMEM_10", text = ("HPMem10 %d$"):format(PRICE_PER * 10) },
    { id = "HPMEM_11", text = ("HPMem11 %d$"):format(PRICE_PER * 11) },
    { id = "HPMEM_12", text = ("HPMem12 %d$"):format(PRICE_PER * 12) },
    { id = "HPMEM_13", text = ("HPMem13 %d$"):format(PRICE_PER * 13) },
    { id = "HPMEM_14", text = ("HPMem14 %d$"):format(PRICE_PER * 14) },
    { id = "exit",   text = "Exit" },
  }
end

Talk.npc({
  area_id = "default",
  object  = "ProgShop", -- add this object name in Tiled
  name    = "SHOP PROG",

  -- Default PROG overworld sprite + animation
  sprite_id = "prog_ow",
  animation = "idle_down",

  on_interact = function(player_id, _bot_id, bot_name)
    -- Build a mutable layout table so we can update money live
    local layout = Presets.get_vert_menu_layout("prog_prompt_shop")
    layout.monies_amount_text = fmt_m(safe_money(player_id))

    -- Shop menu skin (menu window visuals only; NPC stays default PROG)
    local assets = {
      menu_bg       = "/server/assets/net-games/ui/prompt_vert_menu_shop_an.png",
      menu_bg_anim  = "/server/assets/net-games/ui/prompt_vert_menu_an.animation",
      menu_bg_frame = "/server/assets/net-games/ui/prompt_vert_menu_shop_an_frame.png",
      highlight     = "/server/assets/net-games/ui/highlight_shop.png",
    }

    Talk.vert_menu(player_id, bot_name, {
      mugshot = "progMug",
      nameplate = "prog",
      -- no frame dye: default look
    }, {
      intro_text = "Just let me know if you see anything you like.",
      options = build_hpmem_options(),

      sfx   = "card_desc",
      flow  = "prog_prompt",

      assets = assets,
      layout = layout,

      -- This is the new hook we add to Talk/TalkVertMenu
      on_select = function(ctx)
        if ctx.choice_id == "exit" then return end

        local qty = qty_from_choice_id(ctx.choice_id)
        if qty <= 0 then
          return { post_text = "Huh? That item is busted.", suppress_post_select = false }
        end

        local cost  = PRICE_PER * qty
        local money = safe_money(ctx.player_id)

          if money < cost then
            play_error_sfx(ctx.player_id)
            return {
              post_text = ("Sorry pal! you don't have enough money! Need %d$." ):format(cost),
              suppress_confirm_sfx = true,
              after_branch = "no",
            }
        end

        ensure_hpmem_item()
        spend_money_persistent(ctx.player_id, cost, money)

        if ezmemory and type(ezmemory.give_player_item) == "function" then
          ezmemory.give_player_item(ctx.player_id, "HPMem", qty)
        end

        apply_plus_max_hp_now(ctx.player_id, 20 * qty)

        -- Refresh the money display in the menu (update the LIVE menu layout, then force redraw)
        local new_money = safe_money(ctx.player_id)

        if ctx.menu and ctx.menu.layout then
          ctx.menu.layout.monies_amount_text = fmt_m(new_money)
          -- force redraw so the amount actually updates immediately
          if ctx.menu.render_menu_contents then
            ctx.menu:render_menu_contents(true)
          end
        end


        return { post_text = ("Bought %dx HPMem! +%d MaxHP."):format(qty, 20 * qty) }
      end,
    })
  end,
})
