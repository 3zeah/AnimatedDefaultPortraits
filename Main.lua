local _, ns = ...
---@module "Require"
local require = ns.require

---@module "Util"
local Util = require(ns, "Util")
---@module "FrameConfig"
local FrameConfig = require(ns, "FrameConfig")
---@module "AnimationVariantBlacklister"
local AnimationVariantBlacklister = require(ns, "AnimationVariantBlacklister")
---@module "AnimatedPortraitFrame"
local AnimatedPortraitFrame = require(ns, "AnimatedPortraitFrame")

local TextureIsPortrait = Util.TextureIsPortrait
local LeftStrataIsAboveRight = Util.LeftStrataIsAboveRight
local MIN_PORTRAIT_SIZE_TO_ANIMATE = FrameConfig.MIN_PORTRAIT_SIZE_TO_ANIMATE
local ShouldNotAnimate = FrameConfig.ShouldNotAnimate

-- state table of all animated model frames, indexed by each corresponding
-- portrait texture that was replaced by that model
---@type { [SimpleTexture]: AnimatedPortraitState }
local states = {}
-- set of all models maintained by this add-on, for when the system needs to
-- know whether a model is external
---@type { [Model]: boolean }
local models = {}
-- blacklist
---@type { [SimpleTexture]: boolean? }
local portraitsNotToAnimate = {}
-- state set of all registered potentially-blocking model frames, such that they
-- are only hooked once (see function `registerPotentiallyBlockingModelFrame`)
---@type { [Frame]: true? }
local potentiallyBlockingModelFrames = {}

-- call whenever an independent variable is updated, eg `model.blocked`
---@param portraitTexture SimpleTexture
---@param model AnimatedPortrait
local function refreshWhetherDisabled(portraitTexture, model)
   local shouldAnimate = not model.blocked
       and model.textureIsPortrait
       and model.hasModel
   if shouldAnimate then
      if model.disabled ~= false then
         model.disabled = false
         portraitTexture:Hide()
         model:Show()
      end
   else
      if not model.disabled then
         model.disabled = true
         portraitTexture:Show()
         model:Hide()
      end
   end
end

---the portrait texture that the animated portrait is replacing may not be a
---portrait at all, at least temporarily, because its texture was explicitly to
---an image. mark changes to that state via this function
---@param portraitTexture SimpleTexture
---@param model AnimatedPortrait
---@param isPortrait boolean
local function setWhetherTextureIsPortrait(portraitTexture, model, isPortrait)
   model.textureIsPortrait = isPortrait
   if not isPortrait then
      model.unit = nil
      model.guid = nil
   end
   refreshWhetherDisabled(portraitTexture, model)
end

---mark that the given animated portrait should be disabled because it is
---occluded by another model
---@param portraitTexture SimpleTexture
---@param model AnimatedPortrait
---@param isBlocked boolean
local function setWhetherBlocked(portraitTexture, model, isBlocked)
   model.blocked = isBlocked
   refreshWhetherDisabled(portraitTexture, model)
end

-- that is, considering scale
---@param frame ScriptRegion
---@return number
local function getEffectiveArea(frame)
   local _, _, w, h = frame:GetScaledRect()
   return (w or 0) * (h or 0)
end

---@param frameLhs Frame
---@param frameRhs Frame
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

---@param portraitTexture SimpleTexture
---@param state AnimatedPortraitState
---@param blocker Frame
local function blockAnimatedPortrait(portraitTexture, state, blocker)
   state.blockingModels[blocker] = true
   if not state.model.blocked then
      setWhetherBlocked(portraitTexture, state.model, true)
   end
end

---@param portraitTexture SimpleTexture
---@param state AnimatedPortraitState
---@param blocker Frame
local function unblockAnimatedPortrait(portraitTexture, state, blocker)
   state.blockingModels[blocker] = nil
   if state.model.blocked and next(state.blockingModels) == nil then
      setWhetherBlocked(portraitTexture, state.model, false)
   end
end

-- check whether the given blocker overlaps and is above any animated portrait,
-- and ensure they are not animated if so. this is laborious workaround for the
-- issue that model frames cull higher but overlapping model frames
---@param blocker Frame | AnimatedPortraitFrame
local function blockOverlappedPortraitModels(blocker)
   for otherPortraitTexture, otherState in pairs(states) do
      local otherModel = otherState.model
      if blocker ~= otherModel then
         if otherModel:GetRect() -- region actually exists
             and (otherPortraitTexture:IsVisible() or otherModel:IsVisible())
             and leftFrameShouldBlockRight(blocker, otherModel)
             and AnimatedPortraitFrame.MayOcclude(blocker, otherModel) then
            blockAnimatedPortrait(otherPortraitTexture, otherState, blocker)
         else
            unblockAnimatedPortrait(otherPortraitTexture, otherState, blocker)
         end
      end
   end
end

---@param blocker Frame
local function unblockAllPortraitModels(blocker)
   for portraitTexture, modelState in pairs(states) do
      if blocker ~= modelState.model then
         unblockAnimatedPortrait(portraitTexture, modelState, blocker)
      end
   end
end

