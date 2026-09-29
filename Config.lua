local _, ns = ...
-- Const
local MaskShape = ns.MaskShape
local ModelFileId = ns.ModelFileId
local TextureFileId = ns.TextureFileId
-- Util
local CLIENT_IS_CLASSIC = ns.CLIENT_IS_CLASSIC
local ClientIsClassicBefore = ns.ClientIsClassicBefore

-- PORTRAIT APPEARANCE
do
    -- tweaked to match baseline portraits
    function ns.CreateBaselinePortraitLight()
        if CLIENT_IS_CLASSIC then
            return {
                omnidirectional = false,
                -- (x+ is the back of the model, y+ the right-hand side, z+ the bottom)
                point = CreateVector3D(-0.6, 0, -0.6),
                ambientIntensity = 1 / 3,
                ambientColor = CreateColor(1, 1, 1),
                diffuseIntensity = 10 / 6,
                diffuseColor = CreateColor(1, 1, 1),
            }
        else
            return {
                omnidirectional = false,
                -- (x+ is the back of the model, y+ the right-hand side, z+ the bottom)
                point = CreateVector3D(-0.6, 0, -0.6),
                ambientIntensity = 0.45,
                ambientColor = CreateColor(1, 1, 1),
                diffuseIntensity = 1,
                diffuseColor = CreateColor(1, 1, 1),
            }
        end
    end

    -- sampled from baseline portraits
    local function baselinePortraitBackgroundColor()
        if ClientIsClassicBefore(WOW_PROJECT_CATACLYSM_CLASSIC) then
            return CreateColorFromBytes(0, 14, 33, 255)
        elseif CLIENT_IS_CLASSIC then
            return CreateColorFromBytes(13, 47, 74, 255)
        else -- mainline
            return CreateColorFromBytes(4, 12, 31, 255)
        end
    end

    ns.PORTRAIT_BACKGROUND_COLOR = baselinePortraitBackgroundColor()
end

-- MODEL-MASK ALIGNMENT
do
    local function digitalZoomFactor()
        -- untested: wrath and cata; there is no way of verifying this through videos
        if ClientIsClassicBefore(WOW_PROJECT_CATACLYSM_CLASSIC) then
            -- do not ask me why even this apparently differs between classic and
            -- mainline, but with the portrait background color subtly differing and the
            -- model-frame lighting values being different as well, i am not surprised
            return -134.5
        else
            return -130
        end
    end

    ns.MASK_MODEL_CONFIG = {
        -- any model would do that has a sufficiently round hole: this one is available
        -- even on classic clients
        fileId = ModelFileId.TALK_TO_ME_GEARS,
        -- to ensure the mask model occlusion-clips all parts of all possible unit
        -- models, the mask model must be as close to the camera as possible. lowering
        -- the model scale allows a  nearer camera before hitting the near frustum clip
        scale = 0.6,
        -- insets allow zooming in on the model without culling the mask from camera
        -- distance being too low. this zoom factor is experimentally tweaked to
        -- ensure it inscribes the circle of a circular texture mask
        digitalZoomFactor = digitalZoomFactor(),
        -- model has two gears: center one of them
        posX = 0.1118,
        posZ = -0.2837,
        -- 1) at around camera distance 8, model 587744 stops rendering properly.
        -- 2) at around camera distance 30, the model stops covering portrait models
        -- that lean in (eg blood elf female sigh).
        -- the lowest natural ui scale is 65% => 9 / 65% < 14 should be fine
        cameraDistance = 14,
        cameraFacing = math.pi / 2,
        -- ensure the flat parts of the polygonal circle line up with the bound
        -- edges
        cameraRoll = -0.17
    }

    ns.SUPPORTED_MASK_TEXTURE_SHAPES = {
        [TextureFileId.TEMP_PORTRAIT_ALPHA_MASK] =
            MaskShape.CIRCLE,
        [TextureFileId.CIRCLE_MASK] =
            MaskShape.CIRCLE,
        [TextureFileId.UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK] =
            MaskShape.MAINLINE_PLAYER_PORTRAIT,
        [TextureFileId.UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK_2X] =
            MaskShape.MAINLINE_PLAYER_PORTRAIT,
    }
end

-- OFF-SCREEN ANIMATION BLACKLIST
do
    local UD_MALE_ANIMATION_PLAYLIST = {
        -- 5% each observed with small experiment, but boosted here to account for
        -- lack of secondary idle stance (otherwise, character feels stiff)
        [2] = 0.075,
        [3] = 0.075,
    }
    -- zombies have a 1/3 of each variation: just remove the bad one
    local ZOMBIE_ANIMATION_PLAYLIST = { [2] = 1 / 3 }
    local NO_VARIATION_PLAYLIST = {}
    -- the set of known model id:s where an idle variation is awkwardly off-camera,
    -- mapped to a table of whitelisted idle variations with probability of playing
    ns.ANIMATION_OVERRIDES = {
        -- undead male leans away
        [ModelFileId.UNDEAD_MALE] = UD_MALE_ANIMATION_PLAYLIST,
        [ModelFileId.SKELETON_MALE] = UD_MALE_ANIMATION_PLAYLIST,
        [ModelFileId.CRACK_ELF_MALE] = UD_MALE_ANIMATION_PLAYLIST,
        -- undead female crouches (5% of 1 + 5% of 2 -> 10% of 2)
        [ModelFileId.UNDEAD_FEMALE] = { [2] = 0.1 },
        -- carrion birds fly far up
        [ModelFileId.CARRION_BIRD] = NO_VARIATION_PLAYLIST,
        [ModelFileId.CARRION_BIRD_OUTLAND] = NO_VARIATION_PLAYLIST,
        [ModelFileId.VULTURE] = NO_VARIATION_PLAYLIST,
        [ModelFileId.VULTURE_MOUNT] = NO_VARIATION_PLAYLIST,
        -- zombie turns away
        [ModelFileId.ZOMBIE] = ZOMBIE_ANIMATION_PLAYLIST,
        [ModelFileId.ZOMBIE_ARM] = ZOMBIE_ANIMATION_PLAYLIST,
        [ModelFileId.ZOMBIE2] = ZOMBIE_ANIMATION_PLAYLIST,
    }
end
