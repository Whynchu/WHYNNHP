Changelog
v0.0.2

Encounter System

Reworked encounter generation to scale dynamically with player max HP (up to 2000).
Enemy rank now scales from 1–7, with safe fallback to the highest available rank if a rank is missing.
Certain enemies (e.g. Swordy) may reach rank 8 where supported.

Randomization

Enemy starting positions are now randomized.
Enemy ranks may vary by ±1 from the target rank, with weighted probability.
Encounter size now varies between 2–5 enemies.

Early-Game Safeguards

At 100 max HP or lower, encounters are always limited to 2 enemies.
Prevents early difficulty spikes, even when rare enemies are rolled.

Swarm Balancing

Encounters with 4–5 enemies apply a downward adjustment to effective rank.

Enemy Pool Updates

Random encounters may now include:

Mettaur
Canodumb
Gunn
Ratty
Swordy

All enemy selections respect their supported rank sets.

Stability
Encounter generation no longer fails when a requested enemy rank does not exist.
Safe rank rounding ensures valid encounters in all cases.

Rewards

Reward scaling continues to account for HP overcap.
Player HP and emotion states persist correctly after battles.