local function isClassicClient()
   return WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
       or WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
       or WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC
       or WOW_PROJECT_ID == WOW_PROJECT_CATACLYSM_CLASSIC
       or WOW_PROJECT_ID == WOW_PROJECT_MISTS_CLASSIC
end
local IS_CLASSIC_CLIENT = isClassicClient()

-- experimentally evaluated and tweaked to make the models match the portraits
local function createModelLight()
   if IS_CLASSIC_CLIENT then
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
-- to ensure the mask model occlusion-clips all parts of all possible unit
-- models, the mask model must be as close to the camera as possible. lowering
-- the model scale allows a  nearer camera before hitting the near frustum clip
local MODEL_MASK_SCALE = 0.6
local SUPPORTED_MASK_TEXTURES = {
   [130924] = true,  -- interface/characterframe/tempportraitalphamask.blp
   [3528314] = true, -- interface/masks/circlemask.blp
   [4682541] = true, -- interface/hud/uiunitframeplayerportraitmask.blp
   [5321198] = true, -- interface/hud/uiunitframeplayerportraitmask2x.blp
}
local UD_MALE_ANIMATION_PLAYLIST = {
   -- 5% each observed with small experiment, but boosted here to account for
   -- lack of secondary idle stance (character feels stiff)
   [2] = 0.075,
   [3] = 0.075,
}
local ZOMBIE_ANIMATION_PLAYLIST = { [2] = 1 / 3 }
-- the set of known model id:s where an idle variation is awkwardly off-camera,
-- mapped to a table of whitelisted idle variations with probability of playing
local ANIMATION_OVERRIDES = {
   -- character/scourge/male/scourgemale.m2: leans away
   [121768] = UD_MALE_ANIMATION_PLAYLIST,
   -- character/skeleton/male/skeletonmale.m2: ^
   [121942] = UD_MALE_ANIMATION_PLAYLIST,
   -- creature/crackelf/crackelfmale.m2 ^
   [123299] = UD_MALE_ANIMATION_PLAYLIST,
   -- character/scourge/female/scourgefemale.m2: crouches
   [121608] = { [2] = 0.1 }, -- 5% of 1 + 5% of 2 -> 10% of 2 (see ud male)
   -- creature/carrionbird/carrionbird.m2: flies up
   [123137] = {},
   -- creature/carrionbirdoutland/carrionbirdoutland.m2 ^
   [123148] = {},
   -- creature/vulture/vulture.m2 ^
   [1661349] = {},
   -- creature/vulturemount/vulturemount.m2 ^
   [1926505] = {},
   -- creature/zombie/zombie.m2: looks away
   [126570] = ZOMBIE_ANIMATION_PLAYLIST,
   -- creature/zombie/zombiearm.m2 ^
   [126571] = ZOMBIE_ANIMATION_PLAYLIST,
   -- creature/zombie2/zombie2.m2 ^
   [1888300] = ZOMBIE_ANIMATION_PLAYLIST,
}

-- state table of all animated model frames, indexed by each corresponding
-- portrait texture that was replaced by that model
local models = {}
-- blacklist
local portraitsNotToAnimate = {}
-- state set of all registered potentially-blocking model frames, such that they
-- are only hooked once (see function `registerPotentiallyBlockingModelFrame`)
local potentiallyBlockingModelFrames = {}

local PORTRAIT_SHAPE_CIRCLE = 1
local PORTRAIT_SHAPE_PLAYER_FRAME = 2

local function findFirstNamedParent(f)
   local result = f:GetParent()
   while not result:GetName() do
      result = result:GetParent()
   end
   return result
end

local function findSupportedMaskTexture(texture)
   local maskCount = texture:GetNumMaskTextures()
   if maskCount == 0 then
      return nil
   end
   for i = 1, maskCount do
      local mask = texture:GetMaskTexture(i)
      if SUPPORTED_MASK_TEXTURES[mask:GetTexture()] then
         return mask
      end
   end
   return texture:GetMaskTexture(1)
end

-- interface/characterframe/tempportraitalphamask.blp
local CIRCLE_MASK_TEXTURE = 130924
-- sampled from actual blizzard portraits
local PORTRAIT_BACKGROUND_COLOR
if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
    or WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
    or WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC then -- classic classic
   PORTRAIT_BACKGROUND_COLOR = CreateColorFromBytes(0, 14, 33, 255)
elseif IS_CLASSIC_CLIENT then                           -- changed in cata
   PORTRAIT_BACKGROUND_COLOR = CreateColorFromBytes(13, 47, 74, 255)
else                                                    -- retail
   PORTRAIT_BACKGROUND_COLOR = CreateColorFromBytes(4, 12, 31, 255)
