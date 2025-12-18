local ezmemory = require('scripts/ezlibs-scripts/ezmemory')

print("[my_base_stats] LOADED (soft scaling)")

local plugin = {}

-- "Fair" server baseline for comparison (NOT enforced)
local BASE_HP     = 100
local HPMEM_ITEM  = "HPMem"
local HPMEM_BONUS = 20

-- Reward knobs (tune these)
local BASE_MONEY_REWARD     = 500
local BASE_FRAGMENTS_REWARD = 0 -- set >0 if you want fragments too

-- Overcap penalty curve (simple + predictable):
-- ratio 1.0 => 1.00x
-- ratio 2.0 => 0.50x
-- ratio 3.0 => 0.33x
local function reward_multiplier_from_ratio(ratio)
  return 1 / math.max(1, ratio)
end

local function run_async(fn)
  Async.promisify(coroutine.create(fn))
end

local function ensure_hpmem_item_exists()
  if ezmemory.get_or_create_item then
    ezmemory.get_or_create_item(HPMEM_ITEM, "Increases max HP by 20.", true)
  end
end

local function count_hpmem(player_id)
  if ezmemory.count_player_item then
    return ezmemory.count_player_item(player_id, HPMEM_ITEM) or 0
  end
  return 0
end

local function fair_allowed_max_hp(player_id)
  return BASE_HP + (HPMEM_BONUS * count_hpmem(player_id))
end

local function get_overcap_ratio(player_id)
  local allowed = fair_allowed_max_hp(player_id)
  local have = Net.get_player_max_health(player_id) -- whatever the mod/engine gives

  if allowed <= 0 then return 1 end
  if have <= 0 then return 1 end

  local ratio = have / allowed
  if ratio < 1 then ratio = 1 end
  return ratio
end

local function difficulty_tier_from_ratio(ratio)
  -- informational for now (wire into encounters later)
  if ratio < 1.25 then return 0 end
  if ratio < 1.75 then return 1 end
  if ratio < 2.50 then return 2 end
  return 3
end

local function scaled_amount(base_amount, ratio)
  local mult = reward_multiplier_from_ratio(ratio)
  local v = math.floor(base_amount * mult + 0.5)
  if v < 0 then v = 0 end
  return v
end

-- Expose helpers for other scripts (like encounter routing)
function plugin.get_overcap_ratio(player_id)
  return get_overcap_ratio(player_id)
end

function plugin.get_difficulty_tier(player_id)
  return difficulty_tier_from_ratio(get_overcap_ratio(player_id))
end

function plugin.handle_player_join(player_id)
  run_async(function()
    await(ezmemory.wait_until_loaded())
    ensure_hpmem_item_exists()
    -- No HP enforcement. Mods can be wild; scaling handles fairness.
  end)
end

function plugin.handle_player_transfer(player_id)
  run_async(function()
    await(ezmemory.wait_until_loaded())
  end)
end

function plugin.handle_player_avatar_change(player_id, details)
  run_async(function()
    await(ezmemory.wait_until_loaded())
  end)
end

function plugin.handle_battle_results(player_id, stats)
  run_async(function()
    await(ezmemory.wait_until_loaded())

    local ratio = get_overcap_ratio(player_id)
    local money = scaled_amount(BASE_MONEY_REWARD, ratio)
    local frags = scaled_amount(BASE_FRAGMENTS_REWARD, ratio)

    local rewards = {}

    -- Money (type=0)
    if money > 0 then
      ezmemory.spend_player_money(player_id, -money) -- persist
      rewards[#rewards+1] = { type = 0, value = money } -- popup
    end

    -- Fragments+ (type=3)
    if frags > 0 then
      rewards[#rewards+1] = { type = 3, value = frags }
    end

    if #rewards > 0 then
      Net.send_player_battle_rewards(player_id, rewards)
    end

    -- Optional visible feedback for overcap players
    if ratio > 1.01 and Net.ring_player_hud then
      Net.ring_player_hud(player_id)
    end
  end)
end

return plugin
