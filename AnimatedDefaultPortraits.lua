-- experimentally evaluated and tweaked to make the models match the portraits
local MODEL_LIGHT = {
   omnidirectional = false,
   -- (x+ is the back of the model, y+ the right-hand side, z+ the bottom)
   point = CreateVector3D(-0.6, 0, -0.6),
   ambientIntensity = 1 / 3,
   ambientColor = CreateColor(1, 1, 1),
   diffuseIntensity = 10 / 6,
   diffuseColor = CreateColor(1, 1, 1),
}
local PORTRAITS_NOT_TO_ANIMATE = {
   [MicroButtonPortrait] = true,
   [TargetFrameToTPortrait] = true,
   [FocusFrameToTPortrait] = true,
}
local CIRCLE_MASK_TEXTURES = {
   [130924] = true,  -- interface/characterframe/tempportraitalphamask.blp
   [3528314] = true, -- interface/masks/circlemask.blp
}

-- state table of all animated model frames, indexed by each corresponding
-- portrait texture that was replaced by that model
local models = {}
-- state set of all registered potentially-blocking model frames, such that they
-- are only hooked once (see function `registerPotentiallyBlockingModelFrame`)
local potentiallyBlockingModelFrames = {}

local function findCircleMaskTexture(texture)
   local maskCount = texture:GetNumMaskTextures()
   if maskCount == 0 then
      return nil
   end
   for i = 1, maskCount do
      local mask = texture:GetMaskTexture(i)
      if CIRCLE_MASK_TEXTURES[mask:GetTexture()] then
         return mask
      end
   end
   return texture:GetMaskTexture(1)
end

-- interface/characterframe/tempportraitalphamask.blp
local CIRCLE_MASK_TEXTURE = 130924
-- sampled from actual blizzard portraits
local PORTRAIT_BACKGROUND_COLOR = CreateColorFromBytes(0, 14, 33, 255)
-- create the solid-color background texture and color overlay of the model
local function createModelTextures(model, portraitTexture)
   local bg = model:CreateTexture(nil, "BACKGROUND")
   bg:SetColorTexture(
      PORTRAIT_BACKGROUND_COLOR.r,
      PORTRAIT_BACKGROUND_COLOR.g,
      PORTRAIT_BACKGROUND_COLOR.b
   )
   bg:SetAllPoints(portraitTexture)

   local portraitMask = findCircleMaskTexture(portraitTexture)
   local mask = model:CreateMaskTexture()
   if portraitMask then
      mask:SetAllPoints(portraitMask)
      mask:SetTexture(portraitMask:GetTexture())
   else
      mask:SetAllPoints(portraitTexture)
      mask:SetTexture(
         CIRCLE_MASK_TEXTURE,
         "CLAMPTOBLACKADDITIVE",
         "CLAMPTOBLACKADDITIVE"
      )
   end
   bg:AddMaskTexture(mask)

   local colorOverlay = model:CreateTexture(nil, "OVERLAY")
   colorOverlay:SetAllPoints()
   colorOverlay:SetBlendMode("MOD")
   colorOverlay:SetColorTexture(1, 1, 1)

   model.bg = bg
   model.mask = mask
   model.colorOverlay = colorOverlay
end

-- insets allow zooming in on the model without culling the mask from camera
-- distance being too low. additionally, insets are used to align the model
-- mask with the original portrait-texture mask that it is replacing, since, in
-- the blizzard ui, even portraits that are pre-masked may be cropped extra
local function setModelMaskInsets(model, mask)
   local digitalZoomFactor = 132.813
   local size_this, _ = mask:GetSize() -- expect square size
   -- also, set insets to align the model mask with the texture mask
   local left_this, bottom_this = mask:GetLeft(), mask:GetBottom()
   local left_that, bottom_that, width_that, height_that = model.mask:GetRect()
   if not left_this or not left_that then
      local inset = digitalZoomFactor * -size_this
      mask:SetViewInsets(inset, inset, inset, inset)
   else
      -- assume everything is square, else view insets will not work anyway
      local sizeInset = size_this - min(width_that, height_that)
      local leftInset = left_that - left_this - sizeInset / 2
      local bottomInset = bottom_that - bottom_this - sizeInset / 2
      local baseInset = digitalZoomFactor * (sizeInset - size_this)
      mask:SetViewInsets(
         baseInset + leftInset,
         baseInset,
         baseInset,
         baseInset + bottomInset
      )
   end
end

local function setModelMaskCamera(mask)
   -- at around camera distance 8, model 587744 stops rendering properly
   -- at around camera distance 30, the model stops covering portrait models
   -- that lean in (eg blood elf female sigh)
   -- the lowest natural ui scale is 65% => 9 / 65% < 14 should be fine
   mask:SetCameraPosition(0, 14 * mask:GetEffectiveScale(), 0)
