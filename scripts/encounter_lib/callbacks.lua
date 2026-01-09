-- server/scripts/encounter_lib/callbacks.lua
local M = {}
local telemetry = require('scripts/whynn_core/loadout_scaling/player_telemetry')

-- returns a closure: function(player_id, encounter_info, stats) ... end
function M.results_callback_loadout_truth(Net, ezmemory, rewardDir)
  return function(player_id, encounter_info, stats)
    stats = stats or {}

    -- (TEMP) dump battle stats
    for k, v in pairs(stats) do
      print(string.format("[battle_stats] %s = %s (%s)", tostring(k), tostring(v), type(v)))
    end

    -- Preserve your emotion behavior exactly
    if stats.emotion == 1 then
      Net.set_player_emotion(player_id, stats.emotion)
    else
      Net.set_player_emotion(player_id, 0)
    end

    -- === HARD RULE: rewards/heals ONLY on a confirmed win ===
    -- Engine reality (from your dump): stats.reason is numeric (1 win, 2 loss)
    -- Some mods might use outcome/result/etc. We support both.
    local outcome = stats.reason
    if outcome == nil then
      outcome = stats.outcome or stats.result or stats.end_reason or stats.reason
    end

    local victory = false
    if type(outcome) == "number" then
      victory = (outcome == 1)
    elseif type(outcome) == "string" then
      local o = string.lower(outcome)
      victory = (o == "win" or o == "victory" or o == "cleared" or o == "clear" or o == "1")
    else
      if stats.victory == true or stats.win == true or stats.won == true or stats.cleared == true then
        victory = true
      end
      if stats.victory == 1 or stats.win == 1 then
        victory = true
      end
    end

    -- Update telemetry from server-observed battle stats (best-effort)
    -- NOTE: your battle dump currently contains no loadout fields; this just keeps freshness alive.
    telemetry.set(player_id, {
      buster_attack = stats.buster_attack or stats.attack_level or stats.atk,
      charged_attack_multiplier = stats.charged_attack_multiplier or stats.charge_multiplier or stats.cmult,
      speed = stats.buster_speed or stats.rapid or stats.rapid_level, -- avoid using stats.speed if it might be movement
      folder_score = stats.folder_score,
      chip_count = stats.chip_count or stats.folder_count or stats.chips,
      folder_hash = stats.folder_hash,
    })

    if not victory then
      print(string.format(
        "[callbacks][%s] battle not won (reason/outcome=%s) -> NO rewards/heals",
        tostring(player_id),
        tostring(outcome)
      ))
      return
    end

    local deps = { Net = Net, ezmemory = ezmemory }
    rewardDir.on_battle_end(player_id, deps, stats, encounter_info)
  end
end

return M
