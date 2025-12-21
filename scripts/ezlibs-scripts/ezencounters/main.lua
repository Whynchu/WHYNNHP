local ezwarps    = require('scripts/ezlibs-scripts/ezwarps/main')
local ezmemory   = require('scripts/ezlibs-scripts/ezmemory')
local helpers    = require('scripts/ezlibs-scripts/helpers')
local eztriggers = require('scripts/ezlibs-scripts/eztriggers')
local CONFIG     = require('scripts/ezlibs-scripts/ezconfig')
local chip_economy = nil
local ezencounters = {}
local players_in_encounters = {}
local player_last_position = {}
local player_steps_since_encounter = {}
local named_encounters = {}
local provided_encounter_assets = {}
local encounter_finished_callbacks = {}

-- =========================================================
-- Encounter table loading + provisioning
-- Supports:
--   - encounters:       static list (legacy)
--   - all_encounters:   static union list (for provisioning/indexing)
--   - get_encounters(player_id): dynamic list (for runtime selection)
-- =========================================================

local load_encounters_for_areas = function ()
    local areas = Net.list_areas()
    local area_encounter_tables = {}

    for i, area_id in ipairs(areas) do
        local encounter_table_path = CONFIG.ENCOUNTERS_PATH .. area_id

        local ok, tbl = pcall(function ()
            return require(encounter_table_path)
        end)

        local ok, tbl_or_err = pcall(function ()
    return require(encounter_table_path)
end)

if ok and tbl_or_err then
    local tbl = tbl_or_err
    area_encounter_tables[area_id] = tbl

    -- Preload list for provisioning + named encounter registry
    local preload_list = tbl.all_encounters or tbl.encounters or {}

    for _, encounter_info in ipairs(preload_list) do
        if encounter_info.path and not provided_encounter_assets[encounter_info.path] then
            print('[ezencounters] providing mob package ' .. encounter_info.path)
            Net.provide_asset(area_id, encounter_info.path)
            provided_encounter_assets[encounter_info.path] = true
        end

        if encounter_info.name then
            print('[ezencounters] loaded named encounter ' .. encounter_info.name)
            named_encounters[encounter_info.name] = encounter_info
        end
    end

    print('[ezencounters] loaded encounter table for ' .. area_id)
else
    print('[ezencounters] FAILED to load encounter table for ' .. tostring(area_id)
      .. ' path=' .. tostring(encounter_table_path)
      .. ' err=' .. tostring(tbl_or_err))
end

    end

    return area_encounter_tables
end

local area_encounter_tables = load_encounters_for_areas()
do
  local n = 0
  for _ in pairs(area_encounter_tables or {}) do n = n + 1 end
  print("[ezencounters] encounter tables loaded: " .. tostring(n))
end


-- =========================================================
-- Runtime selection helpers (player-aware tables)
-- =========================================================

local function get_encounter_options_for_player(player_id, encounter_table)
    if not encounter_table then
        return {}
    end

    -- Preferred: dynamic per-player encounter list
    if encounter_table.get_encounters then
        local ok, list = pcall(function()
            return encounter_table.get_encounters(player_id)
        end)
        if ok and list and #list > 0 then
            return list
        end
    end

    -- Fallback: legacy static list
    if encounter_table.encounters and #encounter_table.encounters > 0 then
        return encounter_table.encounters
    end

    -- Fallback: static union list (if someone only provided all_encounters)
    if encounter_table.all_encounters and #encounter_table.all_encounters > 0 then
        return encounter_table.all_encounters
    end

    return {}
end

-- =========================================================
-- Step recording
-- =========================================================

local function should_record_step(player_id)
    local player_area = Net.get_player_area(player_id)

    if not player_last_position[player_id] then
        return false
    end
    if Net.is_player_battling(player_id) then
        return false
    end
    if ezwarps.player_is_in_animation(player_id) then
        return false
    end

    local last_pos = player_last_position[player_id]
    local last_tile = Net.get_tile(player_area, last_pos.x, last_pos.y, last_pos.z)
    local tile_tileset_info = Net.get_tileset_for_tile(player_area, last_tile.gid)

    if not tile_tileset_info then
        return false
    end
    if string.find(tile_tileset_info.path, 'conveyer') then
        return false
    end

    return true
end

ezencounters.increment_steps_since_encounter = function (player_id)
    if not should_record_step(player_id) then
        return
    end

    local player_area = Net.get_player_area(player_id)
    local encounter_table = area_encounter_tables[player_area]

    if not player_steps_since_encounter[player_id] then
        player_steps_since_encounter[player_id] = 1
    else
        player_steps_since_encounter[player_id] = player_steps_since_encounter[player_id] + 1
    end

    if encounter_table then
        if player_steps_since_encounter[player_id] >= (encounter_table.minimum_steps_before_encounter or 0) then
            ezencounters.try_random_encounter(player_id, encounter_table)
        end
    end
end

ezencounters.handle_player_move = function(player_id, x, y, z)
    local floor = math.floor
    local rounded_pos_x = floor(x)
    local rounded_pos_y = floor(y)
    local rounded_pos_z = floor(z)

    local last_tile = player_last_position[player_id]
    if last_tile then
        if last_tile.x ~= rounded_pos_x or last_tile.y ~= rounded_pos_y or last_tile.z ~= rounded_pos_z then
            player_last_position[player_id] = {x=rounded_pos_x,y=rounded_pos_y,z=rounded_pos_z}
        end
    else
        player_last_position[player_id] = {x=rounded_pos_x,y=rounded_pos_y,z=rounded_pos_z}
    end

    ezencounters.increment_steps_since_encounter(player_id)
