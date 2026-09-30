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
local states = {}
-- set of all models maintained by this add-on, for when the system needs to
-- know whether a model is external
local models = {}
-- blacklist
local portraitsNotToAnimate = {}
-- state set of all registered potentially-blocking model frames, such that they
-- are only hooked once (see function `registerPotentiallyBlockingModelFrame`)
local potentiallyBlockingModelFrames = {}

-- call whenever an independent variable is updated, eg `state.model.unit`
local function refreshWhetherAnimated(portraitTexture, model)
   local textureIsPortrait = TextureIsPortrait(portraitTexture)
   local shouldAnimate = textureIsPortrait
       and not model.blocked
       and model.unit
       -- units not "visible" to the client cannot have their model loaded
       and UnitIsVisible(model.unit)
   if shouldAnimate then
      if model.disabled ~= false then
         model.disabled = false
         portraitTexture:Hide()
         model:Show()
      end
   else
      if not textureIsPortrait then
         model.unit = nil
      end
      if not model.disabled then
         model.disabled = true
         portraitTexture:Show()
         model:Hide()
      end
   end
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
   if not state.model.blocked then
      state.model.blocked = true
      refreshWhetherAnimated(portraitTexture, state.model)
   end
end

local function unblockAnimatedPortrait(portraitTexture, state, blocker)
   state.blockingModels[blocker] = nil
   if state.model.blocked and next(state.blockingModels) == nil then
      state.model.blocked = false
      refreshWhetherAnimated(portraitTexture, state.model)
   end
end

-- check whether the given blocker overlaps and is above any animated portrait,
-- and ensure they are not animated if so. this is laborious workaround for the
-- issue that model frames cull higher but overlapping model frames
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

local function unblockAllPortraitModels(modelFrame)
   for portraitTexture, modelState in pairs(states) do
      if modelFrame ~= modelState.model then
         unblockAnimatedPortrait(portraitTexture, modelState, modelFrame)
      end
   end
end

-- so that it is not picked up by `tryToRegisterAllNewExternalModelFrames`
local function registerInternalModel(self)
   models[self] = true
end

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

local function onSizeChangedModel(self)
   AnimatedPortraitFrame.UpdateScale(self)
   AnimatedPortraitFrame.UpdateAlignments(self)
end

local UPDATE_PERIOD = 1 / 15
-- create the animated model frame
local function createModel(portraitTexture, disableMasking)
   local model = AnimatedPortraitFrame
       .Create(portraitTexture, not disableMasking, registerInternalModel)

   model:SetScript("OnShow", onShowModel)
   model:SetScript("OnHide", unblockAllPortraitModels)
   model:SetScript("OnSizeChanged", onSizeChangedModel)
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
      refreshWhetherAnimated(portraitTexture, self)
      -- if using raid-style party frames, and then going into edit mode to
      -- turn raid-style off, the party frames will not have their model mask
      -- set properly, because the frame size will be incorrect during the
      -- OnShow, and no OnSizeChanged will fire, either: blizz cannot be trusted
      if self.doAlignOnNextUpdate then
         self.doAlignOnNextUpdate = false
         AnimatedPortraitFrame.UpdateAlignments(self)
      end
      if not self.disabled then
         blockOverlappedPortraitModels(self)
      end
   end)

   return model
end

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
   local state = {
      model = model,
      blockingModels = {},
      animationVariantBlacklister = AnimationVariantBlacklister.Create(model)
   }
   states[portraitTexture] = state

   -- `refreshWhetherAnimated` will see that texture is not set to portrait
   local function disablePortrait(self)
      refreshWhetherAnimated(self, model)
   end
   hooksecurefunc(portraitTexture, "SetTexture", disablePortrait)
   hooksecurefunc(portraitTexture, "SetAtlas", disablePortrait)
   hooksecurefunc(portraitTexture, "SetColorTexture", disablePortrait)

   return state
end