-- so that it is not picked up by `tryToRegisterAllNewExternalModelFrames`
---@param self Model
local function registerInternalModel(self)
   models[self] = true
end

---@param self AnimatedPortrait
local function onShowModel(self)
   -- this used to be required in old client, but maybe not anymore, but does
   -- not hurt: when the model is hidden and re-shown without setting a new
   -- unit, then this guards against the model cam resetting outside addon
   -- control
   AnimatedPortraitFrame.UpdateCamera(self)
   -- at load time, not all portraits have masks available, but the insets
   -- depend on those masks for alignment: refresh alignment on show
   AnimatedPortraitFrame.UpdateAlignments(self)
   -- but even on-show, the regions may lie... see the "OnUpdate" script that
   -- depends on this flag
   self.doAlignOnNextUpdate = true
   blockOverlappedPortraitModels(self)
end

---@param self AnimatedPortraitFrame
local function onSizeChangedModel(self)
   AnimatedPortraitFrame.UpdateScale(self)
   AnimatedPortraitFrame.UpdateAlignments(self)
end

local UPDATE_PERIOD = 1 / 15
-- create the animated model frame
---@param portraitTexture SimpleTexture
---@param disableMasking boolean?
---@return AnimatedPortrait
local function createModel(portraitTexture, disableMasking)
   ---one animated portrait as well as some state maintained directly by its
   ---frame-script handlers
   ---@class (exact) AnimatedPortrait: AnimatedPortraitFrame
   ---@field textureIsPortrait boolean
   ---@field unit UnitToken? the unit that is expected to be in the portrait
   ---@field guid WOWGUID? the guid of the portrait unit
   ---@field disabled boolean? when disabled, the baseline portrait is shown
   ---@field blocked boolean? whether the portrait is occluded by other models
   ---@field hasModel boolean whether the up-to-date model was successfully set
   ---@field doAlignOnNextUpdate boolean?
   local model = AnimatedPortraitFrame
       .Create(portraitTexture, not disableMasking, registerInternalModel)
   model.textureIsPortrait = true
   model.hasModel = false

   model:SetScript("OnShow", onShowModel)
   model:SetScript("OnHide", unblockAllPortraitModels)
   model:SetScript("OnSizeChanged", onSizeChangedModel)
   local secondsSinceUpdate = 0
   ---@param self AnimatedPortrait
   ---@param elapsed number
   local function onUpdate(self, elapsed)
      secondsSinceUpdate = secondsSinceUpdate + elapsed
      if secondsSinceUpdate < UPDATE_PERIOD then
         return
      end
      secondsSinceUpdate = 0
      if self.unit then
         self:SetPaused(UnitIsDead(self.unit))
      end
      -- we already try to track this via `SetTexture` etc, but there are
      -- myriad weird globals to override textures that we may be missing
      local isPortrait = TextureIsPortrait(portraitTexture)
      setWhetherTextureIsPortrait(portraitTexture, self, isPortrait)
      -- if using raid-style party frames, and then going into edit mode to
      -- turn raid-style off, the party frames will not have their model mask
      -- set properly, because the frame size will be incorrect during the
      -- OnShow, and no OnSizeChanged will fire, either: blizz cannot be trusted
      if self.doAlignOnNextUpdate then
         self.doAlignOnNextUpdate = false
         AnimatedPortraitFrame.UpdateAlignments(self)
      end
      -- portrait may have been disabled during this update
      if not self.disabled then
         blockOverlappedPortraitModels(self)
      end
   end
   model:SetScript("OnUpdate", onUpdate)

   return model
end

---@param portraitTexture SimpleTexture
---@param disableMasking boolean?
---@return AnimatedPortraitState?
local function getOrCreateModelState(portraitTexture, disableMasking)
   local extant = states[portraitTexture]
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
   ---an animated portrait as well as all extra state associated with it, which
   ---are not already maintained directly by its script handlers
   ---@class (exact) AnimatedPortraitState
   ---@field model AnimatedPortrait
   ---@field blockingModels { [Frame]: boolean? }
   ---@field animationVariantBlacklister AnimationVariantBlacklister
   local state = {
      model = model,
      blockingModels = {},
      animationVariantBlacklister = AnimationVariantBlacklister.Create(model)
   }
   states[portraitTexture] = state

   ---@param self Texture
   local function setTextureIsNotAPortrait(self)
      setWhetherTextureIsPortrait(self, model, false)
   end
   hooksecurefunc(portraitTexture, "SetTexture", setTextureIsNotAPortrait)
   hooksecurefunc(portraitTexture, "SetAtlas", setTextureIsNotAPortrait)
   hooksecurefunc(portraitTexture, "SetColorTexture", setTextureIsNotAPortrait)

   return state
end

---update portrait model either to a new unit, or to refresh the extant unit
---(eg, gear change)
---@param portraitTexture SimpleTexture
---@param state AnimatedPortraitState
local function updateUnitModel(portraitTexture, state)
   local model = state.model
   local success = AnimatedPortraitFrame
       .UpdateUnit(model, portraitTexture, model.unit)
   if success then
      AnimationVariantBlacklister
          .UpdateAfterModelChanged(state.animationVariantBlacklister, model)
      model:SetPaused(UnitIsDead(model.unit))
   end
   model.hasModel = success
   refreshWhetherDisabled(portraitTexture, model)