end
-- create the solid-color background texture and color overlay of the model
local function createModelTextures(model, portraitTexture, disableMasking)
   local layer, subLayer = model:GetModelDrawLayer()
   -- it APPEARS the model is always drawn above the background at same level,
   -- but if we ever cannot rely on that, note that the classic trade frame will
   -- break: TradeFrameRecipientPortrait is at (OVERLAY, 1), but
   -- TradeFrame.TopBorder is at (OVERLAY,0)
   local bg = model:CreateTexture(nil, layer, nil, subLayer)
   bg:SetColorTexture(
      PORTRAIT_BACKGROUND_COLOR.r,
      PORTRAIT_BACKGROUND_COLOR.g,
      PORTRAIT_BACKGROUND_COLOR.b
   )
   bg:SetAllPoints(portraitTexture)

   if not disableMasking then
      local mask = model:CreateMaskTexture()
      mask:SetAllPoints(portraitTexture)
      mask:SetTexture(
         CIRCLE_MASK_TEXTURE,
         "CLAMPTOBLACKADDITIVE",
         "CLAMPTOBLACKADDITIVE"
      )
      bg:AddMaskTexture(mask)
   end
   -- there may also be a mask texture, even if portrait masking is disabled.
   -- in retail, both masks are typically applied, eg for the target frame
   local externalPortraitMask = findSupportedMaskTexture(portraitTexture)
   if externalPortraitMask then
      local mask = model:CreateMaskTexture()
      mask:SetAllPoints(externalPortraitMask)
      mask:SetTexture(
         externalPortraitMask:GetTexture(),
         "CLAMPTOBLACKADDITIVE",
         "CLAMPTOBLACKADDITIVE"
      )
      bg:AddMaskTexture(mask)
      model.externalPortraitMask = mask
   end

   model.bg = bg
end

-- insets allow zooming in on the model without culling the mask from camera
-- distance being too low. additionally, insets are used to align the model
-- mask with the original portrait-texture mask that it is replacing, since, in
-- the blizzard ui, even portraits that are pre-masked may be cropped extra
local DIGITAL_ZOOM_FACTOR
-- untested: wrath and cata; there is no way of verifying this through videos
if IS_CLASSIC_CLIENT and WOW_PROJECT_ID ~= WOW_PROJECT_MISTS_CLASSIC then
   -- do not ask me why even this apparently differs between classic and
   -- mainline, but with the portrait background color subtly differing and the
   -- model-frame lighting values being different as well, i am not surprised
   DIGITAL_ZOOM_FACTOR = -134.5
else
   DIGITAL_ZOOM_FACTOR = -130
end

-- # NOTO BENE ON ALL THIS RANDOM FUCKING MATH
-- ## MODEL SIZE MANIPULATION
-- symmetrical insets are used to zoom in and out. in particular,
-- `SetViewInsets(x,x,x,x)` will for negative `x` zoom in by some margin.
-- the intuition for how much `x` will zoom is that `SetViewInsets(x,x,x,x)`,
-- given a frame of size `s`, is equivalent in zoom to a model frame of size
-- `s - 2 * x`. that is, negative view insets are effectively adding a margin
-- size to the model frame, in frame space units, but cropping the render to
-- the actual frame size, which remains smaller. a corollary of this is that,
-- because the effective render size of the model frame needs to be
-- proportional to the size of the visible model frame, `s - 2 * x` must be a
-- linear function on `s` => `x` must be a linear function on `s`. here,
-- `x = DIGITAL_ZOOM_FACTOR * s`
-- ## MODEL POSITION MANIPULATION
-- the asymmetrical (margin) insets are merely for shifting the model by
-- coordinate differences in frame space: `SetViewInsets(x,-x,0,0)` will
-- simply shift the model to the right by `x` frame-space units, equivalent
-- to adding `x` to the x of the model frame, wrt to the position of the
-- rasterized model
local function tryToAlignModelMaskWithRegion(mask, region)
   local leftSrc, bottomSrc, sizeSrc, _ = mask:GetRect() -- expect square size
   -- but this is only possible if the positions have been initialized
   if not leftSrc then
      return nil
   end
   local leftDst, bottomDst, widthDst, heightDst = region:GetRect()
   if not leftDst then
      return nil
   end
   -- the model mask must be square, because i do not know of a way to
   -- stretch the model only on one axis: target the minimum destination size
   -- when resizing, since having a portrait be too big is worse than too
   -- small (bleeds outside frames)
   local minSizeDst = min(widthDst, heightDst)
   local sizeInset = (sizeSrc - minSizeDst) / 2
   -- zoom in as if the frame were the size of the destination region, but
   -- leave margin accounting for the size of the actual source region
   local digitalZoomInset = DIGITAL_ZOOM_FACTOR * minSizeDst + sizeInset
   -- a lot of terms here... given that the zoom inset effectively resizes
   -- the mask with respect to the center, the size inset must be subtracted
   -- from the effective margin, lest the size inset effectively be applied
   -- twice. additionally, because the destination region is treated as
   -- square, half the real-to-square size difference must be added to center
   -- the destination square within its potentially larger real region
   local leftMargin = (leftDst - leftSrc) - sizeInset
       + (widthDst - minSizeDst) / 2
   local bottomMargin = (bottomDst - bottomSrc) - sizeInset
       + (heightDst - minSizeDst) / 2
   return
       digitalZoomInset + leftMargin,
       digitalZoomInset - leftMargin,
       digitalZoomInset - bottomMargin,
       digitalZoomInset + bottomMargin
