--=====================================================
-- player_power.lua
--
-- Purpose:
--   Compute a composite "power score" P and derive a tier.
--
-- Inputs (authoritative where possible):
--   * max_hp            (Net.get_player_max_health)
--   * hpmem count       (ezmemory.count_player_item, if available)
--   * buster telemetry  (loadout_readers.read_buster)
--   * folder telemetry  (loadout_readers.read_folder)
--
-- Core rules:
--   1) HP defines an absolute floor tier (cannot be faked by loadout swaps).
--   2) Loadout (buster/folder) may influence power, but is trust-weighted by source.
--   3) Loadout influence is gated by HP ("low HP can't overwhelm the curve").
--   4) Final tier = max(power_tier, hp_floor_tier).
--
-- Output:
--   A table containing inputs, ratios, composite P, and tiers.
--=====================================================

local C = require('scripts/whynn_core/loadout_scaling/scaling_config')
local readers = require('scripts/whynn_core/loadout_scaling/loadout_readers')

local M = {}

--=====================================================
-- Small helpers
--=====================================================

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

--=====================================================
-- Tier helpers
--=====================================================

-- Ladder: highest row.hp that is <= max_hp wins.
local function tier_from_hp_ladder(max_hp, ladder, fallback_tier)
  fallback_tier = fallback_tier or 0
  if type(ladder) ~= "table" then return fallback_tier end

  local t = fallback_tier
  for _, row in ipairs(ladder) do
    if type(row) == "table" then
      local hp = row.hp
      local tr = row.tier
      if hp ~= nil and tr ~= nil then
        if max_hp >= hp then
          t = tr
        end
      end
    end
  end

  return t
end