end

-- any model would do that has a sufficiently round hole: this one is available
-- even on classic clients
local CIRCLE_MASK_MODEL = 587744 -- Interface/Buttons/TalkToMe_Gears.M2
local function createCircularModelMask(model)
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
   local mask = CreateFrame("Model", nil, model)
   mask:SetFrameStrata("BACKGROUND") -- below any portraits
   mask:SetAllPoints()
   mask:SetModel(CIRCLE_MASK_MODEL)
   mask:SetPaused(true)
   mask:MakeCurrentCameraCustom()
   mask:SetCameraFacing(math.pi / 2)
   mask:SetPosition(0.1114, 0, -0.2839) -- center one of the gears
   -- camera/insets experimentally tweaked to ensure only the corners are masked
   setModelMaskInsets(model, mask)
   setModelMaskCamera(mask)
   -- at load time, not all portraits have masks available, but this depends on
   -- those masks for alignment
   mask:HookScript("OnShow", function(self)
      setModelMaskInsets(model, self)
   end)
   -- unfortunately, camera position is not scale-aware: keep updating it
   mask:HookScript("OnSizeChanged", setModelMaskCamera)
   -- culling behavior is optimized away if mask model is actually hidden:
   -- make it pseudo-invisible
   mask:SetAlpha(0.01)      -- anything lower than 1% gets rounded to 0 = hide
   mask:SetModelAlpha(0.01) -- compounds with frame alpha
end

local function setModelAlpha(model, a)
   -- normally translucent models like ghost wolf have 1 alpha in portraits,
   -- and thus we want "model alpha" to be equal to the new overall "alpha",
   -- but additionally, because the alpha of the background texture is combined
   -- with the model alpha, each alpha component is set lower
   local alphaComponent = 1 - sqrt(1 - a)
   model:SetAlpha(alphaComponent)
   model:SetModelAlpha(alphaComponent)
end

local function setModelVertexColor(model, r, g, b, a)
   model.colorOverlay:SetColorTexture(r, g, b)
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

local UPDATE_PERIOD = 1 / 30
-- create the animated model frame
local function createModel(portraitTexture)
   local textureFrame = portraitTexture:GetParent()
   local model = CreateFrame("PlayerModel", nil, textureFrame)
   model:SetAllPoints(portraitTexture)
   model:SetFrameLevel(textureFrame:GetFrameLevel())
   model:SetLight(true, MODEL_LIGHT)
   -- because models may be hidden briefly by other model frames
   model:SetKeepModelOnHide(true)
   -- this used to be required in old client, but maybe not anymore, but does
   -- not hurt: when the model is hidden and re-shown without setting a new unit
   -- then this guards against the model frame resetting outside addon control
   model:HookScript("OnShow", function(self)
      self:SetPortraitZoom(1)
   end)
   -- camera position breaks when eg scale is changed
   model:HookScript("OnSizeChanged", function(self)
      self:RefreshCamera()
      self:SetPortraitZoom(1)
   end)
   local secondsSinceUpdate = 0
   model:HookScript("OnUpdate", function(self, elapsed)
      secondsSinceUpdate = secondsSinceUpdate + elapsed
      if secondsSinceUpdate < UPDATE_PERIOD then
         return
      end
      secondsSinceUpdate = 0
      if self.unit then
         self:SetPaused(UnitIsDead(self.unit))
      end
   end)
   createModelTextures(model, portraitTexture)
   createCircularModelMask(model)
   maintainModelColorOverlay(portraitTexture, model)
   return model
end

local function getOrCreateModelState(portraitTexture)
   local extant = models[portraitTexture]
   if extant then
      return extant
   else
      local model = createModel(portraitTexture)
      local result = { animated = true, model = model, blockingModels = {} }
      models[portraitTexture] = result
      return result
   end
end