end

-- camera/insets experimentally tweaked to ensure only the corners are masked
local function evalModelMaskInsets(model, mask)
   -- if there is a texture mask, the model mask should be aligned with it
   local alignRegion = model.externalPortraitMask
   if alignRegion then
      local left, right, top, bottom =
          tryToAlignModelMaskWithRegion(mask, alignRegion)
      if left then
         return left, right, top, bottom
      end
   end
   -- fallback is simply to align with the model frame itself
   local frameSize, _ = mask:GetSize() -- expect square size
   local digitalZoomInset = DIGITAL_ZOOM_FACTOR * frameSize
   return digitalZoomInset, digitalZoomInset, digitalZoomInset, digitalZoomInset
end

local function updateModelMaskInsetsInContainer(model, container)
   if not container then
      return
   end
   -- all masks share the same region rect: eval insets only once
   local left, right, top, bottom = evalModelMaskInsets(model, container.model1)
   container.model1:SetViewInsets(left, right, top, bottom)
   container.model2:SetViewInsets(left, right, top, bottom)
end

-- faster and more comfortable than setting the insets for each mask separately
local function updateModelMaskInsets(model)
   updateModelMaskInsetsInContainer(model, model.circleMaskFull)
   updateModelMaskInsetsInContainer(model, model.circleMaskTopLeft)
   updateModelMaskInsetsInContainer(model, model.circleMaskTopRight)
   updateModelMaskInsetsInContainer(model, model.circleMaskBottomLeft)
end

local function updateModelMaskCamera(mask)
   mask:SetModelScale(MODEL_MASK_SCALE / mask:GetEffectiveScale())
   -- at around camera distance 8, model 587744 stops rendering properly
   -- at around camera distance 30, the model stops covering portrait models
   -- that lean in (eg blood elf female sigh)
   -- the lowest natural ui scale is 65% => 9 / 65% < 14 should be fine
   mask:SetCameraPosition(0, 14 * MODEL_MASK_SCALE, 0)
end

-- any model would do that has a sufficiently round hole: this one is available
-- even on classic clients
local CIRCLE_MASK_MODEL = 587744 -- Interface/Buttons/TalkToMe_Gears.M2
local function createCircularModelMaskModel(container, model)
   -- this is a crazy idea... it is not possible to apply texture masks to
   -- models, but if a model BG is rendered below a model FG, but model BG is
   -- above model FG in 3D space, then model BG will obscure model FG,
   -- effectively culling part of the foreground model without rendering
   -- anything above it. here, we leverage this by putting a zoomed-in circular
   -- gear below the portait model to cull its corners, and thus fit the
   -- portrait neatly inside the circular unit frame
   --
   -- this hack is subject to lose to random blizz updates. the previous
   -- solution is robust: modify the unit frame texture asset to be thicker
   -- (from version 1.0.0)
   local mask = CreateFrame("Model", nil, container)
   mask:SetFrameStrata("BACKGROUND") -- lowest: below any portraits
   mask:SetFixedFrameStrata(true)
   mask:SetFrameLevel(0)
   mask:SetFixedFrameLevel(true)
   mask:SetAllPoints(model)
   mask:SetModel(CIRCLE_MASK_MODEL)
   mask:SetPaused(true)
   mask:MakeCurrentCameraCustom()
   mask:SetCameraFacing(math.pi / 2)
   mask:SetPosition(0.1118, 0, -0.2837) -- center one of the gears
   updateModelMaskCamera(mask)
   mask:SetScript("OnSizeChanged", updateModelMaskCamera)
   -- culling behavior is optimized away if mask model is actually hidden:
   -- make it pseudo-invisible
   mask:SetIgnoreParentAlpha(true)
   mask:SetAlpha(0.0001)      -- anything lower seems to get rounded to 0 = hide
   mask:SetModelAlpha(0.0001) -- compounds with frame alpha
   return mask
end

local function createCircularModelMask(container, model, roll)
   local mask1 = createCircularModelMaskModel(container, model)
   local mask2 = createCircularModelMaskModel(container, model)
   local left, right, top, bottom = evalModelMaskInsets(model, mask1)
   -- if `left`, then `right`, `top` and `bottom`
   ---@diagnostic disable-next-line: param-type-mismatch
   mask1:SetViewInsets(left, right, top, bottom)
   ---@diagnostic disable-next-line: param-type-mismatch
   mask2:SetViewInsets(left, right, top, bottom)
   local baseRoll = (roll or 0) - 0.17
   mask1:SetCameraRoll(baseRoll)
   mask2:SetCameraRoll(baseRoll + math.pi / 12)
   return mask1, mask2