end

-- =========================================================
-- Weighted selection (NOW player-aware)
-- =========================================================

ezencounters.pick_encounter_from_table = function (player_id, encounter_table)
    local options = get_encounter_options_for_player(player_id, encounter_table)
    if not options or #options == 0 then
        return nil
    end

    local total_weight = 0
    for _, option in ipairs(options) do
        total_weight = total_weight + (option.weight or 1)
    end

    local crawler = math.random() * total_weight
    for i, option in ipairs(options) do
        crawler = crawler - (option.weight or 1)
        if crawler <= 0 then
            return options[i]
        end
    end

    return options[1]
end

ezencounters.try_random_encounter = function (player_id, encounter_table)
    local chance = encounter_table.encounter_chance_per_step or 0
    if math.random() <= chance then
        local encounter_info = ezencounters.pick_encounter_from_table(player_id, encounter_table)
        if encounter_info then
            ezencounters.begin_encounter(player_id, encounter_info)
        end
    end
end

-- =========================================================
-- Encounter start
-- =========================================================

ezencounters.begin_encounter_by_name = function(player_id, encounter_name, trigger_object)
    return async(function ()
        local encounter_info = named_encounters[encounter_name]
        if encounter_info then
            await(ezencounters.begin_encounter(player_id, encounter_info, trigger_object))
        else
            print('[ezencounters] no encounter with name ', encounter_name, ' has been added to any encounter tables!')
        end
    end)
end

ezencounters.begin_encounter = function (player_id, encounter_info, trigger_object)
    return async(function ()
        players_in_encounters[player_id] = { encounter_info = encounter_info }
        ezencounters.clear_tiles_since_encounter(player_id)
        local stats = await(Async.initiate_encounter(player_id, encounter_info.path, encounter_info))
        return stats
    end)
end

ezencounters.clear_tiles_since_encounter = function (player_id)
    player_steps_since_encounter[player_id] = nil
end

ezencounters.clear_last_position = function (player_id)
    print('[ezencounters] clearing last position')
    player_last_position[player_id] = nil
    ezencounters.clear_tiles_since_encounter(player_id)
    players_in_encounters[player_id] = nil
end

-- =========================================================
-- Battle results -> call callbacks + chip economy
-- =========================================================

Net:on("battle_results", function(event)
    local player_id = event.player_id
    if players_in_encounters[player_id] then
        local player_encounter = players_in_encounters[player_id]

        -- === Chip Economy Hook (server-authoritative drop resolution) ===
        pcall(function()
            chip_economy.on_encounter_finished({
                player_id = player_id,
                event = event,
                encounter_info = player_encounter.encounter_info,
                area_id = Net.get_player_area(player_id),
            })
        end)

        if chip_economy and chip_economy.on_encounter_finished then
  pcall(function()
    chip_economy.on_encounter_finished({
      player_id = player_id,
      event = event,
      encounter_info = player_encounter.encounter_info,
      area_id = Net.get_player_area(player_id),
    })
  end)
end
        -- ==============================================================

        if encounter_finished_callbacks[player_id] then
            encounter_finished_callbacks[player_id](event)
            encounter_finished_callbacks[player_id] = nil
        end

        if player_encounter.encounter_info.results_callback then
            player_encounter.encounter_info.results_callback(player_id, player_encounter.encounter_info, event)
        end

        players_in_encounters[player_id] = nil
    end
end)

-- =========================================================
-- Radius encounters (unchanged)
-- =========================================================

local function on_radius_encounter_triggered(event)
    return async(function ()
        print('[ezencounters] radius encounter triggered ', event.object.custom_properties)

        local player_area = Net.get_player_area(event.player_id)
        local is_hidden_already = ezmemory.object_is_hidden_from_player(event.player_id, player_area, event.object.id)
        if is_hidden_already then
            return
        end

        local encounter_name = event.object.custom_properties["Name"]
        local stats = false

        if encounter_name then
            stats = await(ezencounters.begin_encounter_by_name(event.player_id, encounter_name, event.object))
        else
            local encounter_info = { path = event.object.custom_properties["Path"] }
            stats = await(ezencounters.begin_encounter(event.player_id, encounter_info, event.object))
        end

        if stats then
            if stats.ran or stats.health == 0 then
                return stats
            end
            local player_area2 = Net.get_player_area(event.player_id)
            if event.object.custom_properties["Once"] == "true" then
                ezmemory.hide_object_from_player(event.player_id, player_area2, event.object.id)
            end
        end

        ezmemory.hide_object_from_player_till_disconnect(event.player_id, player_area, event.object.id)
    end)
end

local areas = Net.list_areas()
for i, area_id in next, areas do
    local objects = Net.list_objects(area_id)
    for j, object_id in next, objects do
        local object = Net.get_object_by_id(area_id, object_id)
        if object.type == "Radius Encounter" then
            local radius = tonumber(object.custom_properties["Radius"] or 1)
            local emitter = eztriggers.add_radius_trigger(area_id, object, radius, radius, 0, 0)
            emitter:on('entered_radius', function(event)
                return on_radius_encounter_triggered(event)
            end)
        end
    end
end

return ezencounters
