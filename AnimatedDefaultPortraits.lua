local ADDON_PATH = [[Interface\AddOns\AnimatedDefaultPortraits]]
-- filepath of the custom targeting frame texture, which hides animated
-- portrait corners
local UNIT_FRAME_TEXTURE_PATH = ADDON_PATH .. [[\UI-TargetingFrame]]
-- model frames are necessarily rectangular, unlike the circular portraits that
-- they replace, and the default unit frames are too thin to hide the model
-- corners: the unit frames must be thickened. for each portrait, then, map the
-- corresponding frame texture and the margins of the model frame relative to
-- the portrait frame
local PORTRAIT_FRAMES = {
   [PlayerPortrait] = {
      -- corresponding frame texture that needs to be replaced
      texture = PlayerFrameTexture,
      -- margins of the model frame wrt the default portrait texture (to hide
      -- corners behind frames)
      margins = { right = 3, left = 4, top = 4, bottom = 3 },
   },
   [TargetFramePortrait] = {
      texture = TargetFrameTextureFrameTexture,
      margins = { right = 4, left = 3, top = 4, bottom = 3 },
   },
   [FocusFramePortrait] = {
      texture = FocusFrameTextureFrameTexture,
      margins = { right = 4, left = 3, top = 4, bottom = 3 },
   }
}
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
local PORTRAITS_TO_ANIMATE = {
   [PlayerPortrait] = true,
   [TargetFramePortrait] = true,
   [FocusFramePortrait] = true,
}

-- state table of all animated model frames, indexed by each corresponding
-- portrait texture that was replaced by that model
local models = {}
-- state set of all registered potentially-blocking model frames, such that they
-- are only hooked once (see function `registerPotentiallyBlockingModelFrame`)
local potentiallyBlockingModelFrames = {}

-- sampled from actual blizzard portraits
local PORTRAIT_BACKGROUND_COLOR = CreateColorFromBytes(0, 14, 33, 255)
-- create the solid-color background texture and color overlay of the model
local function createModelTextures(model)
   local bg = model:CreateTexture(nil, "BACKGROUND")
   bg:SetColorTexture(
      PORTRAIT_BACKGROUND_COLOR.r,
      PORTRAIT_BACKGROUND_COLOR.g,
      PORTRAIT_BACKGROUND_COLOR.b
   )
   bg:SetAllPoints()

   local colorOverlay = model:CreateTexture(nil, "OVERLAY")
   colorOverlay:SetAllPoints()
   colorOverlay:SetBlendMode("MOD")
   colorOverlay:SetColorTexture(1, 1, 1)
   model.colorOverlay = colorOverlay
end

-- set the position and dimensions of the model frame to match the portrait
local function positionModelFrame(model, portraitTexture)
   local portraitFrame = PORTRAIT_FRAMES[portraitTexture]
   if not portraitFrame or not portraitFrame.margins then
      model:SetAllPoints(portraitTexture)
   else
      local margins = portraitFrame.margins
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

-- create the animated model frame
local function createModel(portraitTexture)
   local textureFrame = portraitTexture:GetParent()
   local model = CreateFrame("PlayerModel", nil, textureFrame)
   positionModelFrame(model, portraitTexture)
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
   if not PORTRAITS_TO_ANIMATE[portraitTexture] then
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
      local model = state.model
      portraitTexture:Hide()
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

local UNADORNED_TEXTURE_FILE_PATH =
[[Interface\TargetingFrame\UI-TargetingFrame]]
local UNADORNED_TEXTURE_FILE_ID = 137026
-- set the asset of the texture to the custom one that hides the animated
-- portrait corners if the target frame is unadorned (ie. is neither elite nor
-- rare)
local function setCustomTextureIfUnadorned(self, textureAsset)
   if textureAsset == UNADORNED_TEXTURE_FILE_ID
       or textureAsset == UNADORNED_TEXTURE_FILE_PATH then
      self:SetTexture(UNIT_FRAME_TEXTURE_PATH)
   end
end

-- post-hook the given texture to maintain the custom asset
local function maintainRetexture(texture)
   hooksecurefunc(texture, "SetTexture", setCustomTextureIfUnadorned)
   if texture:GetTexture() == UNADORNED_TEXTURE_FILE_ID then
      texture:SetTexture(UNIT_FRAME_TEXTURE_PATH)
   end
end

-- set the texture of the animated unit frames to the custom one that hides
-- the animated portrait corners
local function retextureUnitFrames()
   for _, portraitFrame in pairs(PORTRAIT_FRAMES) do
      local frameTexture = portraitFrame.texture
      if frameTexture then
         maintainRetexture(frameTexture)
      end
   end
end

-- in this new version of "classic", the player-frame texture is cropped,
-- because it has a lot of dead space given that the player-frame texture is
-- never adorned by the elite/rare dragon. the crop visually cuts off our
-- thicker custom texture, though. fortunately, we can simply copy the texture
-- coordinates from the target frame
local function unCropPlayerFrame()
   -- copy size, texture coordinates, and anchor points from target frame to
   -- player frame, but horizontally mirrored
   PlayerFrameTexture:SetSize(TargetFrameTextureFrameTexture:GetSize())
   local left, top, _, bottom, right =
       TargetFrameTextureFrameTexture:GetTexCoord()
   PlayerFrameTexture:SetTexCoord(right, left, top, bottom) -- x-mirrored
   PlayerFrameTexture:ClearAllPoints()
   for i = 1, TargetFrameTextureFrameTexture:GetNumPoints() do
      local point, _, relativePoint, offsetX, offsetY =
          TargetFrameTextureFrameTexture:GetPoint(i)
      PlayerFrameTexture:SetPoint(
         point,
         PlayerFrame,
         relativePoint,
         -offsetX, -- x-mirrored
         offsetY
      )
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
      unCropPlayerFrame()
      retextureUnitFrames()
      enableAnimatedPortraits()
      registerPotentiallyBlockingModelFrame(CharacterModelFrame)
      registerPotentiallyBlockingModelFrame(DressUpModelFrame)
      registerPotentiallyBlockingModelFrame(SideDressUpModel)
   elseif event == "INSPECT_READY" then
      -- inspect model frame is not available before an inspect
      registerPotentiallyBlockingModelFrame(InspectModelFrame)
   end
end