end

local function createCircularModelMaskContainer(model, roll)
   local container = CreateFrame("Frame", nil, model)
   container:SetUsingParentLevel(true)
   -- use container to crop model mask without having to re-evaluate alignment
   -- (the mask model frame itself is still aligned with full portrait model)
   container:SetClipsChildren(true)
   local mask1, mask2 = createCircularModelMask(container, model, roll)
   container.model1 = mask1
   container.model2 = mask2
   return container
end

local function setModelAlpha(model, a)
   -- if the model happens to be frame buffered, setting one overall alpha works
   -- (otherwise the model and the background will blend: see `else` case)
   if model:IsFrameBuffer() then
      model:SetAlpha(a)
      model:SetModelAlpha(1)
   else
      -- normally translucent models like ghost wolf have 1 alpha in portraits,
      -- and thus we want "model alpha" to be equal to the new overall "alpha",
      -- but additionally, because the alpha of the background texture is
      -- combined with the model alpha, each alpha component is set lower
      local alphaComponent = 1 - sqrt(1 - a)
      model.bg:SetAlpha(alphaComponent)
      model:SetModelAlpha(alphaComponent)
   end
end

local function setModelVertexColor(model, r, g, b, a)
   local light = model.light
   light.ambientColor = CreateColor(r, g, b)
   light.diffuseColor = CreateColor(r, g, b)
   model:SetLight(true, light)
   model.bg:SetVertexColor(r, g, b)
   if not a then
      return
   end
   setModelAlpha(model, a)
end

-- post-hook the portrait coloring to also color the model
local function maintainModelColorOverlay(portraitTexture, model)
   hooksecurefunc(portraitTexture, "SetVertexColor", function(_, ...)
      setModelVertexColor(model, ...)
   end)
   hooksecurefunc(portraitTexture, "SetAlpha", function(_, ...)
      setModelAlpha(model, ...)
   end)
end

local function lowerDrawLayer(level)
   if level == "HIGHLIGHT" then
      return "OVERLAY"
   elseif level == "OVERLAY" then
      return "ARTWORK"
   elseif level == "ARTWORK" then
      return "BORDER"
   elseif level == "BORDER" then
      return "BACKGROUND"
   else
      return "BACKGROUND"
   end
end

-- call whenever an independent variable is updated, eg `state.model.unit`
local function refreshWhetherAnimated(portraitTexture, model)
   local textureIsPortrait = portraitTexture:GetTexture() == "RTPortrait1"
   local shouldAnimate = textureIsPortrait
       and not model.blocked
       and model.unit
       -- units not "visible" to the client cannot have their model loaded
       and UnitIsVisible(model.unit)
   if shouldAnimate then
      portraitTexture:Hide()
      model:Show()
      return true
   else
      if not textureIsPortrait then
         model.unit = nil
      end
      portraitTexture:Show()
      model:Hide()
      return false
   end
end

local FRAME_STRATAS = {
   "WORLD",
   "BACKGROUND",
   "LOW",
   "MEDIUM",
   "HIGH",
   "DIALOG",
   "FULLSCREEN",
   "FULLSCREEN_DIALOG",
   "TOOLTIP",
}
local function evalFrameStrataGreaterThanOrdering()
   local result = {}
   for i, strata in ipairs(FRAME_STRATAS) do
      local result_i = {}
      for j = 1, i - 1 do
         result_i[FRAME_STRATAS[j]] = true
      end
      result[strata] = result_i
   end
   return result
end
local FRAME_STRATA_GREATER_THAN_ORDERING = evalFrameStrataGreaterThanOrdering()

local function getDistanceSquared(xA, yA, xB, yB)
   return abs(xA - xB) ^ 2 + abs(yA - yB) ^ 2
end

