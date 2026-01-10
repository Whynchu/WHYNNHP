--=====================================================
-- prog_shop.lua
-- Sapphire PROG shop NPC (Talk.vert_menu + shop skin)
-- Sells HPMem items with real money checks + live money UI updates
--=====================================================

local Talk     = require("scripts/net-games/npcs/talk")
local ezmemory = require("scripts/ezlibs-scripts/ezmemory")
local Presets  = require("scripts/net-games/npcs/talk_presets")

local PRICE_PER = 125000

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

  if Net.get_player_money then
    local m = Net.get_player_money(player_id)
    if type(m) == "number" then return m end
  end

  return 0
end

local function spend_money_persistent(player_id, amount, have_money)
  if ezmemory and type(ezmemory.spend_money_persistent) == "function" then
    return ezmemory.spend_money_persistent(player_id, amount, have_money)
  end

  if Net.set_player_money then
    Net.set_player_money(player_id, (have_money or safe_money(player_id)) - amount)
  end
end

local function ensure_hpmem_item()
  if not Net.create_item then return end

  -- If it exists already, do nothing
  local ok, exists = pcall(function()
    return Net.list_items and Net.list_items()["HPMem"]
  end)
  if ok and exists then return end

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
  local n = tostring(choice_id):match("^HPMEM_(%d+)$")
  return tonumber(n) or 0
end

local function build_hpmem_options()
  local opts = {}
  for i = 1, 14 do
    local opt = {
      id = ("HPMEM_%d"):format(i),
      text = ("HPMemory%-2d %d$"):format(i, PRICE_PER * i),
    }

    -- Only HPMEM_10 gets a custom card image
    if i == 14 then
      opt.image   = "/server/assets/net-games/ui/bewd.png"
      opt.image_w = 40
      opt.image_h = 40
    end

    table.insert(opts, opt)

  end
  table.insert(opts, { id = "exit", text = "Exit" })
  return opts
end

Talk.npc({
  area_id = "default",
  object  = "ProgShop2", -- must match the Tiled object name
  name    = "SAPPHIRE PROG",

  -- Sapphire overworld assets
  texture_path   = "/server/assets/ow/prog/prog_ow_sapphire.png",
  animation_path = "/server/assets/ow/prog/prog_ow.animation",

  on_interact = function(player_id, _bot_id, bot_name)
    -- Build a mutable layout table so we can update money live
    local layout = Presets.get_vert_menu_layout("prog_prompt_shop")
    layout.monies_amount_text = fmt_m(safe_money(player_id))
    layout.frame = Presets.frames.sapphire
    -- Shop menu skin
    local assets = {
      menu_bg       = "/server/assets/net-games/ui/prompt_vert_menu_shop_an.png",
      menu_bg_anim  = "/server/assets/net-games/ui/prompt_vert_menu_an.animation",
      menu_bg_frame = "/server/assets/net-games/ui/prompt_vert_menu_shop_an_frame.png",
      highlight     = "/server/assets/net-games/ui/highlight_shop.png",
    }

    Talk.vert_menu(player_id, bot_name, {
      mug = "prog_sapphire",
      nameplate = "prog",

      -- Sapphire frame dye (tints textbox + nameplate frame overlay)
      -- (If you want a different sapphire, change these RGB values.)
      frame = "sapphire",
    }, {
      -- Add the missing open question + keep your normal intro line
      open_question = "Hey!{p_1} Wanna check out my shop?!",
      intro_text    = "Just let me know if you see anything you like.",

      options = build_hpmem_options(),

      sfx   = "card_desc",
      flow  = "prog_prompt",

      assets = assets,
      layout = layout,

      on_select = function(ctx)
        if ctx.choice_id == "exit" then return end

        local qty = qty_from_choice_id(ctx.choice_id)
        if qty <= 0 then
          return { post_text = "Huh? That item is busted." }
        end

        local cost  = PRICE_PER * qty
        local money = safe_money(ctx.player_id)

        -- Not enough money: play error sfx and veto confirm sfx
        if money < cost then
          play_error_sfx(ctx.player_id)
          return {
            post_text = ("Sorry pal,{p_0.5} you don't have enough monies!"):format(cost, money),
            suppress_confirm_sfx = true,

            -- If your patched talk_vert_menu uses after_branch, this nudges it to the "no" vibe.
            after_branch = "no",
          }
        end

        -- Successful purchase
        ensure_hpmem_item()
        spend_money_persistent(ctx.player_id, cost, money)

        if ezmemory and type(ezmemory.give_player_item) == "function" then
            for i = 1, qty do
              ezmemory.give_player_item(ctx.player_id, "HPMem", 1)
            end

        end

        --apply_plus_max_hp_now(ctx.player_id, 20 * qty)

        -- Refresh money display immediately
        local new_money = safe_money(ctx.player_id)
        if ctx.menu and ctx.menu.layout then
          ctx.menu.layout.monies_amount_text = fmt_m(new_money)
          if ctx.menu.render_menu_contents then
            ctx.menu:render_menu_contents(true)
          end
        end

        return { post_text = ("Bought %dx HPMem! +%d MaxHP."):format(qty, 20 * qty) }
      end,
    })
  end,
})