end

-- update the portrait to the animated model if possible and desired, or to
-- the default portrait otherwise. note that if the unit is not loaded (not
-- "visible" to the client) or the default portrait is missing, then the model
-- will have no texture, so in that case we fall back to default portraits
---@param portraitTexture SimpleTexture
---@param unit UnitToken
---@param disableMasking boolean?
local function setAnimatedPortraitTexture(portraitTexture, unit, disableMasking)
   if portraitsNotToAnimate[portraitTexture] then
      return
   end
   local state = getOrCreateModelState(portraitTexture, disableMasking)
   if not state then
      portraitsNotToAnimate[portraitTexture] = true
      return
   end
   local model = state.model
   model.unit = unit
   setWhetherTextureIsPortrait(portraitTexture, model, true)
   -- resetting unit and refreshing camera will visibly reset the portrait:
   -- only do it when absolutely necessary, and let `UNIT_PORTRAIT_UPDATE`
   -- handle when the portrait unit changed appearance
   --
   -- if the underlying portrait is inactive (eg no target frame because no
   -- target), then we can no longer rely on `UNIT_PORTRAIT_UPDATE`: it is
   -- imperative that we do not skip any model updates then: the portrait is
   -- inactive if the animated portrait is not visible but also not disabled
   local guid = UnitGUID(unit)
   if not model.guid or model.guid ~= guid or not model.hasModel
       or (not model.disabled and not model:IsVisible()) then
      model.guid = guid
      updateUnitModel(portraitTexture, state)
   end
end

-- post-hook the global portrait texturing function with our animated variant
local function enableAnimatedPortraits()
   hooksecurefunc("SetPortraitTexture", setAnimatedPortraitTexture)
end

local BLOCK_CHECK_UPDATE_PERIOD = 1 / 15
local secondsSinceBlockCheck = {}
---@param modelFrame Frame
---@param elapsed number
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

---@param frame Frame
local function registerPotentiallyBlockingExternalModelFrame(frame)
   -- do not register models owned by this add-on, and do not register twice
   if not frame or models[frame] or potentiallyBlockingModelFrames[frame] then
      return
   end
   potentiallyBlockingModelFrames[frame] = true
   frame:HookScript("OnShow", blockOverlappedPortraitModels)
   -- check on update because the blocking frame may have moved...
   frame:HookScript("OnUpdate", updatePotentiallyBlockingExternalModelFrame)
   frame:HookScript("OnHide", unblockAllPortraitModels)
end

local METHODS_TO_HOOK_PER_MODEL_WIDGET = {
   ["Model"] = { "SetModel" },
   ["PlayerModel"] = { "SetModel", "SetCreature", "SetDisplayInfo", "SetUnit" },
   ["CinematicModel"] = {
      "SetModel", "SetCreature", "SetDisplayInfo", "SetUnit", "SetCreatureData"
   },
   ["DressUpModel"] = {
      "SetModel", "SetCreature", "SetDisplayInfo", "SetUnit"
   },
   ["TabardModel"] = { "SetModel", "SetCreature", "SetDisplayInfo", "SetUnit" },
   ["ModelScene"] = { "CreateActor" },
}
-- modern clients appear unable to render models if the model frames intersect:
-- track model frames from blizzard ui and turn off animated portraits that
-- overlap those model frames. typical example is the character frame covering
-- a unit frame
--
-- by hooking into the api:s for actually showing a model in a model frame, we
-- can hope to catch all potentially-blocking external models without having to
-- explicitly register each, especially because some are not present at load
-- time, eg the inspect model and the transmog-preview model
local function preventIntersectingModelOcclusion()
   for widgetType, methods in pairs(METHODS_TO_HOOK_PER_MODEL_WIDGET) do
      local meta = getmetatable(CreateFrame(widgetType)).__index
      for _, method in ipairs(methods) do
         hooksecurefunc(
            meta, method, registerPotentiallyBlockingExternalModelFrame
         )
      end
   end
end

-- re-texture the frames and enable the animated portraits
local function onEvent(_, event, ...)
   if event == "PLAYER_LOGIN" then
      enableAnimatedPortraits()
      preventIntersectingModelOcclusion()
   elseif event == "PORTRAITS_UPDATED" then
      for portraitTexture, state in pairs(states) do
         if state.model.unit then
            updateUnitModel(portraitTexture, state)
         end
      end
   elseif event == "UNIT_PORTRAIT_UPDATE" then
      ---@type UnitToken
      local unit = ...
      for portraitTexture, state in pairs(states) do
         if state.model.unit == unit then
            updateUnitModel(portraitTexture, state)
         end
      end
   end
end

local function init()
   local f = CreateFrame("Frame")
   f:Hide()
   f:SetScript("OnEvent", onEvent)
   f:RegisterEvent("PLAYER_LOGIN")
   f:RegisterEvent("PORTRAITS_UPDATED")
   f:RegisterEvent("UNIT_PORTRAIT_UPDATE")
end

init()