-- that is, also considering model masking. model-mask models will not interfere
-- with each other, but will interfere with visible models, eg portrait models.
-- thus, this function returns true exactly when some visible section of either
-- model intersects with the bounds of the other model frame
local function modelsVisiblyIntersect(modelA, modelB)
   local leftA, bottomA, widthA, heightA = modelA:GetScaledRect()
   -- no reported size => region is not properly loaded => region can be ignored
   if not heightA then
      return false
   end
   local leftB, bottomB, widthB, heightB = modelB:GetScaledRect()
   if not heightB then
      return false
   end
   local rightA = leftA + widthA
   local topA = bottomA + heightA
   local rightB = leftB + widthB
   local topB = bottomB + heightB
   local boundsIntersect = leftA <= rightB and leftB <= rightA
       and bottomA <= topB and bottomB <= topA
   -- optimization
   if not boundsIntersect then
      return false
   end
   local shapeA = modelA.animatedDefaultPortraitsMaskShape
   local shapeB = modelB.animatedDefaultPortraitsMaskShape
   -- if no shape, the model is rectangular: intersect because bounds intersect
   if not shapeA or not shapeB then
      return true
   end
   local centerXA = leftA + widthA / 2
   local centerYA = bottomA + heightA / 2
   local centerXB = leftB + widthB / 2
   local centerYB = bottomB + heightB / 2
   -- at least some corners are rounded: first, assume both models are circles
   -- and check whether the circles intersect
   local distanceSquared =
       getDistanceSquared(centerXA, centerYA, centerXB, centerYB)
   local radiusA = max(widthA, heightA) / 2
   local radiusB = max(widthB, heightB) / 2
   -- 99% is just to provide some visual margin
   if distanceSquared < (0.99 * (radiusA + radiusB)) ^ 2 then
      return true
   end
   -- finally, since the bounds intersect, but the regions are not close enough
   -- to circle-intersect, only one corner of each region are intersecting:
   -- check that both corners are masked and that neither are in the circle of
   -- the other
   local bIsToBottomRight = centerXA < centerXB and centerYB < centerYA
   local bIsToTopLeft = centerXB < centerXA and centerYA < centerYB
   -- `PORTRAIT_SHAPE_PLAYER_FRAME` is the only non-circle shape: it has an
   -- un-masked lower-right corner
   if (shapeA == PORTRAIT_SHAPE_PLAYER_FRAME and bIsToBottomRight)
       or (shapeB == PORTRAIT_SHAPE_PLAYER_FRAME and bIsToTopLeft) then
      return true
   end
   local offendingXA, offendingYA
   local offendingXB, offendingYB
   if bIsToBottomRight then
      offendingXA, offendingYA = rightA, bottomA
      offendingXB, offendingYB = leftB, topB
   elseif bIsToTopLeft then
      offendingXA, offendingYA = leftA, topA
      offendingXB, offendingYB = rightB, bottomB
   elseif centerXA < centerXB and centerYA < centerYB then
      -- B is to top right
      offendingXA, offendingYA = rightA, topA
      offendingXB, offendingYB = leftB, bottomB
   else
      -- B is to bottom left
      offendingXA, offendingYA = leftA, bottomA
      offendingXB, offendingYB = rightB, topB
   end
   -- are the intersecting corners inside the circle shape?
   local cornerDistanceSquaredA =
       getDistanceSquared(offendingXA, offendingYA, centerXB, centerYB)
   if cornerDistanceSquaredA < (0.99 * radiusB) ^ 2 then
      return true
   end
   local cornerDistanceSquaredB =
       getDistanceSquared(offendingXB, offendingYB, centerXA, centerYA)
   return cornerDistanceSquaredB < (0.99 * radiusA) ^ 2
end

-- that is, considering scale
local function getEffectiveArea(frame)
   local _, _, w, h = frame:GetScaledRect()
   return (w or 0) * (h or 0)
end

local function leftFrameShouldBlockRight(frameLhs, frameRhs)
   -- higher strata wins
   local strataLhs = frameLhs:GetFrameStrata()
   local strataRhs = frameRhs:GetFrameStrata()
   if strataLhs ~= strataRhs then
      return FRAME_STRATA_GREATER_THAN_ORDERING[strataLhs][strataRhs] or false
   end
   -- within a strata, significantly larger portraits win
   local sizeLhs = getEffectiveArea(frameLhs)
   local sizeRhs = getEffectiveArea(frameRhs)
   if max(sizeLhs, sizeRhs) / min(sizeLhs, sizeRhs) > 1.1 then
      return sizeLhs > sizeRhs
   end
   -- otherwise, check which is higher
   local raisedLevelLhs = frameLhs:GetRaisedFrameLevel()
   local raisedLevelRhs = frameRhs:GetRaisedFrameLevel()
   if raisedLevelLhs ~= raisedLevelRhs then
      return raisedLevelLhs > raisedLevelRhs
   end
   local levelLhs = frameLhs:GetFrameLevel()
   local levelRhs = frameRhs:GetFrameLevel()
   if levelLhs ~= levelRhs then
      return levelLhs > levelRhs
   end
   -- finally, since this function must not return true for both frames, lest
   -- both be blocked, we require a final fallback: comparing positions is
   -- fine because, by an above guard, the frames are of equal size, and, thus,
   -- if they are also on the same position, then it is fine to block both
   local leftLhs = frameLhs:GetLeft()
   local leftRhs = frameRhs:GetLeft()
   if leftLhs ~= leftRhs then
      return leftLhs < leftRhs
   end
   return frameLhs:GetBottom() < frameRhs:GetBottom()
end

local function blockAnimatedPortrait(portraitTexture, state, blocker)
   state.blockingModels[blocker] = true
   state.model.blocked = true
   refreshWhetherAnimated(portraitTexture, state.model)
end

