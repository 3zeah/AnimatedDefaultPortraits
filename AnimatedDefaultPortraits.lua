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
-- set of portraits to animate along with associated configuration
local PORTRAITS_TO_ANIMATE = {
   [PlayerPortrait] = {
      -- margins of the model frame wrt the default portrait texture
      -- (these are tweaked top make the model frame as small as possible
      -- without leaving gaps under the unit frame, which makes it easier to
      -- circle-mask the corners of the model frame)
      margins = { right = 3, left = 4, top = 4, bottom = 3 }
   },
   [TargetFramePortrait] = {
      margins = { right = 4, left = 3, top = 4, bottom = 3 },
   },
   [FocusFramePortrait] = {
      margins = { right = 4, left = 3, top = 4, bottom = 3 }
   },
}

-- state table of all animated model frames, indexed by each corresponding
-- portrait texture that was replaced by that model
local models = {}
-- state set of all registered potentially-blocking model frames, such that they
-- are only hooked once (see function `registerPotentiallyBlockingModelFrame`)
local potentiallyBlockingModelFrames = {}

-- create the solid-color background texture and color overlay of the model
local function createModelTextures(model)
   local bg = model:CreateTexture(nil, "BACKGROUND")
   bg:SetColorTexture(0, 0, 0)
   bg:SetAllPoints()

   local colorOverlay = model:CreateTexture(nil, "OVERLAY")
   colorOverlay:SetAllPoints()
   colorOverlay:SetBlendMode("MOD")
   colorOverlay:SetColorTexture(1, 1, 1)
   model.colorOverlay = colorOverlay
end

-- set the position and dimensions of the model frame to match the portrait
local function positionModelFrame(model, portraitTexture, config)
   local margins = config.margins
   if not margins then
      model:SetAllPoints(portraitTexture)
   else
      model:SetPoint(
         "TOPRIGHT",
         portraitTexture,
         "TOPRIGHT",
         -margins.right,
         -margins.top
      )
      model:SetPoint(
         "BOTTOMLEFT",
         portraitTexture,
         "BOTTOMLEFT",
         margins.left,
         margins.bottom
      )
      model:SetViewInsets(
         -margins.left,
         -margins.right,
         -margins.top,
         -margins.bottom
      )
   end
end

local UPDATE_PERIOD = 1 / 30
-- create the animated model frame
local function createModel(portraitTexture, config)
   local textureFrame = portraitTexture:GetParent()
   local model = CreateFrame("PlayerModel", nil, textureFrame)
   positionModelFrame(model, portraitTexture, config)
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
   createModelTextures(model)
   return model
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

local function getOrCreateModelState(portraitTexture, config)
   local extant = models[portraitTexture]
   if extant then
      return extant
   else
      local model = createModel(portraitTexture, config)
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
   local config = PORTRAITS_TO_ANIMATE[portraitTexture]
   if not config then
      return
   end
   local state = getOrCreateModelState(portraitTexture, config)
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

-- post-hook the portrait coloring to also color the model
local function maintainModelColorOverlay(portraitTexture)
   hooksecurefunc(portraitTexture, "SetVertexColor", function(self, ...)
      local model = getOrCreateModelState(self).model
      setModelVertexColor(model, ...)
   end)
   hooksecurefunc(portraitTexture, "SetAlpha", function(self, ...)
      local model = getOrCreateModelState(self).model
      setModelAlpha(model, ...)
   end)
end

-- post-hook the global portrait texturing function with our animated variant
local function enableAnimatedPortraits()
   hooksecurefunc("SetPortraitTexture", setAnimatedPortraitTexture)
   for portrait, _ in pairs(PORTRAITS_TO_ANIMATE) do
      maintainModelColorOverlay(portrait)
   end
end

local function regionsIntersect(a, b)
   return a:GetLeft() <= b:GetRight() and b:GetLeft() <= a:GetRight()
       and a:GetBottom() <= b:GetTop() and b:GetBottom() <= a:GetTop()
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
