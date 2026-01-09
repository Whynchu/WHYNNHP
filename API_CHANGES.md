# API CHANGES
- `Net.toggle_player_hud(player_id)`
- `Net.set_player_hud_mode(player_id, mode)`
- `Net.send_player_battle_rewards(player_id, rewards={})`
- `Net.ring_player_hud(player_id)`
- `Net.get_player_fragments(player_id)`
- `Net.set_player_fragments(player_id, count)`
- `Net.send_player_email(player_id, mail={})`
- `Net.email_read(event={player_id, email_id})`
- `Net.player_alloc_sprite(player_id, sprite_id, params={})`
- `Net.player_draw_sprite(player_id, sprite_id, obj={})`
- `Net.player_erase_sprite(player_id, obj_id)`
- `Net.player_dealloc_sprite(player_id, sprite_id)`
- `Net.virtual_input(event={player_id, events={name, state}})`
  
## Changelog
### 11/22/25
- `Net.virtual_input(event)` added

### 11/21/25
- `opacity` can now optionally be replaced with `a` for alpha channel.
- `r`, `g`, `b` properties added to sprite draw api.
- `color_mode` property added to sprite draw api.
  
## Breaking 2.1 Beta Changes
- Sprite objects cannot change their anim doc via `anim_path`.
  - If you need to use a new anim doc, it's likely with a new texture too.
  - So just use create and use a new `sprite_id` to draw that `obj_id` instead.

# DOCUMENTATION
## `toggle_player_hud`
This API will toggle the visibility of the HUD visible or invisible.
Track the state on your own if needed. Often times, it's enough just
to hide it for cutscenes and then toggle it visible again after.

## `set_player_hud_mode`
The param `mode` is an enum with key-values `health=0` or `icon=1`.

`health` corresponds to the player health in cyberworld.

`icon` corresponds to the PET in human overworld.

## `send_player_battle_rewards`
The param `rewards` is a lua list, so a table `{}`.

Each `entry` in the list `rewards` describes the battle reward.
- `type`: enum integer for the reward type.
  - `0`: Money
  - `1`: Chip
  - `2`: Health+
  - `3`: Fragments+
- `value`: the integer value used for Money, Health+, Fragments+
- `code`: a string character code for the card granted by the server
- `card_id`: the string package id for the chip

> Note that `code` and `card_id` are only needed if the `type` is `1`.
> Additionally, chips do not need `value`. However if the reward `type`
> is anything else, it does need the `value` field and the `code` with
> `card_id` are not used.

## `ring_player_hud`
There are no other params aside from the required `player_id` field like
most of the player API functions. This will trigger the HUD to animate
a ring if it is visible and play a sound effect even if it's not visible.

## `set_player_fragments`
The param `count` sets the quantity of fragments the player has.
This API is similar to monies.

## `get_player_fragments`
Returns an integer value of how many fragments the player has.
This API is similar to monies.

## `send_player_email`
The param `mail` is a lua object with properties, so a table `{}`.

All but one of the properties are mandatory:
- `id`: (string) The unique ID of this email instance.
- `icon`: (int) An enum which maps to the icon types available in the client.
- `title`: (string) The **short** title of the email.
- `from`: (string) The **short** name of the sender.
- `body`: (string) The email contents.
- `mug_texture_path`: (string) The server asset path of the mugshot atlas.
- `mug_animation_path`: (string) The server asset path of the mugshot anim.
- `read`: (bool) **OPTIONAL** Indicates whether or not the player has read the email.

## Event `email_read`
When a player reads an email, a Net event `Net.email_read` is triggered.
You can use this event to track what emails have been read and send this information
back to your player on join in order to persist game state.

#### Overwriting
... Alternatively, you can send an entirely different email whenever a player
has read the email for the first time. This allows you to create scenarios
where the email has a virus attachment and after reading, begins a battle, and 
upon return the new email data is "cleared". You can also use this as a way
to build naration between the player and the characters - remeniscing on the email
information from earlier. Or even changing the the email contents when a quest is complete!

## `player_alloc_sprite`
Sprites need a unique `sprite_id` to identify its texture and initial animation data, if any.
This allocates a new sprite on the client for some player.

The param `fields` is a lua object with properties, so a table `{}`.

Fields has the following properties:
- `texture_path`: (string) the server asset path of the sprite atlas.
- `anim_path`: (string) **OPTIONAL** the server asset path of the animation doc.
- `anim_state`: (string) **OPTIONAL** the default animation state of this sprite.

## `player_draw_sprite`
To draw a sprite, a sprite instance (object) needs to be declared with that `sprite_id`. 
The draw API will create a sprite object for you if that sprite object doesn't exist already.
This design allows hundreds of sprites to reference the same preloaded assets without
allocating redundant resources.

The param `obj` is a lua object with properties, so a table `{}`.

Objects have the following properties:
- `id`: (string) Required object id for this sprite instance.
- `x`: (int) **OPTIONAL** the x pos on screen.
- `y`: (int) **OPTIONAL** the y pos on screen.
- `z`: (int) **OPTIONAL** the z order for sorting.
- `ox`*: (int) **OPTIONAL** the x origin of the sprite.
- `oy`*: (int) **OPTIONAL** the y origin of the sprite.
- `sx`: (number) **OPTIONAL** the x scale of the sprite.
- `sy`: (number) **OPTIONAL** the y scale of the sprite.
- `ro`: (number) **OPTIONAL** the rotation of the sprite in degrees.
- `opacity`: (int) **OPTIONAL** the opacity of the sprite in range 0-255.
- `a`: _an alternative name for `opacity`._
- `r`: (int) **OPTIONAL** the red channel of the sprite in range 0-255.
- `g`: (int) **OPTIONAL** the green channel of the sprite in range 0-255.
- `b`: (int) **OPTIONAL** the blue channel of the sprite in range 0-255.
- `color_mode`: (int) **OPTIONAL** the enum of the color mode.
- `anim_state`**: (string) **OPTIONAL** the new anim state to apply to this object.

> For `ox` and `oy` fields, if the sprite object uses an animation,
> then the animation will override this property.

> The animation for a sprite will loop.

For all assets, be sure to provide them to your player before making this draw statement.

### Color Modes
The following color modes are available:
- `0`: Multiply (default draw behavior)
- `1`: Additive
- `2`: Colorize

## `player_erase_sprite`
Erases a sprite instance (object) identified by `obj_id` for some player.

## `player_dealloc_sprite`
Erases a sprite from the client identified by its `sprite_id` for some player.

**Deallocating a sprite erases all objects referring to it**.
This is a convenience feature and will also release those `obj_id`s for use.

## Event `virtual_input`
When the player is online and their **input is locked**, the client
will emit virtual key press information for server owners to respond to
in their own custom game states.

The param `event` is a lua object with properties, so a table `{}`.
The event has the following structure:
- `player_id` - the player these virtual inputs correspond to
- `events` - a lua table of the name-state pairs of inputs

### Input Events
This sub `events` lua object has the following structure:
- `name` - the name of the virtual key input
- `state` - an enum of the possible input states

The input states can be 
- `0` - Pressed
- `1` - Held
- `2` - Released

> If there are no input events found for some given `name`, then
> this indicates that no input event has occured. For example, a button
> pressed for more than 1 frame is followed by a button held event.
> When the player releases either `pressed` or `held`, a `release` event is emitted.
> After `release`, there will be no more button states in the `events` table
> for that button.