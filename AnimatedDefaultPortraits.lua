local _, ns = ...

-- Const
local MaskShape = ns.MaskShape
local ModelFileId = ns.ModelFileId
local TextureFileId = ns.TextureFileId

-- Util
local Set = ns.Set
local GetDistanceSquared = ns.GetDistanceSquared
local CLIENT_IS_CLASSIC = ns.CLIENT_IS_CLASSIC
local TextureIsPortrait = ns.TextureIsPortrait
local LeftStrataIsAboveRight = ns.LeftStrataIsAboveRight
local LowerDrawLayer = ns.LowerDrawLayer

-- Config
local MIN_PORTRAIT_SIZE_TO_ANIMATE = ns.MIN_PORTRAIT_SIZE_TO_ANIMATE
local ShouldNotAnimate = ns.ShouldNotAnimate
local CreateBaselinePortraitLight = ns.CreateBaselinePortraitLight
local PORTRAIT_BACKGROUND_COLOR = ns.PORTRAIT_BACKGROUND_COLOR
local MASK_MODEL_CONFIG = ns.MASK_MODEL_CONFIG
local SUPPORTED_MASK_TEXTURE_SHAPES = ns.SUPPORTED_MASK_TEXTURE_SHAPES

local AnimationVariantBlacklister = ns.AnimationVariantBlacklister

-- state table of all animated model frames, indexed by each corresponding
-- portrait texture that was replaced by that model
local models = {}
-- blacklist
local portraitsNotToAnimate = {}
-- state set of all registered potentially-blocking model frames, such that they
-- are only hooked once (see function `registerPotentiallyBlockingModelFrame`)
local potentiallyBlockingModelFrames = {}

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
      local shape = SUPPORTED_MASK_TEXTURE_SHAPES[mask:GetTexture()]
      if shape then
         return mask, shape
      end
   end
   return texture:GetMaskTexture(1)
end

-- create the solid-color background texture and color overlay of the model
local function createModelTextures(model, portraitTexture, disableMasking)
   local layer, subLayer = model:GetModelDrawLayer()
   -- it APPEARS the model is always drawn above the background at same level,
   -- but if we ever cannot rely on that, note that the classic trade frame will
   -- break: TradeFrameRecipientPortrait is at (OVERLAY, 1), but
   -- TradeFrame.TopBorder is at (OVERLAY,0), so there is no way to sandwich
   -- both our elements to separate draw layers
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
         TextureFileId.TEMP_PORTRAIT_ALPHA_MASK,
         "CLAMPTOBLACKADDITIVE",
         "CLAMPTOBLACKADDITIVE"
      )
      bg:AddMaskTexture(mask)
   end
   -- there may also be a mask texture, even if portrait masking is disabled.
   -- in retail, both masks are typically applied, eg for the target frame
   local maskTexture, shape = findSupportedMaskTexture(portraitTexture)
   if maskTexture then
      local mask = model:CreateMaskTexture()
      mask:SetAllPoints(maskTexture)
      mask:SetTexture(
         maskTexture:GetTexture(),
         "CLAMPTOBLACKADDITIVE",
         "CLAMPTOBLACKADDITIVE"
      )
      bg:AddMaskTexture(mask)
      model.referenceMask = { texture = maskTexture, shape = shape }
   end

   model.bg = bg
end

-- # NOTA BENE ON ALL THIS RANDOM FUCKING MATH
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
-- `x = MASK_DIGITAL_ZOOM_FACTOR * s`
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
   local digitalZoomInset = MASK_MODEL_CONFIG.digitalZoomFactor
       * minSizeDst + sizeInset
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

local function evalModelMaskInsets(model, mask)
   -- if there is a texture mask, the model mask should be aligned with it
   local referenceMask = model.referenceMask
   if referenceMask then
      local left, right, top, bottom =
          tryToAlignModelMaskWithRegion(mask, referenceMask.texture)
      if left then
         return left, right, top, bottom
      end
   end
   -- fallback is simply to align with the model frame itself
   local frameSize, _ = mask:GetSize() -- expect square size
   local digitalZoomInset = MASK_MODEL_CONFIG.digitalZoomFactor * frameSize
   return digitalZoomInset, digitalZoomInset, digitalZoomInset, digitalZoomInset
end

local function applyOrEvalModelMaskInsetsToContainer(
    model,
    container,
    left, right, top, bottom
)
   if not container then
      return nil
   end
   if not left then
      left, right, top, bottom = evalModelMaskInsets(model, container.model1)
   end
   container.model1:SetViewInsets(left, right, top, bottom)
   container.model2:SetViewInsets(left, right, top, bottom)
   return left, right, top, bottom
end

-- faster and more comfortable than setting the insets for each mask separately
local function updateModelMaskInsets(model)
   local left, right, top, bottom
   -- all masks share the same region rect: eval insets only once
   left, right, top, bottom = applyOrEvalModelMaskInsetsToContainer(
      model,
      model.circleMaskFull,
      left, right, top, bottom
   )
   left, right, top, bottom = applyOrEvalModelMaskInsetsToContainer(
      model,
      model.circleMaskTopLeft,
      left, right, top, bottom
   )
   applyOrEvalModelMaskInsetsToContainer(
      model,
      model.circleMaskTopRight,
      left, right, top, bottom
   )
   applyOrEvalModelMaskInsetsToContainer(
      model,
      model.circleMaskBottomLeft,
      left, right, top, bottom
   )