-- Threshold list: first row where value < row.max wins.
local function tier_from_thresholds(value, thresholds, fallback_tier)
  fallback_tier = fallback_tier or 0
  if type(thresholds) ~= "table" then return fallback_tier end

  for _, row in ipairs(thresholds) do
    if type(row) == "table" then
      local mx = row.max
      local tr = row.tier
      if mx ~= nil and tr ~= nil then
        if value < mx then return tr end
      end
    end
  end

  local last = thresholds[#thresholds]
  if type(last) == "table" and last.tier ~= nil then
    return last.tier
  end

  return fallback_tier
end

--=====================================================
-- HP memory helpers
--=====================================================

local function get_hpmem_count(player_id, ezmemory)
  if ezmemory and ezmemory.count_player_item then
    return ezmemory.count_player_item(player_id, "HPMem") or 0
  end
  return 0
end

--=====================================================
-- Trust model
--=====================================================

-- Determines how much client-derived ratios can affect P.
-- NOTE: This does not validate truth; it only bounds impact.
local function source_trust_weight(src)
  src = tostring(src or "")

  -- Fully trusted: server-known
  if src == "net" or src == "package" or src == "server_capture" or src == "ezmemory" then
    return 1.0
  end

  -- Client-derived: keep muted until 2.5 telemetry is proven stable.
  if src == "client_report" then
    return 0.0
  end

  if src == "client_clamped" then
    return 0.0
  end

  return 0.0
end

--=====================================================
-- Ratio models (buster / folder)
--=====================================================

-- Folder is assumed pre-normalized to ~1.0 baseline.
local function compute_folder_ratio(f)
  local folder_score = tonumber(f.folder_score) or 1.0
  local folder_baseline = 1.0

  -- Slight dampening curve
  local ratio = (folder_score / folder_baseline) ^ 0.80

  return {
    folder_score = folder_score,
    folder_baseline = folder_baseline,
    ratio = ratio,
  }
end

-- Buster model:
-- Baseline = BN6 Mega: attack=1, charged_mult=10, speed=1.0
local function compute_buster_ratio(b)
  local attack = tonumber(b.attack_level) or 1
  local cmult  = tonumber(b.charged_attack_multiplier) or 10
  local speed  = tonumber(b.speed) or 1.0

  -- Raw offensive value:
  --  - 55% uncharged attack
  --  - 45% charged component (attack * cmult)
  local raw = 0.55 * attack + 0.45 * (attack * cmult)

  -- Baseline raw: 0.55*1 + 0.45*(1*10) = 5.05
  local raw_baseline = 0.55 * 1 + 0.45 * (1 * 10)

  -- Ratio curve: damp raw, lightly weight speed
  local ratio = (raw / raw_baseline) ^ 0.70 * (speed / 1.0) ^ 0.35

  return {
    attack = attack,
    cmult = cmult,
    speed = speed,
    raw = raw,
    raw_baseline = raw_baseline,
    ratio = ratio,
  }
end

--=====================================================
-- Public API
--=====================================================

function M.compute(player_id, deps)
  local Net = deps and deps.Net
  local ezmemory = deps and deps.ezmemory

  if not Net or type(Net.get_player_max_health) ~= "function" then
    return {
      max_hp = 0,
      hpmem = 0,
      fair_allowed_max_hp = 1,
      hp_ratio = 1.0,
      buster = { attack_level = 1, charged_attack_multiplier = 10, speed = 1.0, source = "stub" },
      folder = { folder_score = 1.0, source = "stub" },
      buster_ratio = 1.0,
      folder_ratio = 1.0,
      hp01 = 0.0,
      loadout_influence = 0.0,
      P = 1.0,
      power_tier = 0,
      hp_floor_tier = 0,
      final_tier = 0,
    }
  end

  -- Authoritative HP
  local max_hp = tonumber(Net.get_player_max_health(player_id)) or 0

  -- Real HPMem count (server-known if ezmemory can count items)
  local hpmem = get_hpmem_count(player_id, ezmemory)

  -- Fair allowed HP (baseline + HPMem)
  local fair_allowed_max_hp = (C.BASE_HP or 100) + (hpmem * (C.HPMEM_BONUS or 20))
  if fair_allowed_max_hp < 1 then fair_allowed_max_hp = 1 end

  local hp_ratio = max_hp / fair_allowed_max_hp

  local USE_LOADOUT = (C.USE_CLIENT_LOADOUT == true)

  -- Read loadout (only if enabled; otherwise stub it)
  local buster, folder
  local bsrc, fsrc

  if USE_LOADOUT then
    buster, bsrc = readers.read_buster(player_id, deps)
    folder, fsrc = readers.read_folder(player_id, deps)
  else
    buster, bsrc = { attack_level = 1, charged_attack_multiplier = 10, speed = 1.0, source = "stub" }, "stub"
    folder, fsrc = { folder_score = 1.0, source = "stub" }, "stub"
  end

  buster.source = buster.source or bsrc or "?"
  folder.source = folder.source or fsrc or "?"

  -- Always compute ratios for debug visibility (even if loadout muted)
  local bcalc = compute_buster_ratio(buster)
  local fcalc = compute_folder_ratio(folder)

  -- Trust-weighted blending:
  -- used_ratio = 1.0 + (computed_ratio - 1.0) * trust
  local b_trust = source_trust_weight(buster.source)
  local f_trust = source_trust_weight(folder.source)

  local buster_ratio = 1.0 + (bcalc.ratio - 1.0) * b_trust
  local folder_ratio = 1.0 + (fcalc.ratio - 1.0) * f_trust

  if not USE_LOADOUT then
    buster_ratio = 1.0
    folder_ratio = 1.0
  end

  -- HP-gated loadout influence:
  -- 100hp -> ~0.25 influence, 1200hp+ -> ~1.0
  local hp01 = clamp((max_hp - 100) / (1200 - 100), 0.0, 1.0)
  local loadout_influence = 0.25 + 0.75 * hp01 -- 0.25..1.0
  if not USE_LOADOUT then
    loadout_influence = 0.0
  end

  -- Composite power:
  local P =
    (hp_ratio ^ (C.POWER_W_HP or 0.20)) *
    (buster_ratio ^ ((C.POWER_W_BUSTER or 0.45) * loadout_influence)) *
    (folder_ratio ^ ((C.POWER_W_FOLDER or 0.35) * loadout_influence))

  -- Tier derivation:
  local power_tier    = tier_from_thresholds(P, C.TIER_P_THRESHOLDS, 0)
  local hp_floor_tier = tier_from_hp_ladder(max_hp, C.HP_FLOOR_BY_MAX_HP, 0)

  -- Final tier is hard-gated by HP floor
  local final_tier = power_tier
  if hp_floor_tier > final_tier then final_tier = hp_floor_tier end

  -- Debug lives at the bottom (house style)
  M._dbg_power(player_id, {
    USE_LOADOUT = USE_LOADOUT,

    max_hp = max_hp,
    hpmem = hpmem,
    fair_allowed_max_hp = fair_allowed_max_hp,
    hp_ratio = hp_ratio,
    hp_floor_tier = hp_floor_tier,

    buster = buster,
    folder = folder,

    bcalc = bcalc,
    fcalc = fcalc,

    b_trust = b_trust,
    f_trust = f_trust,

    buster_ratio = buster_ratio,
    folder_ratio = folder_ratio,

    hp01 = hp01,
    loadout_influence = loadout_influence,

    P = P,
    power_tier = power_tier,
    final_tier = final_tier,
  }, deps)

  return {
    max_hp = max_hp,
    hpmem = hpmem,
    fair_allowed_max_hp = fair_allowed_max_hp,
    hp_ratio = hp_ratio,

    buster = buster,
    folder = folder,

    buster_ratio = buster_ratio,
    folder_ratio = folder_ratio,

    hp01 = hp01,
    loadout_influence = loadout_influence,

    P = P,
    power_tier = power_tier,
    hp_floor_tier = hp_floor_tier,
    final_tier = final_tier,
  }
end

--=====================================================
-- Debug (house style: bottom of file)
--=====================================================

function M._dbg_power(player_id, d, deps)
  -- Decision line (level 1): short + useful
  if C and C.dbg_print then
    C.dbg_print(1, "power", string.format(
      "[%s] tier=%s (hp_floor=%s, power=%s) P=%.3f hp=%s hp_ratio=%.3f",
      tostring(player_id),
      tostring(d.final_tier),
      tostring(d.hp_floor_tier),
      tostring(d.power_tier),
      tonumber(d.P) or 0,
      tostring(d.max_hp),
      tonumber(d.hp_ratio) or 0
    ))
  end

  -- Breakdown spam (level 3 + power_breakdown gate)
  if not (C and C.dbg_enabled and C.dbg_enabled(3)) then return end
  if not (C.DEBUG and C.DEBUG.power_breakdown) then return end

  C.dbg_print(3, "power", string.format(
    "[%s] LOADOUT_MODE: %s",
    tostring(player_id),
    d.USE_LOADOUT and "ENABLED" or "DISABLED"
  ))

  C.dbg_print(3, "power", string.format(
    "[%s] HP: max=%d hpmem=%d fair_allowed=%d hp_ratio=%.3f hp_floor_tier=%d",
    tostring(player_id),
    tonumber(d.max_hp) or -1,
    tonumber(d.hpmem) or -1,
    tonumber(d.fair_allowed_max_hp) or -1,
    tonumber(d.hp_ratio) or -1,
    tonumber(d.hp_floor_tier) or -1
  ))

  C.dbg_print(3, "power", string.format(
    "[%s] BUSTER(%s): atk=%s cmult=%s speed=%.2f raw=%.3f base=%.3f ratio=%.3f (trust=%.2f used=%.3f)",
    tostring(player_id),
    tostring(d.buster.source or "?"),
    tostring(d.bcalc.attack),
    tostring(d.bcalc.cmult),
    tonumber(d.bcalc.speed) or 0,
    tonumber(d.bcalc.raw) or 0,
    tonumber(d.bcalc.raw_baseline) or 0,
    tonumber(d.bcalc.ratio) or 0,
    tonumber(d.b_trust) or 0,
    tonumber(d.buster_ratio) or 0
  ))

  C.dbg_print(3, "power", string.format(
    "[%s] FOLDER(%s): score=%.3f base=%.3f ratio=%.3f (trust=%.2f used=%.3f)",
    tostring(player_id),
    tostring(d.folder.source or "?"),
    tonumber(d.fcalc.folder_score) or 0,
    tonumber(d.fcalc.folder_baseline) or 0,
    tonumber(d.fcalc.ratio) or 0,
    tonumber(d.f_trust) or 0,
    tonumber(d.folder_ratio) or 0
  ))

  C.dbg_print(3, "power", string.format(
    "[%s] INFLUENCE: loadout=%.3f (0.25..1.00)",
    tostring(player_id),
    tonumber(d.loadout_influence) or 0
  ))

  C.dbg_print(3, "power", string.format(
    "[%s] COMPOSITE: P=%.3f power_tier=%d final_tier=%d",
    tostring(player_id),
    tonumber(d.P) or 0,
    tonumber(d.power_tier) or -1,
    tonumber(d.final_tier) or -1
  ))
end

return M
