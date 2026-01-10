-- scripts/net-games/npcs/menu_options.lua
-- Purpose: Build PromptVertical option tables without loops/math in each NPC file.

local M = {}

local function pad2(n)
  if n < 10 then return "0" .. tostring(n) end
  return tostring(n)
end

-- Build numbered options from a count.
-- Example:
--   MenuOptions.count(40, { prefix="Lime Option ", pad=2, start=1, exit_text="Exit" })
function M.count(count, cfg)
  cfg = cfg or {}
  local start = tonumber(cfg.start or 1) or 1
  local prefix = tostring(cfg.prefix or "Option ")
  local pad = tonumber(cfg.pad or 0) or 0

  local exit_text = tostring(cfg.exit_text or "Exit")
  local exit_id = cfg.exit_id or "exit"

  local t = {}
  for i = 0, (count - 1) do
    local n = start + i
    local label = tostring(n)
    if pad == 2 then label = pad2(n) end
    t[#t + 1] = { id = n, text = prefix .. label }
  end

  t[#t + 1] = { id = exit_id, text = exit_text }
  return t
end

-- Build from a list of strings. IDs become 1..N by default.
-- Example:
--   MenuOptions.list({ "Potion", "Antidote" }, { exit_text="Exit" })
function M.list(items, cfg)
  cfg = cfg or {}
  local exit_text = tostring(cfg.exit_text or "Exit")
  local exit_id = cfg.exit_id or "exit"

  local t = {}
  for i = 1, #items do
    t[#t + 1] = { id = i, text = tostring(items[i]) }
  end

  t[#t + 1] = { id = exit_id, text = exit_text }
  return t
end


-- Build HPMem shop entries (common pattern used by ProgShop2).
-- cfg:
--   max (default 14)
--   price_per (default 125000)
--   id_prefix (default "HPMEM_")
--   label (default "HPMemory")
--   images (table) optional: { [1]=<path>, [2]=<path>, ... } per index
--   exit_text/exit_id optional
function M.hpmem_shop(cfg)
  cfg = cfg or {}
  local max = tonumber(cfg.max or 14) or 14
  local price_per = tonumber(cfg.price_per or 125000) or 125000
  local id_prefix = tostring(cfg.id_prefix or "HPMEM_")
  local label = tostring(cfg.label or "HPMemory")
  local images = cfg.images or {}

  local exit_text = tostring(cfg.exit_text or "Exit")
  local exit_id = cfg.exit_id or "exit"

  local t = {}
  for i = 1, max do
    local opt = {
      id = ("%s%d"):format(id_prefix, i),
      text = ("%s%-2d %d$"):format(label, i, price_per * i),
    }
    if images[i] then
      opt.image = images[i]
    end
    t[#t + 1] = opt
  end

  t[#t + 1] = { id = exit_id, text = exit_text }
  return t
end

return M
