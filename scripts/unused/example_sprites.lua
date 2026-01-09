local sprites = {
    foo={
        texture_path='/server/assets/particle.png',
    },
    champ={
        texture_path='/server/assets/champion-topper.png',
    },
    card={
        texture_path='/server/assets/card.png',
        anim_path='/server/assets/card.anim',
        anim_state='IDLE_D',
    },
}

local enums = require('scripts/libs/enums')
local ColorMode = enums.ColorMode

local stardust = require("scripts/libs/stardust/core")
local stars =
    stardust()
    :frames(300)
    :start_x(0+100, 480+100)
    :start_y(0, 480)
    :vel_x(-0.1)
    :vel_y(0.1)
    -- If two values are provided, it is a range.
    -- Initial values are selected from a range with no easing.
    :acc_x(-0.001, -0.01)
    :acc_y(0.001, 0.001)
    :fco_x(1)
    :fco_y(1)
    -- Uses a preset easing function by name on the scale property.
    :scl_x(0, 1.5, 'square')
    :scl_y(0, 1.5, 'square')
    -- Uses a custom easing function on the alpha channel.
    :ach(0, 255, function(x) return math.ceil(x*4)/4 end)
    :delay(3)
    :spawn(2)
    :limit(1200)
    :build()

local players = {}
Net:on("player_join", function(event)
    local player_id = event.player_id

    for k, v in pairs(sprites) do
        Net.provide_asset_for_player(player_id, v.texture_path)

        if(v.anim_path) then
            Net.provide_asset_for_player(player_id, v.anim_path)
        end

        Net.player_alloc_sprite(player_id, k, v);
    end

    Net.player_draw_sprite(
        player_id,
        'card',
        {
            id='A',
            x=32,
            y=160,
        }
    )

    Net.player_draw_sprite(
        player_id,
        'champ',
        {
            id='B',
            -- Pin the sprite center-top.
            -- Later, we set the origin to center on the sprite.
            x=240,
            y=0,
            -- With colorize as our color mode,
            -- the sprite's default color property (white)
            -- produced a greyscale result!
            color_mode=ColorMode.COLOR
        }
    )

    Net.toggle_player_hud(player_id)

    players[player_id] = {}
end)

Net:on("player_disconnect", function(event)
    players[event.player_id] = nil
end)

DT = 0
Net:on("tick", function(event)
    DT = DT + event.delta_time
    for player_id, _ in pairs(players) do
        stars:for_each(
            function(index, value, is_alive)
                local data = { sx=0, sy=0 }

                if is_alive then
                    local s = (value.pos.x/480)
                    local theta = 2*(22/7)*s
                    data = {
                        x=value.pos.x,
                        y=value.pos.y,
                        ox=32,
                        oy=32,
                        sx=value.scl.x,
                        sy=value.scl.y,
                        r=255-math.floor((math.sin(theta)+1)*0.5*170),
                        g=255-math.floor((math.cos(theta)+1)*0.5*170),
                        b=255-math.floor(s*170),
                        a=value.ach,
                        color_mode=ColorMode.ADD,
                    }
                end

                data.id = index

                Net.player_draw_sprite(player_id, 'foo', data)
            end
        )

        --[[local z = 100
        if DT % 10 < 5 then
            z = -100
        end--]]

        local states = {
            'IDLE_D',
            'IDLE_DL',
            'IDLE_L',
            'IDLE_UL',
            'IDLE_U',
            'IDLE_UR',
            'IDLE_R',
            'IDLE_DR'
        }

        Net.player_draw_sprite(
            player_id,
            'card',
            {
                id='A',
                --z=z,
                anim_state=states[1+math.floor(DT%8)]
            }
        )

        local scale = 1+math.abs(math.sin(DT))
        Net.player_draw_sprite(
        player_id,
        'champ',
        {
            id='B',
            sx=scale,
            sy=scale,
            ox=94/2,
            oy=0
        }
    )
    end
end)