end

local function updateModelMaskCamera(mask)
   mask:SetModelScale(MASK_MODEL_CONFIG.scale / mask:GetEffectiveScale())
   mask:SetCameraPosition(
      0, MASK_MODEL_CONFIG.cameraDistance * MASK_MODEL_CONFIG.scale, 0
   )
end

local function createCircularModelMaskModel(container, model)
   local mask = CreateFrame("Model", nil, container)
   mask:SetFrameStrata("BACKGROUND") -- lowest: below any portraits
   mask:SetFixedFrameStrata(true)
   mask:SetFrameLevel(0)
   mask:SetFixedFrameLevel(true)
   mask:SetAllPoints(model)
   mask:SetModel(MASK_MODEL_CONFIG.fileId)
   mask:SetPaused(true)
   mask:MakeCurrentCameraCustom()
   mask:SetCameraFacing(MASK_MODEL_CONFIG.cameraFacing)
   mask:SetPosition(MASK_MODEL_CONFIG.posX, 0, MASK_MODEL_CONFIG.posZ)
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
   local baseRoll = (roll or 0) + MASK_MODEL_CONFIG.cameraRoll
   mask1:SetCameraRoll(baseRoll)
   -- mask-model circle has 12 vertices: by adding a second model rolled by 1/24
   -- revolution, the effective circle has 24 vertices
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
   local light = CreateBaselinePortraitLight()
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

-- call whenever an independent variable is updated, eg `state.model.unit`
local function refreshWhetherAnimated(portraitTexture, model)
   local textureIsPortrait = TextureIsPortrait(portraitTexture)
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
       GetDistanceSquared(centerXA, centerYA, centerXB, centerYB)
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
   if (shapeA == MaskShape.MAINLINE_PLAYER_PORTRAIT and bIsToBottomRight)
       or (shapeB == MaskShape.MAINLINE_PLAYER_PORTRAIT and bIsToTopLeft) then
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
       GetDistanceSquared(offendingXA, offendingYA, centerXB, centerYB)
   if cornerDistanceSquaredA < (0.99 * radiusB) ^ 2 then
      return true
   end
   local cornerDistanceSquaredB =
       GetDistanceSquared(offendingXB, offendingYB, centerXA, centerYA)
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
      return LeftStrataIsAboveRight(strataLhs, strataRhs)
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

-- not necessarily exhaustive
local SCORPION_MODELS = Set(
   ModelFileId.SCORPION,
   ModelFileId.HORDE_SCORPION,
   ModelFileId.HORDE_SCORPION_MOUNT
)
local function updateModelScale(model)
   local baseScale
   -- the dreaded scorpid hack: scorpids keep waving their fakakta claws through
   -- and very close to the camera, which causes the claw to pop out of the
   -- model mask, which relies on the portrait model being at a lower depth for
   -- occlusion. by increasing the model scale, the depth of the portrait model
   -- is arbitrarily increased without affecting the perspective. the SCORPION
   -- EFFECT appears worse in mainline, presumably because the clipping plane
   -- is nearer, maybe
   --
   -- do not apply this workaround to all models, though, because it ruins
   -- particles and puts deep models at risk of getting far-clipped: verify each
   -- model that is included here
   if not CLIENT_IS_CLASSIC and SCORPION_MODELS[model:GetModelFileID()] then
      baseScale = 500
   else
      baseScale = 1
   end
   model:SetModelScale(baseScale / model:GetEffectiveScale())
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
      model:SetModelDrawLayer(LowerDrawLayer(drawLayer))
   end

   local light = CreateBaselinePortraitLight()
   model:SetLight(true, light)
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
      updateModelScale(self)
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

   if not disableMasking or model.referenceMask then
      local referenceMask = model.referenceMask
      if referenceMask
          and referenceMask.shape == MaskShape.MAINLINE_PLAYER_PORTRAIT then
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
         model.animatedDefaultPortraitsMaskShape = MaskShape.MAINLINE_PLAYER_PORTRAIT
      else -- otherwise, this is a circle mask
         local mask1, mask2 = createCircularModelMask(model, model)
         model.circleMaskFull = { model1 = mask1, model2 = mask2 }
         model.animatedDefaultPortraitsMaskShape = MaskShape.CIRCLE
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

local function getOrCreateModelState(portraitTexture, disableMasking)
   local extant = models[portraitTexture]
   if extant then
      return extant
   end

   if ShouldNotAnimate(portraitTexture) then
      return nil
   end
   local w, h = portraitTexture:GetSize()
   -- non-square portraits simply do not work with the model-masking hack, and
   -- small portraits are not detailed enough to bother animating
   -- (the only non-square portraits i am aware of are the micro button and the
   -- the character-stats button in the post-cata character frame)
   if abs(w - h) > 0.5 or w < MIN_PORTRAIT_SIZE_TO_ANIMATE - 0.5 then
      return nil
   end

   local model = createModel(portraitTexture, disableMasking)
   local state = {
      model = model,
      notAPortrait = false,
      blockingModels = {},
      animationVariantBlacklister = AnimationVariantBlacklister.Create(model)
   }
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
   updateModelScale(model)
   model:RefreshCamera()
   model:SetPortraitZoom(1)
   AnimationVariantBlacklister
       .UpdateAfterModelChanged(state.animationVariantBlacklister, model)
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

-- re-texture the frames and enable the animated portraits
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
