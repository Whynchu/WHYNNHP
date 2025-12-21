--=====================================================
-- package_stats.lua
--
-- Purpose:
--   Optional server-trusted overrides for KNOWN packages.
--
-- This table maps:
--   package_id -> buster stat baseline
--
-- Design intent:
--   - This file is NOT a whitelist.
--   - This file is NOT required for scaling to work.
--   - It exists ONLY for:
--       * canonical navis shipped by the server
--       * internal test navis
--       * intentionally "busted" showcase navis
--
-- Any package not listed here:
--   * is still fully supported
--   * is scaled via HP + client telemetry
--   * does NOT break the system
--
-- Use sparingly.
--=====================================================

return {

  --===================================================
  -- Example: intentionally overpowered test / showcase navi
  -- Replace with the REAL package_id if used.
  --===================================================
  ["com.whynchu.dummy"] = {
    attack_level = 5,
    charged_attack_multiplier = 50,
    speed = 5.0,
  },

  --===================================================
  -- Canonical baseline MegaMan
  -- Explicitly defined for clarity and testing.
  --===================================================
  ["com.keristero.navi.MegaMan"] = {
    attack_level = 1,
    charged_attack_multiplier = 10,
    speed = 1.0,
  },

}
