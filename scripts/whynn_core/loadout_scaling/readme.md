=====================================================
LOADOUT SCALING SYSTEM
=====================================================

This folder implements a SERVER-SIDE encounter scaling system for
OPEN servers that allow arbitrary custom Navis and client-side assets.

The system intentionally avoids:
- Package whitelisting
- Trusting raw client values
- Reading client asset files
- Maintaining a registry of all valid Navis

Instead, encounters scale based on ACTUAL player power.

This approach is called:
LOADOUT TRUTH SCALING


-----------------------------------------------------
DESIGN GOALS
-----------------------------------------------------

1. HP IS TRUTH
   - HP cannot be faked
   - HP establishes a hard minimum difficulty

2. LOADOUT REFINES DIFFICULTY
   - Buster and folder matter
   - Their influence is trust-weighted and HP-gated

3. OPEN SERVER SAFE
   - Unknown Navis are supported
   - No registry required
   - No assumptions about client packages

4. PREDICTABLE TUNING
   - Difficulty is explicitly controlled
   - No hidden jitter or magic behavior


-----------------------------------------------------
HIGH LEVEL DATA FLOW
-----------------------------------------------------

Client
  sends telemetry (optional, sanitized)
    |
    v
player_telemetry.lua      (short lived, in memory)
    |
    v
loadout_readers.lua       (source priority and sanity)
    |
    v
player_power.lua          (composite power P and tier)
    |
    v
encounter_director.lua    (rank and count plan)
    |
    v
room encounter script
    |
    v
reward_director.lua       (win only rewards and crit heal)


-----------------------------------------------------
CORE MODULES
-----------------------------------------------------

scaling_config.lua

The central tuning dashboard.

Defines:
- HP baseline and HPMem value
- Power model weights
- Tier thresholds
- HP floor tiers
- Rank floor per tier
- Reward economy
- Critical post battle heal rules
- Debug flags

If you want to rebalance the game, start here.


player_telemetry.lua

Short lived cache of client reported loadout data.

Properties:
- Stored in memory only
- Freshness enforced by timestamp
- Never trusted blindly
- Used only if recent and sane

Telemetry includes:
- Buster attack, charge, rapid
- Folder score
- Chip count
- Folder hash (optional)


loadout_truth_store.lua

Persistent server preferred loadout truth.

Stored in ezmemory under:
mem.loadout_truth.buster
mem.loadout_truth.folder

Rules:
- Trusted sources override untrusted ones
- Client data cannot overwrite server known data
- Used as fallback when telemetry is missing

Benefits:
- Survives reconnects
- Survives server restarts
- Prevents flapping between sources


package_stats.lua

Optional server trusted overrides for known packages.

Important:
- This is NOT a whitelist
- This file is NOT required
- Unknown packages are fully supported

Use cases:
- Canonical server navis
- Test navis
- Intentionally busted showcase navis


loadout_readers.lua

Source of truth router.

Resolves loadout data using strict priority rules.

BUSTER PRIORITY
1. Fresh telemetry        client_report or client_clamped
2. Package registry       package
3. Legacy ezmemory keys   ezmemory
4. Stub baseline          stub

FOLDER PRIORITY
1. Fresh telemetry
2. Legacy ezmemory key
3. Stub baseline

Each result is tagged with a source string so downstream
systems can trust weight the data.


player_power.lua

The math core.

Computes:
- HP ratio vs fair baseline
- Trust weighted buster ratio
- Trust weighted folder ratio
- HP gated loadout influence
- Composite power score P
- Power tier
- HP floor tier
- Final tier = max(power_tier, hp_floor_tier)

Guarantees:
- High HP cannot pretend to be weak
- Strong loadouts cannot overpower low HP
- Unknown Navis still scale correctly


encounter_director.lua

The tuning brain.

Produces an encounter plan:
- Desired enemy rank
- Rank jitter range
- Enemy count range
- Rare spike behavior

Also applies:
- HP fairness caps (low HP prevents scary packs)
- High HP nudges for late game
- Optional global difficulty modifier

This module does NOT spawn enemies.
It defines what encounter scripts are allowed to spawn.


reward_director.lua

Win only reward logic.

Handles:
- Money rewards (score plus mob count)
- BugFrag rewards
- Post battle critical HP heal
- Authoritative wallet updates
- Reward UI display
- ezmemory persistence

Rules:
- No rewards on run or escape
- No crit heal on run
- Net wallet is source of truth
- ezmemory stores final values only


-----------------------------------------------------
USAGE IN ENCOUNTER SCRIPTS
-----------------------------------------------------

At encounter start:

local ctx = encounter_director.begin_encounter(player_id, deps, {
  is_wild = true,
  area_id = "default",
})

local plan = ctx.plan
local rank = encounter_director.roll_rank(plan)
local count = math.random(plan.min_count, plan.max_count)


At battle end:

reward_director.on_battle_end(player_id, deps, stats, encounter_info)


-----------------------------------------------------
TRUST MODEL SUMMARY
-----------------------------------------------------

Source           Trust
-----------------------
net              Full
package          Full
ezmemory         Full
client_report    Partial
client_clamped   Very Low
stub             Neutral

Trust affects how much loadout data influences difficulty,
not whether the player is allowed to play.


-----------------------------------------------------
PHILOSOPHY
-----------------------------------------------------

- HP is law
- Loadout is flavor
- Unknown Navis are welcome
- Players who self nerf deserve respect
- If someone brings god gear, give them gods to fight

If HP can be bypassed, the system is broken.
=====================================================
