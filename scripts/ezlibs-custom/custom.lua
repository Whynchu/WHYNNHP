local plugins = {}

plugins[#plugins+1] = require('scripts/ezlibs-custom/my_base_stats')

return {
  handle_player_join = function(player_id)
    for _, p in ipairs(plugins) do
      if p.handle_player_join then p.handle_player_join(player_id) end
    end
  end
}
