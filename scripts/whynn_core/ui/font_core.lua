--=====================================================
-- font_core.lua
-- Shared sprite-font renderer for ONB.
-- - One sprite atlas per player (allocated once per font instance)
-- - Draws glyphs via Net.player_draw_sprite with per-glyph anim_state
-- - Optional debug + position capture (like your font_menu)
--=====================================================

local FontCore = {}

function FontCore.new(cfg)
  assert(cfg and cfg.TEX and cfg.ANIM, "FontCore.new(cfg) requires cfg.TEX and cfg.ANIM")
  assert(type(cfg.to_state) == "function", "FontCore.new(cfg) requires cfg.to_state(ch)")

  local M = {}

  -- Assets + metrics
  M.TEX       = cfg.TEX
  M.ANIM      = cfg.ANIM
  M.ADV       = cfg.ADV or 8
  M.SPACE_ADV = cfg.SPACE_ADV or M.ADV
  M.LINE_DY   = cfg.LINE_DY or 0 -- optional, useful for multi-line renderers

  -- Debug toggles (override per wrapper)
  M.DEBUG = cfg.DEBUG or false
  M.CAPTURE_POSITIONS = (cfg.CAPTURE_POSITIONS ~= nil) and cfg.CAPTURE_POSITIONS or true
  M.DEBUG_PRINT_LIMIT = cfg.DEBUG_PRINT_LIMIT or 200

  -- Mapping hook
  M.to_state = cfg.to_state

  -- Internal state (per instance)
  local allocated = {} -- player_id -> true
  local positions = {} -- positions[player_id][prefix] = { {ch,state,x,y,id}, ... }

  local function dprint(msg)
    if not M.DEBUG then return end
    print("[font_core] " .. msg)
  end

  local function ensure_pos_table(player_id)
    if not positions[player_id] then positions[player_id] = {} end
  end

  function M.get_positions(player_id, prefix)
    if not M.CAPTURE_POSITIONS then return nil end
    if not positions[player_id] then return nil end
    return positions[player_id][prefix]
  end

  function M.ensure(player_id, sprite_id)
    if allocated[player_id] then return end

    Net.provide_asset_for_player(player_id, M.TEX)
    Net.provide_asset_for_player(player_id, M.ANIM)

    local ok, err = pcall(function()
      Net.player_alloc_sprite(player_id, sprite_id, {
        texture_path = M.TEX,
        anim_path    = M.ANIM,
        anim_state   = cfg.INIT_STATE or "A",
      })
    end)

    if not ok then
      dprint(("ensure ALLOC FAIL player=%s sprite=%s err=%s")
        :format(tostring(player_id), tostring(sprite_id), tostring(err)))
      return
    end

    allocated[player_id] = true
    dprint(("ensure ok player=%s sprite=%s"):format(tostring(player_id), tostring(sprite_id)))
  end

  function M.dealloc(player_id, sprite_id)
    if not allocated[player_id] then return end
    pcall(function() Net.player_dealloc_sprite(player_id, sprite_id) end)
    allocated[player_id] = nil
    positions[player_id] = nil
  end

  function M.erase(player_id, prefix, max_glyphs)
    if M.CAPTURE_POSITIONS and positions[player_id] then
      positions[player_id][prefix] = nil
    end
    for i = 1, max_glyphs do
      pcall(function() Net.player_erase_sprite(player_id, prefix .. "_" .. i) end)
    end
  end

  -- Draw a single line (caller handles wrapping/newlines if needed)
  function M.draw(player_id, sprite_id, prefix, text, x, y, z, sx, sy, adv, space_adv, tint)
    sx = sx or 1
    sy = sy or 1
    adv = (adv or M.ADV) * sx
    space_adv = (space_adv or M.SPACE_ADV) * sx

    text = tostring(text or "")

    local cx = x
    local gi = 0

    local printed = 0
    local function dlim(msg)
      if not M.DEBUG then return end
      if printed >= (M.DEBUG_PRINT_LIMIT or 200) then return end
      printed = printed + 1
      print("[font_core] " .. msg)
    end

    if M.CAPTURE_POSITIONS then
      ensure_pos_table(player_id)
      positions[player_id][prefix] = {}
    end

    dlim(("DRAW prefix=%s len=%d at (%.1f,%.1f) sx=%.2f sy=%.2f adv=%.2f sp=%.2f")
      :format(tostring(prefix), #text, x, y, sx, sy, adv, space_adv))

    for i = 1, #text do
      local ch = text:sub(i, i)

      if ch == " " then
        dlim(("SP i=%d cx+=%.1f"):format(i, space_adv))
        cx = cx + space_adv
      else
        gi = gi + 1
        local st = M.to_state(ch) or (cfg.FALLBACK_STATE or "A")
        local obj_id = prefix .. "_" .. gi

        local obj = {
          id         = obj_id,
          x          = cx,
          y          = y,
          z          = z,
          sx         = sx,
          sy         = sy,
          anim_state = st,
          a          = 255,
        }

        if tint then
          obj.r, obj.g, obj.b = tint.r, tint.g, tint.b
        end

        dlim(("GLYPH i=%d gi=%d ch='%s' -> state=%s at (%.1f,%.1f) id=%s")
          :format(i, gi, ch, tostring(st), cx, y, obj_id))

        local ok, err = pcall(function()
          Net.player_draw_sprite(player_id, sprite_id, obj)
        end)

        if not ok then
          dprint(("DRAW FAIL id=%s ch='%s' state=%s err=%s")
            :format(obj_id, ch, tostring(st), tostring(err)))
        end

        if M.CAPTURE_POSITIONS then
          positions[player_id][prefix][#positions[player_id][prefix] + 1] = {
            ch = ch, state = st, x = cx, y = y, id = obj_id
          }
        end

        cx = cx + adv
      end
    end

    return gi
  end

  return M
end

return FontCore
