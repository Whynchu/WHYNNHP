local noop = function () end
local texture = nil
local animation_path = nil
local cannon_sfx = nil

-- cursor.lua
local Cursor = {}

local function spawn_barrel_smoke(canodumb)
  local field = canodumb:get_field()
  local tile = canodumb:get_current_tile()

  local artifact = Battle.Artifact.new()
  artifact:set_facing(canodumb:get_facing())
  artifact:sprite():set_layer(-1)
  artifact:set_texture(texture, true)

  if canodumb:get_facing() == Direction.Left then
    artifact:set_offset(-40, -65)
  else
    artifact:set_offset(40, -65)
  end

  local anim = artifact:get_animation()
  anim:load(animation_path)
  anim:set_state("SMOKE")
  anim:on_complete(function()
    artifact:erase()
  end)

  field:spawn(artifact, tile:x(), tile:y())
end

local function attack_tile(canodumb, attack_spell, tile)
  if not tile then
    attack_spell:erase()
    return
  end

  -- set the cursor up for damage
  attack_spell:set_hit_props(HitProps.new(
    canodumb._attack,
    Hit.Flinch | Hit.Impact | Hit.Flash,
    Element.None,
    canodumb:get_context(),
    Drag.new()
  ))

  tile:attack_entities(attack_spell)
end

local function attack(canodumb, cursor)
  Engine.play_audio(cannon_sfx, AudioPriority.Low)

  spawn_barrel_smoke(canodumb)

  local cursor_anim = cursor.spell:get_animation()
  cursor_anim:set_state("CURSOR_SMOKE")
  cursor_anim:set_playback(Playback.Once)
  cursor_anim:on_complete(function()
    cursor:erase()
  end)

  local canodumb_anim = canodumb:get_animation()
  canodumb_anim:set_state(canodumb._shoot_state)
  canodumb_anim:on_complete(function()
    canodumb_anim:set_state(canodumb._idle_state)
  end)

  -- create a new attack spell to deal damage
  -- we can't deal damage to a target if we've hit them and they haven't moved
  local attack_spell = Battle.Spell.new(canodumb:get_team())

  local tile = canodumb:get_tile()
  local direction = canodumb:get_facing()

  attack_spell.update_func = function()
    tile = tile:get_tile(direction, 1)

    attack_tile(canodumb, attack_spell, tile)
  end

  attack_spell.attack_func = function()
    -- hit something, dont hit anything more
    attack_spell:erase()
  end

  -- attach the spell so attacks can register
  canodumb:get_field():spawn(attack_spell, 0, 0)
end

local function begin_attack(canodumb, cursor)
  -- stop the cursor from scanning for players
  cursor.spell.update_func = noop
  cursor.spell.attack_func = noop

  local cursor_anim = cursor.spell:get_animation()
  cursor_anim:set_state(canodumb._cursor_shoot_state)
  cursor_anim:set_playback(Playback.Once)
  cursor_anim:on_complete(function()
    canodumb._should_attack = true
  end)
end

local function spawn_cursor(cursor, canodumb, tile)
  local spell = Battle.Spell.new(canodumb:get_team())
  spell:set_texture(texture, true)
  spell:sprite():set_layer(-1)
  spell:set_hit_props(HitProps.new(
    0,
    Hit.None,
    Element.None,
    canodumb:get_context(),
    Drag.new()
  ))

  local anim = spell:get_animation()
  anim:load(animation_path)
  anim:set_state(canodumb._cursor_state)
  anim:set_playback(Playback.Once)

  local field = canodumb:get_field()
  field:spawn(spell, tile)

  spell.update_func = function(action, time)
    cursor.remaining_frames = cursor.remaining_frames - 1

    -- test if we need to move
    if cursor.remaining_frames > 0 then
      return
    end

    tile = tile:get_tile(canodumb:get_facing(), 1)

    if tile then
      cursor.remaining_frames = canodumb._frames_per_cursor_movement + 1
      spell:teleport(tile)
    else
      cursor:erase()
    end
  end

  spell.attack_func = function()
    begin_attack(canodumb, cursor)
  end

  spell.can_move_to_func = function(tile)
    return true
  end

  return spell
end

function Cursor:new(canodumb, tile)
  local cursor = {
    canodumb = canodumb,
    spell = nil,
    remaining_frames = canodumb._frames_per_cursor_movement
  }

  setmetatable(cursor, self)
  self.__index = self

  cursor.spell = spawn_cursor(cursor, canodumb, tile)

  return cursor
end

function Cursor:erase()
  self.spell:erase()
  self.canodumb._cursor = nil
end

-- entry.lua

local target_update, idle_update

target_update = function(canodumb, dt)
  if canodumb._cursor then
    local spell = canodumb._cursor.spell

    spell:get_current_tile():attack_entities(spell)

    if canodumb._should_attack then
        canodumb._should_attack = false
        attack(canodumb, canodumb._cursor)
    end
  else
    canodumb.update_func = idle_update
  end
end

idle_update = function(canodumb, dt)
  local target = canodumb:get_target()
  local current_tile = canodumb:get_current_tile()
  local y = current_tile:y()

  if not target then return end -- no target
  if y ~= target:get_current_tile():y() then return end -- not same row

  local cursor_tile = canodumb:get_tile(canodumb:get_facing(), 1)
  canodumb._cursor = Cursor:new(canodumb, cursor_tile)
  canodumb.update_func = target_update
end

local delete_func = function(canodumb)
  if canodumb._cursor then
    canodumb._cursor:erase()
  end
end

function package_init(canodumb)
  if not texture then
    texture = Engine.load_texture(_modpath.."canodumb.png")
    cannon_sfx = Engine.load_audio(_modpath.."cannon.ogg")
    animation_path = _modpath.."canodumb.animation"
  end

  -- private variables
  canodumb._frames_per_cursor_movement = 15
  canodumb._cursor = nil
  canodumb._idle_state = "IDLE_1"
  canodumb._shoot_state = "SHOOT_1"
  canodumb._cursor_state = "CURSOR"
  canodumb._cursor_shoot_state = "CURSOR_SHOOT"
  canodumb._attack = 10
  canodumb._should_attack = false

  -- meta
  canodumb:set_name("Canodumb")
  canodumb:set_height(55)

  local rank = canodumb:get_rank()

  if rank == Rank.V1 then
    canodumb:set_health(60)
  elseif rank == Rank.V2 then
    canodumb._idle_state = "IDLE_2"
    canodumb._shoot_state = "SHOOT_2"
    canodumb._attack = 50
    canodumb:set_health(90)
  elseif rank == Rank.V3 then
    canodumb._idle_state = "IDLE_3"
    canodumb._shoot_state = "SHOOT_3"
    canodumb._attack = 100
    canodumb:set_health(130)
  else
    canodumb._idle_state = "IDLE_SP"
    canodumb._shoot_state = "SHOOT_SP"
    canodumb._attack = 200
    canodumb:set_health(180)
  end

  canodumb:set_texture(texture, true)

  local anim = canodumb:get_animation()
  anim:load(animation_path)
  anim:set_state(canodumb._idle_state)
  anim:set_playback(Playback.Once)

  -- setup defense rules
  canodumb.defense = Battle.DefenseVirusBody.new() -- lua owns this need to keep it alive
  canodumb:add_defense_rule(canodumb.defense)

  -- setup event hanlders
  canodumb.update_func = idle_update
  canodumb.battle_start_func = noop
  canodumb.battle_end_func = noop
  canodumb.on_spawn_func = noop
  canodumb.delete_func = delete_func
end