local function unblockAnimatedPortrait(portraitTexture, state, blocker)
   state.blockingModels[blocker] = nil
   if next(state.blockingModels) == nil then
      state.model.blocked = false
      refreshWhetherAnimated(portraitTexture, state.model)
   end
end

-- check whether the given blocker overlaps and is above any animated portrait,
-- and ensure they are not animated if so. this is laborious workaround for the
-- issue that model frames cull higher but overlapping model frames
local function blockOverlappedPortraitModels(blocker)
   for otherPortraitTexture, otherState in pairs(models) do
      local otherModel = otherState.model
      if blocker ~= otherModel then
         if otherState.model:GetRect() -- region actually exists
             and (otherPortraitTexture:IsVisible() or otherModel:IsVisible())
             and leftFrameShouldBlockRight(blocker, otherState.model)
             and modelsVisiblyIntersect(blocker, otherState.model) then
            blockAnimatedPortrait(otherPortraitTexture, otherState, blocker)
         else
            unblockAnimatedPortrait(otherPortraitTexture, otherState, blocker)
         end
      end
   end
end

local function unblockAllPortraitModels(modelFrame)
   for portraitTexture, modelState in pairs(models) do
      unblockAnimatedPortrait(portraitTexture, modelState, modelFrame)
   end
end

local UPDATE_PERIOD = 1 / 30
-- create the animated model frame
local function createModel(portraitTexture, disableMasking)
   local textureFrame = portraitTexture:GetParent()
   local model = CreateFrame("PlayerModel", nil, textureFrame)
   model:SetAllPoints(portraitTexture)
   model:SetUsingParentLevel(true)
   -- there is no way to set draw sub-layer on models? (haha!!!!!): since the
   -- model draw layer defaults to 0, it is only safe to place the model on the
   -- same draw layer as the portrait if the portrait is on sub-level 0 or above
   -- (the risk is greater that the model covers something than vice versa)
   local drawLayer, subLevel = portraitTexture:GetDrawLayer()
   if subLevel >= 0 then
      model:SetModelDrawLayer(drawLayer)
   else
      model:SetModelDrawLayer(lowerDrawLayer(drawLayer))
   end

   local light = createModelLight()
   model:SetLight(true, light)
   model.light = light
   -- because models may be hidden briefly by other model frames
   model:SetKeepModelOnHide(true)
   model:SetScript("OnShow", function(self)
      -- this used to be required in old client, but maybe not anymore, but does
      -- not hurt: when the model is hidden and re-shown without setting a new
      -- unit, then this guards against the model frame resetting outside addon
      -- control
      self:SetPortraitZoom(1)
      -- at load time, not all portraits have masks available, but the insets
      -- depend on those masks for alignment
      updateModelMaskInsets(self)
      blockOverlappedPortraitModels(self)
   end)
   model:SetScript("OnHide", unblockAllPortraitModels)
   -- camera position breaks when eg scale is changed
   model:SetScript("OnSizeChanged", function(self)
      self:RefreshCamera()
      self:SetPortraitZoom(1)
      updateModelMaskInsets(self)
   end)
   local secondsSinceUpdate = 0
   model:SetScript("OnUpdate", function(self, elapsed)
      secondsSinceUpdate = secondsSinceUpdate + elapsed
      if secondsSinceUpdate < UPDATE_PERIOD then
         return
      end
      secondsSinceUpdate = 0
      if self.unit then
         self:SetPaused(UnitIsDead(self.unit))
      end
      -- this is just defensive: we already try to refresh on `SetTexture` etc
      local isAnimated = refreshWhetherAnimated(portraitTexture, self)
      -- if using raid-style party frames, and then going into edit mode to
      -- turn raid-style off, the party frames will not have their model mask
      -- set properly, because the frame size will be incorrect during the
      -- OnShow, and no OnSizeChanged will fire, either: blizz cannot be trusted
      updateModelMaskInsets(self)
      if isAnimated then
         blockOverlappedPortraitModels(self)
      end
   end)
   createModelTextures(model, portraitTexture, disableMasking)

   if not disableMasking or model.externalPortraitMask then
      if model.externalPortraitMask and (
             model.externalPortraitMask:GetTexture() == 5321198
             or model.externalPortraitMask:GetTexture() == 4682541
          ) then -- if mainline unit frame player portrait mask
         -- then create special mask containers for each masked corner
         local topLeft = createCircularModelMaskContainer(model, 0)
         topLeft:SetPoint("TOPLEFT", model, "TOPLEFT")
         topLeft:SetPoint("BOTTOMRIGHT", model, "CENTER")
         local topRight = createCircularModelMaskContainer(model, math.pi / 2)
         topRight:SetPoint("TOPRIGHT", model, "TOPRIGHT")
         topRight:SetPoint("BOTTOMLEFT", model, "CENTER")
         local bottomLeft = createCircularModelMaskContainer(model, 3 * math.pi / 4)
         bottomLeft:SetPoint("BOTTOMLEFT", model, "BOTTOMLEFT")
         bottomLeft:SetPoint("TOPRIGHT", model, "CENTER")
         model.circleMaskTopLeft = topLeft
         model.circleMaskTopRight = topRight
         model.circleMaskBottomLeft = bottomLeft
         model.animatedDefaultPortraitsMaskShape = PORTRAIT_SHAPE_PLAYER_FRAME
      else -- otherwise, this is a circle mask: just go with full circle mask
         local mask1, mask2 = createCircularModelMask(model, model)
         model.circleMaskFull = { model1 = mask1, model2 = mask2 }
         model.animatedDefaultPortraitsMaskShape = PORTRAIT_SHAPE_CIRCLE
      end
   end

   -- by using a frame buffer, alpha can be made more accurate (otherwise,
   -- model alpha will blend with background alpha). the downside is that frame
   -- buffering requires render-layer flattening, which makes make it impossible
   -- to sandwich the model frame into other frames by fiddling with draw
   -- layers. for most portrait containers, this does not actually matter, so it
   -- is safe to enable this for any frame that has been vetted to look fine
   -- with this enabled, but it is also only necessary if the portrait is ever
   -- not opaque
   if portraitTexture == PlayerPortrait
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
       or findFirstNamedParent(portraitTexture) == PartyFrame then
      model:SetFlattensRenderLayers(true)
      model:SetIsFrameBuffer(true)
      model.bg:SetIgnoreParentAlpha(true)
   end

   maintainModelColorOverlay(portraitTexture, model)
   return model