-- either to a new unit, or to refresh the extant unit (eg, gear change)
local function updateModelFromUnit(portraitTexture, state)
   local model = state.model
   local unit = model.unit
   AnimatedPortraitFrame.UpdateUnit(model, portraitTexture, unit)
   AnimationVariantBlacklister
       .UpdateAfterModelChanged(state.animationVariantBlacklister, model)
   model:SetPaused(UnitIsDead(unit))
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
   local model = state.model
   model.unit = unit
   -- resetting unit and refreshing camera will visibly reset the portrait:
   -- only do it when absolutely necessary, and let UNIT_PORTRAIT_UPDATE
   -- handle when the same unit requires a portrait-model update
   local guid = UnitGUID(unit)
   -- (if the model is invisible, then the frame itself is dead, and we can no
   -- longer rely on UNIT_PORTRAIT_UPDATE: it is imperative that we do not skip
   -- any model updates, then, and hence `isVisible` is part of the skip eval)
   if not model:IsVisible() or not state.guid or state.guid ~= guid then
      state.guid = guid
      updateModelFromUnit(portraitTexture, state)
   end
   refreshWhetherAnimated(portraitTexture, model)
end

-- post-hook the global portrait texturing function with our animated variant
local function enableAnimatedPortraits()
   hooksecurefunc("SetPortraitTexture", setAnimatedPortraitTexture)
end

local BLOCK_CHECK_UPDATE_PERIOD = 1 / 15
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
   -- do not register models owned by this add-on, and do not register twice
   if not frame or models[frame] or potentiallyBlockingModelFrames[frame] then
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

-- by hooking into the api:s for actually showing a model in a model frame, we
-- can hope to catch all potentially-blocking external models without having to
-- explicitly register each, especially because some are not present at load
-- time, eg the inspect model and the transmog-preview model
local function tryToRegisterAllNewExternalModelFrames()
   do
      local meta = getmetatable(CreateFrame("Model")).__index
      hooksecurefunc(
         meta, "SetModel", registerPotentiallyBlockingExternalModelFrame
      )
   end
   do
      local meta = getmetatable(CreateFrame("PlayerModel")).__index
      hooksecurefunc(
         meta, "SetModel", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetCreature", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetDisplayInfo", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetUnit", registerPotentiallyBlockingExternalModelFrame
      )
   end
   do
      local meta = getmetatable(CreateFrame("CinematicModel")).__index
      hooksecurefunc(
         meta, "SetModel", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetCreature", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetDisplayInfo", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetUnit", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetCreatureData", registerPotentiallyBlockingExternalModelFrame
      )
   end
   do
      local meta = getmetatable(CreateFrame("DressUpModel")).__index
      hooksecurefunc(
         meta, "SetModel", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetCreature", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetDisplayInfo", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetUnit", registerPotentiallyBlockingExternalModelFrame
      )
   end
   do
      local meta = getmetatable(CreateFrame("TabardModel")).__index
      hooksecurefunc(
         meta, "SetModel", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetCreature", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetDisplayInfo", registerPotentiallyBlockingExternalModelFrame
      )
      hooksecurefunc(
         meta, "SetUnit", registerPotentiallyBlockingExternalModelFrame
      )
   end
   do
      local meta = getmetatable(CreateFrame("ModelScene")).__index
      hooksecurefunc(
         meta, "CreateActor", registerPotentiallyBlockingExternalModelFrame
      )
   end
end

-- re-texture the frames and enable the animated portraits
local function onEvent(_, event, ...)
   if event == "PLAYER_LOGIN" then
      enableAnimatedPortraits()
      tryToRegisterAllNewExternalModelFrames()
      registerPotentiallyBlockingExternalModelFrame(CharacterModelFrame)
      registerPotentiallyBlockingExternalModelFrame(DressUpModelFrame)
      registerPotentiallyBlockingExternalModelFrame(SideDressUpModel)
      registerPotentiallyBlockingExternalModelFrame(CharacterModelScene)
      registerPotentiallyBlockingExternalModelFrame(DressUpFrame.ModelScene)
      registerPotentiallyBlockingExternalModelFrame(TabardModel)
   elseif event == "PORTRAITS_UPDATED" then
      for portraitTexture, state in pairs(states) do
         local unit = state.model.unit
         if unit then
            updateModelFromUnit(portraitTexture, state)
            refreshWhetherAnimated(portraitTexture, state.model)
         end
      end
   elseif event == "UNIT_PORTRAIT_UPDATE" then
      local unit = ...
      for portraitTexture, state in pairs(states) do
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
   f:RegisterEvent("PORTRAITS_UPDATED")
   f:RegisterEvent("UNIT_PORTRAIT_UPDATE")
end

init()
