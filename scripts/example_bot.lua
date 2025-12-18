local Direction = require("scripts/libs/direction")
local enums = require("scripts/libs/enums")
local InputState = enums.InputState
local InputEvent = enums.InputEvent

local area_id = "default"

local bot_pos = Net.get_object_by_name(area_id, "Bot Spawn")
local bot_id = Net.create_bot({
  name = "",
  area_id = area_id,
  texture_path = "/server/assets/prog.png",
  animation_path = "/server/assets/prog.animation",
  x = bot_pos.x,
  y = bot_pos.y,
  z = bot_pos.z,
  solid = true
})

local mug_texture_path = "resources/ow/prog/prog_mug.png"
local mug_animation_path = "resources/ow/prog/prog_mug.animation"

local all_player_buttons = {}

Net:on("virtual_input", function(event)
  local player_id = event.player_id
  local player_button = all_player_buttons[player_id]
  if player_button == nil then return end

  local events = event.events

  for _, input in ipairs(events) do
    if input.name == player_button and input.state == InputState.PRESSED then
      Net.message_player(player_id, "I SET YOU FREE!", mug_texture_path, mug_animation_path)
      Net.unlock_player_input(player_id)
      all_player_buttons[player_id] = nil
    end
  end
end)

Net:on("actor_interaction", function(event)
  local player_id = event.player_id
  Net.lock_player_input(player_id)

  local player_pos = Net.get_player_position(player_id)
  Net.set_bot_direction(bot_id, Direction.from_points(bot_pos, player_pos))

  Async.question_player(player_id, "CAN YOU PRESS A BUTTON FOR ME?", mug_texture_path, mug_animation_path)
    .and_then(function(response)
      if response == nil then
        -- player disconnected
        return
      end

      if response == 1 then
        local button = nil
        local idx = math.random(InputEvent.LEN)
        local count = 0
        for _, v in pairs(InputEvent) do
          count = count + 1
          if count == idx then
            button = v
            break
          end
        end

        if button == nil then
          -- Something went wrong.
          Net.unlock_player_input(player_id)
          return
        end

        Net.message_player(player_id, "PRESS THE "..button.." BUTTON!", mug_texture_path, mug_animation_path);
        all_player_buttons[player_id] = button
      else
        Net.message_player(player_id, "OK THAT WAS ALWAYS ALLOWED.", mug_texture_path, mug_animation_path);
        Net.unlock_player_input(player_id)
      end
  end)
end)