-- update the portrait to the animated model if possible and desired, or to
-- the default portrait otherwise. note that if the unit is not loaded (not
-- "visible" to the client) or the default portrait is missing, then the model
-- will have no texture, so in that case we fall back to default portraits
local function setAnimatedPortraitTexture(portraitTexture, unit)
   if PORTRAITS_NOT_TO_ANIMATE[portraitTexture] then
      return
   end
   local w, h = portraitTexture:GetSize()
   -- non-square portraits simply do not work with the model-masking hack, and
   -- small portraits are not detailed enough to bother animating
   -- (the specific value here, 35, comes from target-of-target being 35 but
   -- party and pet frames being 37: the former should be disabled
   -- stylistically, imo, but the latter not, and thus this is a decent guide)
   -- (the only non-square portrait i am aware of is the micro button)
   if w - h > 0.5 or w < 35.5 then
      return
   end
   local state = getOrCreateModelState(portraitTexture)
   -- either show regular static portrait or replace it with animated model
   if not state.animated
       -- units not "visible" to the client cannot have their model loaded
       or not UnitIsVisible(unit)
       -- back in original classic, at least, i observed missing portraits in
       -- some cases: preserve this behavior
       or not portraitTexture:GetTexture() then
      portraitTexture:Show()
      state.model:Hide()
   else
      -- resetting unit and refreshing camera will visibly reset the portrait
      local prevGuid = state.guid
      local guid = UnitGUID(unit)
      if prevGuid and prevGuid == guid then
         return
      end
      state.guid = guid
      local model = state.model
      portraitTexture:Hide()
      model.unit = unit
      model:Show()
      model:SetUnit(unit)
      model:RefreshCamera()
      model:SetPortraitZoom(1)
      model:SetPaused(UnitIsDead(unit))
      setModelVertexColor(model, portraitTexture:GetVertexColor())
      setModelAlpha(model, portraitTexture:GetAlpha())
   end
end

-- post-hook the global portrait texturing function with our animated variant
local function enableAnimatedPortraits()
   hooksecurefunc("SetPortraitTexture", setAnimatedPortraitTexture)
end

local function regionsIntersect(a, b)
   local aLeft, aBottom, aWidth, aHeight = a:GetScaledRect()
   local bLeft, bBottom, bWidth, bHeight = b:GetScaledRect()
   if not aLeft or not bLeft then
      return false
   end
   return aLeft <= bLeft + bWidth and bLeft <= aLeft + aWidth
       and aBottom <= bBottom + bHeight and bBottom <= aBottom + aHeight
end

local function blockAnimatedPortrait(portraitTexture, state, blockingModel)
   state.blockingModels[blockingModel] = true
   state.animated = false
   state.model:Hide()
   portraitTexture:Show()
end

local function unblockAnimatedPortrait(portraitTexture, state, blockingModel)
   state.blockingModels[blockingModel] = nil
   if next(state.blockingModels) == nil then
      state.animated = true
      portraitTexture:Hide()
      state.model:Show()
   end
end

local BLOCK_CHECK_UPDATE_PERIOD = 1 / 30
local secondsSinceBlockCheck = {}
local function blockOverlappedAnimatedPortraits(modelFrame, elapsed)
   -- elapsed is not sent for OnShow, ie the first check
   if elapsed then
      local t = (secondsSinceBlockCheck[modelFrame] or 0) + elapsed
      if t < BLOCK_CHECK_UPDATE_PERIOD then
         secondsSinceBlockCheck[modelFrame] = t
         return
      end
   end
   secondsSinceBlockCheck[modelFrame] = 0
   for portraitTexture, modelState in pairs(models) do
      if regionsIntersect(modelState.model, modelFrame) then
         blockAnimatedPortrait(portraitTexture, modelState, modelFrame)
      else
         unblockAnimatedPortrait(portraitTexture, modelState, modelFrame)
      end
   end
end

local function unblockAnimatedPortraits(modelFrame)
   for portraitTexture, modelState in pairs(models) do
      unblockAnimatedPortrait(portraitTexture, modelState, modelFrame)
   end
end

-- modern clients appear unable to render models if the model frames intersect:
-- track model frames from blizzard ui and turn off animated portraits that
-- are blocked by those model frames
local function registerPotentiallyBlockingModelFrame(frame)
   if potentiallyBlockingModelFrames[frame] then
      return
   end
   potentiallyBlockingModelFrames[frame] = true
   frame:HookScript("OnShow", blockOverlappedAnimatedPortraits)
   -- check on update because the blocking frame may have moved...
   frame:HookScript("OnUpdate", blockOverlappedAnimatedPortraits)
   frame:HookScript("OnHide", unblockAnimatedPortraits)
end

function AnimatedDefaultPortraits_OnLoad(self)
   self:RegisterEvent("PLAYER_LOGIN")
   self:RegisterEvent("INSPECT_READY")
end

-- retexture the frames and enable the animated portraits
function AnimatedDefaultPortraits_OnEvent(_, event)
   if event == "PLAYER_LOGIN" then
      enableAnimatedPortraits()
      registerPotentiallyBlockingModelFrame(CharacterModelFrame)
      registerPotentiallyBlockingModelFrame(DressUpModelFrame)
      registerPotentiallyBlockingModelFrame(SideDressUpModel)
   elseif event == "INSPECT_READY" then
      -- inspect model frame is not available before an inspect
      registerPotentiallyBlockingModelFrame(InspectModelFrame)
   end
end