end

local function rollIdleAnimationVariation(playlist)
   if next(playlist) == nil then
      return 0
   end
   local rng = fastrandom()
   local total_p = 0
   for variation, p in pairs(playlist) do
      total_p = total_p + p
      if rng < total_p then
         return variation
      end
   end
   return 0
end

local function shouldBlacklist(portraitTexture)
   return portraitTexture == MicroButtonPortrait
       or (
          CharacterMicroButton
          and CharacterMicroButton.Portrait
          and portraitTexture == CharacterMicroButton.Portrait
       )
       or (
          PaperDollSidebarTab1
          and portraitTexture == PaperDollSidebarTab1.Icon
       )
       or portraitTexture == TargetFrameToTPortrait
       or TargetFrameToT and portraitTexture == TargetFrameToT.Portrait
       or portraitTexture == FocusFrameToTPortrait
       or (FocusFrameToT and portraitTexture == FocusFrameToT.Portrait)
       or portraitTexture == AchievementFrameComparisonHeaderPortrait
end

local function getOrCreateModelState(portraitTexture, disableMasking)
   local extant = models[portraitTexture]
   if extant then
      return extant
   end

   if shouldBlacklist(portraitTexture) then
      return nil
   end
   local w, h = portraitTexture:GetSize()
   -- non-square portraits simply do not work with the model-masking hack, and
   -- small portraits are not detailed enough to bother animating
   -- (the specific value here, 35, comes from target-of-target being 35 in
   -- classic, but party and pet frames being 37: the former should be disabled
   -- stylistically, imo, but the latter not, and thus this is a decent guide)
   -- (the only non-square portrait i am aware of is the micro button)
   if abs(w - h) > 0.5 or w < 35.5 then
      return nil
   end

   local model = createModel(portraitTexture, disableMasking)
   local state = {
      model = model,
      notAPortrait = false,
      blockingModels = {},
      idlePlaylist = nil,
      nextIdleVariation = nil,
   }
   model:SetScript("OnAnimFinished", function(self)
      local playlist = state.idlePlaylist
      if not playlist then
         return
      end
      local nextVariation = state.nextIdleVariation
      if not nextVariation then
         return
      end
      local variation = nextVariation
      state.nextIdleVariation = rollIdleAnimationVariation(playlist)
      self:SetAnimation(0, variation)
   end)
   models[portraitTexture] = state

   -- `refreshWhetherAnimated` will see that texture is not set to portrait
   local function disableAnimation(self)
      refreshWhetherAnimated(self, model)
   end
   hooksecurefunc(portraitTexture, "SetTexture", disableAnimation)
   hooksecurefunc(portraitTexture, "SetAtlas", disableAnimation)
   hooksecurefunc(portraitTexture, "SetColorTexture", disableAnimation)

   return state
end

-- either to a new unit, or to refresh the extant unit (eg, gear change)
local function updateModelFromUnit(portraitTexture, state)
   local model = state.model
   local unit = model.unit
   model:SetUnit(unit)
   model:RefreshCamera()
   model:SetPortraitZoom(1)
   local animationPlaylist = ANIMATION_OVERRIDES[model:GetModelFileID()]
   if animationPlaylist then
      state.idlePlaylist = animationPlaylist
      state.nextIdleVariation = rollIdleAnimationVariation(animationPlaylist)
      model:SetAnimation(0, rollIdleAnimationVariation(animationPlaylist))
   else
      state.idlePlaylist = nil
   end
   model:SetPaused(UnitIsDead(unit))
   setModelVertexColor(model, portraitTexture:GetVertexColor())
   setModelAlpha(model, portraitTexture:GetAlpha())
