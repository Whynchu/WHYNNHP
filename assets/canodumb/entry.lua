local package_id = "com.discord.Konstinople#7692.canodumb"
local character_id = "com.discord.Konstinople#7692.enemy.canodumb"

function package_requires_scripts()
  Engine.define_character(character_id, _modpath.."canodumb")
end

function package_init(package)
  package:declare_package_id(package_id)
  package:set_name("Canodumb")
  package:set_description("Canodumb lua port!")
  -- package:set_speed(999)
  -- package:set_attack(999)
  -- package:set_health(9999)
  package:set_preview_texture_path(_modpath.."preview.png")
end

function package_build(mob)
--mob:no_results()

  mob
    :create_spawner(character_id, Rank.V2)
    :spawn_at(6, 1)

  mob
    :create_spawner(character_id, Rank.V1)
    :spawn_at(4, 2)

  mob
    :create_spawner(character_id, Rank.V3)
    :spawn_at(6, 3)
end
