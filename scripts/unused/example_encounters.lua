local Encounters = require("scripts/libs/encounters")
local enums = require("scripts/libs/enums")
--local ezmemory = require('scripts/ezlibs-scripts/ezmemory')
local BattleItem = enums.BattleItem
local PackageType = enums.PackageType
local AssetType = enums.AssetType

-- Setup the default area's encounters
local encounters_table = { }
encounters_table["default"] = {
  min_travel = 20, -- 10 tiles are free to walk after each encounter
  chance = .05, -- 5% chance for each movement event after the minimum travel to cause an encounter
  preload = true,
  encounters = {
    {
      asset_path = "/server/assets/canodumb.zip",
      weight = 0.1
    }
  }
}

Encounters.setup(encounters_table)

Net:on("player_join", function(event)
  Encounters.track_player(event.player_id)

  -- Ensure the client has the mods for this example.
  -- In serious game servers, don't send mods if they have
  -- not earned it! Otherwise they can spoof progress. 
end)

Net:on("player_disconnect", function(event)
  -- Drop will forget this player entry record
  -- Also useful to stop tracking players for things like cutscenes or
  -- repel items
  Encounters.drop_player(event.player_id)
end)

Net:on("player_move", function(event)
  Encounters.handle_player_move(event.player_id, event.x, event.y, event.z)
end)

Net:on("battle_results", function(event)
  local reward = 500
  ezmemory.spend_player_money(event.player_id, -reward)

  Net.send_player_battle_rewards(event.player_id, {
    {
      type = 0,
      value = reward,
    }
  })
end)
