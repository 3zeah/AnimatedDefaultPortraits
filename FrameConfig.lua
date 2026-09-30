---system config for animated portrait frames, including the associated model
---mask, chiefly per-client portrait-appearance data and mask-alignment values

local _, ns = ...
---@module "Require"
local require = ns.require

---@module "Const"
local Const = require(ns, "Const")
---@module "Util"
local Util = require(ns, "Util")

local MaskShape = Const.MaskShape
local ModelFileId = Const.ModelFileId
local TextureFileId = Const.TextureFileId
local CLIENT_IS_CLASSIC = Util.CLIENT_IS_CLASSIC
local ClientIsClassicBefore = Util.ClientIsClassicBefore

local lib = {}

-- 36 comes from target-of-target being 35 in classic, but party and pet frames
-- being 37: the former should be disabled stylistically, imo, but the latter
-- not, and thus this is a decent guide
lib.MIN_PORTRAIT_SIZE_TO_ANIMATE = 36

---if true for a given portrait, this add-on will effectively ignore it
function lib.ShouldNotAnimate(portrait)
    return portrait == MicroButtonPortrait
        or (
            CharacterMicroButton
            and CharacterMicroButton.Portrait
            and portrait == CharacterMicroButton.Portrait
        )
        or (
            PaperDollSidebarTab1
            and portrait == PaperDollSidebarTab1.Icon
        )
        or portrait == TargetFrameToTPortrait
        or TargetFrameToT and portrait == TargetFrameToT.Portrait
        or portrait == FocusFrameToTPortrait
        or (FocusFrameToT and portrait == FocusFrameToT.Portrait)
        or portrait == AchievementFrameComparisonHeaderPortrait
end

do
    local function findFirstNamedParent(f)
        local result = f:GetParent()
        while not result:GetName() do
            result = result:GetParent()
        end
        return result
    end

    -- by using a frame buffer, alpha can be made more accurate (otherwise,
    -- model alpha will blend with background alpha). the downside is that frame
    -- buffering requires render-layer flattening, which makes make it impossible
    -- to sandwich the model frame into other frames by fiddling with draw
    -- layers. for most portrait containers, this does not actually matter, so it
    -- is safe to enable this for any frame that has been vetted to look fine
    -- with this enabled, but it is also only necessary if the portrait is ever
    -- not opaque
    function lib.ShouldRenderToFrameBuffer(portraitTexture)
        return portraitTexture == PlayerPortrait
            or (
                PlayerFrame
                and PlayerFrame.PlayerFrameContainer
                and portraitTexture == PlayerFrame.PlayerFrameContainer.PlayerPortrait
            )
            or portraitTexture == TargetFramePortrait
            or (
                TargetFrame
                and TargetFrame.TargetFrameContainer
                and portraitTexture == TargetFrame.TargetFrameContainer.Portrait
            )
            or portraitTexture == FocusFramePortrait
            or (
                FocusFrame
                and FocusFrame.TargetFrameContainer
                and portraitTexture == FocusFrame.TargetFrameContainer.Portrait
            )
            or findFirstNamedParent(portraitTexture) == PartyFrame
    end
end

-- PORTRAIT APPEARANCE
do
    -- tweaked to match baseline portraits
    function lib.CreateBaselinePortraitLight()
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

    lib.PORTRAIT_BACKGROUND_COLOR = baselinePortraitBackgroundColor()
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

    lib.MASK_MODEL_CONFIG = {
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

    lib.SUPPORTED_MASK_TEXTURE_SHAPES = {
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

ns.FrameConfig = lib
return lib