end

-- update the portrait to the animated model if possible and desired, or to
-- the default portrait otherwise. note that if the unit is not loaded (not
-- "visible" to the client) or the default portrait is missing, then the model
-- will have no texture, so in that case we fall back to default portraits
local function setAnimatedPortraitTexture(portraitTexture, unit, disableMasking)
   if portraitsNotToAnimate[portraitTexture] then
      return
   end
   local state = getOrCreateModelState(portraitTexture, disableMasking)
   if not state then
      portraitsNotToAnimate[portraitTexture] = true
      return
   end
   state.model.unit = unit
   -- resetting unit and refreshing camera will visibly reset the portrait:
   -- only do it when absolutely necessary, and let UNIT_PORTRAIT_UPDATE
   -- handle when the same unit requires a portrait-model update
   local guid = UnitGUID(unit)
   -- (if the model is invisible, then the frame itself is dead, and we can no
   -- longer rely on UNIT_PORTRAIT_UPDATE: it is imperative that we do not skip
   -- any model updates, then, and hence `isVisible` is part of the skip eval)
   if not state.model:IsVisible() or not state.guid or state.guid ~= guid then
      state.guid = guid
      updateModelFromUnit(portraitTexture, state)
   end
   state.notAPortrait = false
   refreshWhetherAnimated(portraitTexture, state.model)
end

-- post-hook the global portrait texturing function with our animated variant
local function enableAnimatedPortraits()
   hooksecurefunc("SetPortraitTexture", setAnimatedPortraitTexture)
end

local BLOCK_CHECK_UPDATE_PERIOD = 1 / 30
local secondsSinceBlockCheck = {}
local function updatePotentiallyBlockingExternalModelFrame(modelFrame, elapsed)
   if elapsed then
      local t = (secondsSinceBlockCheck[modelFrame] or 0) + elapsed
      if t < BLOCK_CHECK_UPDATE_PERIOD then
         secondsSinceBlockCheck[modelFrame] = t
         return
      end
   end
   secondsSinceBlockCheck[modelFrame] = 0
   blockOverlappedPortraitModels(modelFrame)
end

-- modern clients appear unable to render models if the model frames intersect:
-- track model frames from blizzard ui and turn off animated portraits that
-- are blocked by those model frames
local function registerPotentiallyBlockingExternalModelFrame(frame)
   if not frame then
      return
   end
   if potentiallyBlockingModelFrames[frame] then
      return
   end
   potentiallyBlockingModelFrames[frame] = true
   frame:HookScript("OnShow", blockOverlappedPortraitModels)
   -- check on update because the blocking frame may have moved...
   frame:HookScript("OnUpdate", updatePotentiallyBlockingExternalModelFrame)
   frame:HookScript("OnHide", unblockAllPortraitModels)
end

-- retexture the frames and enable the animated portraits
local function onEvent(_, event, ...)
   if event == "PLAYER_LOGIN" then
      enableAnimatedPortraits()
      registerPotentiallyBlockingExternalModelFrame(CharacterModelFrame)
      registerPotentiallyBlockingExternalModelFrame(DressUpModelFrame)
      registerPotentiallyBlockingExternalModelFrame(SideDressUpModel)
      registerPotentiallyBlockingExternalModelFrame(CharacterModelScene)
      registerPotentiallyBlockingExternalModelFrame(DressUpFrame.ModelScene)
      registerPotentiallyBlockingExternalModelFrame(TabardModel)
   elseif event == "INSPECT_READY" then
      -- inspect model frame is not available before an inspect
      registerPotentiallyBlockingExternalModelFrame(InspectModelFrame)
   elseif event == "PORTRAITS_UPDATED" then
      for portraitTexture, state in pairs(models) do
         local unit = state.model.unit
         if unit then
            updateModelFromUnit(portraitTexture, state)
            refreshWhetherAnimated(portraitTexture, state.model)
         end
      end
   elseif event == "UNIT_PORTRAIT_UPDATE" then
      local unit = ...
      for portraitTexture, state in pairs(models) do
         if state.model.unit == unit then
            updateModelFromUnit(portraitTexture, state)
            refreshWhetherAnimated(portraitTexture, state.model)
         end
      end
   end
end

local function init()
   local f = CreateFrame("Frame")
   f:Hide()
   f:SetScript("OnEvent", onEvent)
   f:RegisterEvent("PLAYER_LOGIN")
   f:RegisterEvent("INSPECT_READY")
   f:RegisterEvent("PORTRAITS_UPDATED")
   f:RegisterEvent("UNIT_PORTRAIT_UPDATE")
end

init()
