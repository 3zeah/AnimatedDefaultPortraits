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

local ThrottledOnUpdate = Util.ThrottledOnUpdate
local NilIfSecretValue = Util.NilIfSecretValue
local TextureIsPortrait = Util.TextureIsPortrait
local LeftStrataIsAboveRight = Util.LeftStrataIsAboveRight
local MIN_PORTRAIT_SIZE_TO_ANIMATE = FrameConfig.MIN_PORTRAIT_SIZE_TO_ANIMATE
local ShouldDisableFor = FrameConfig.ShouldDisableFor
local IsInanimate = FrameConfig.IsInanimate

---the update period in seconds
---
---only needs to be high enough that moving eg a character frame above a
---unit-frame portrait does not result in occlusion for a visually significant
---amount of time
local UPDATE_PERIOD = 1 / 15

---state table of all animated model frames, indexed by each corresponding
---portrait texture that was replaced by that model
---@type { [SimpleTexture]: AnimatedPortraitState }
local animatedPortraits = {}
---the set of animated portraits that correspond to presently visible portraits
---
---because this tracks visible portraits, rather than visible animated-portrait
---frames, the elements of this set are not necessarily visible, but if an
---element of this set is not visible, then the corresponding baseline portrait
---must be visible
---@type { [AnimatedPortraitState]: true? }
local activePortraits = {}
---optimization: when a portrait is not animated for whatever reason, recall to
---skip it for next time
---@type { [SimpleTexture]: true? }
local portraitsNotToAnimate = {}
---set of all models maintained by this add-on, for when the system needs to
---know whether a model is external
---@type { [Model]: true? }
local internalModels = {}
---set of all other models in the interface, such that the system can prevent
---occlusion between these and the animated portraits
---@type { [Frame]: true? }
local externalModels = {}
---set of all other models in the interface that are visible presently
---@type { [Frame]: true? }
local visibleExternalModels = {}

---call whenever an independent variable is updated, eg `model.blocked`
---@param self AnimatedPortraitState
local function refreshWhetherDisabled(self)
   local shouldAnimate = not self.blocked
       and self.textureIsPortrait
       and self.hasModel
   if shouldAnimate then
      if self.disabled ~= false then
         self.disabled = false
         self.portraitTexture:Hide()
         self:Show()
      end
   else
      if not self.disabled then
         self.disabled = true
         self.portraitTexture:Show()
         self:Hide()
      end
   end
end

---call whenever an independent variable is updated, eg whether unit is dead
---@param self AnimatedPortraitState
local function refreshWhetherPaused(self)
   local unit = self.unit
   if not unit then
      return
   end
   if self.isInanimate or UnitIsDead(unit) then
      self:SetPaused(true)
      self:SetAnimation(0, 0)
   else
      self:SetPaused(false)
   end
end

---the portrait texture that the animated portrait is replacing may not be a
---portrait at all, at least temporarily, because its texture was set explicitly
---to an image. mark changes to that state via this function
---@param self AnimatedPortraitState
---@param isPortrait true?
local function setWhetherTextureIsPortrait(self, isPortrait)
   self.textureIsPortrait = isPortrait
   if not isPortrait then
      self.unit = nil
      self.guid = nil
   end
   refreshWhetherDisabled(self)
end

---mark whether the given animated portrait should be disabled because it is
---occluded by another model
---@param self AnimatedPortraitState
---@param isBlocked true?
local function setWhetherBlocked(self, isBlocked)
   self.blocked = isBlocked
   refreshWhetherDisabled(self)
end

---@param self Texture
local function setTextureIsNotAPortrait(self)
   local animatedPortrait = animatedPortraits[self]
   if animatedPortrait then
      setWhetherTextureIsPortrait(animatedPortrait, nil)
   end
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
   if max(sizeLhs, sizeRhs) / min(sizeLhs, sizeRhs) > 1.2 then
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

---@param self AnimatedPortraitState
---@param blocker Frame
local function blockAnimatedPortrait(self, blocker)
   self.blockingModels[blocker] = true
   if not self.blocked then
      setWhetherBlocked(self, true)
   end
end

---@param self AnimatedPortraitState
---@param blocker Frame
local function unblockAnimatedPortrait(self, blocker)
   self.blockingModels[blocker] = nil
   if self.blocked and next(self.blockingModels) == nil then
      setWhetherBlocked(self, nil)
   end
end

---@param self AnimatedPortraitState
local function updateOcclusionBlocksForNewlyActivePortrait(self)
   -- since it is newly active, there are no blocks to unblock
   for otherPortrait, _ in pairs(activePortraits) do
      if self ~= otherPortrait then
         -- in my testing, `ScriptRegion:Intersects` is faster even than just
         -- querying the bounds of both frames, and it also handles regions with
         -- nil "rect"s: very optimal early guard
         if self:Intersects(otherPortrait)
             and AnimatedPortraitFrame.MayOcclude(self, otherPortrait) then
            if leftFrameShouldBlockRight(self, otherPortrait) then
               blockAnimatedPortrait(otherPortrait, self)
            else
               blockAnimatedPortrait(self, otherPortrait)
            end
         end
      end
   end
   for externalModel, _ in pairs(visibleExternalModels) do
      if self:Intersects(externalModel) then
         blockAnimatedPortrait(self, externalModel)
      end
   end
end

---@param blocker Frame
local function unblockAllPortraitModels(blocker)
   for portrait, _ in pairs(activePortraits) do
      if blocker ~= portrait then
         unblockAnimatedPortrait(portrait, blocker)
      end
   end
end

---mark that the given portrait is not active and thus does not need to be
---included in the occlusion-blocking algorithm until it is active again. here,
---active is defined as whether either portrait is visible: animated or baseline
---@param self AnimatedPortraitState
local function registerInactivePortrait(self)
   activePortraits[self] = nil
   self.blocked = nil
   local blockingModels = self.blockingModels
   for k, _ in pairs(self.blockingModels) do
      blockingModels[k] = nil
   end
   unblockAllPortraitModels(self)
end

---mark that the portrait is active. if it was not already, the
---occlusion-blocking system will have to check whether this new portrait
---results in new portrait blocks
local function registerActivePortrait(self)
   if activePortraits[self] then
      return
   end
   activePortraits[self] = true
   updateOcclusionBlocksForNewlyActivePortrait(self)
   refreshWhetherDisabled(self)
end

-- so that it is not picked up by `preventExternalModelOcclusion`
---@param self Model
local function registerInternalModel(self)
   internalModels[self] = true
end

---@param self AnimatedPortraitState
local function onShowAnimatedPortrait(self)
   registerActivePortrait(self)
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
end

---@param self AnimatedPortraitState
local function onHideAnimatedPortrait(self)
   -- if the animated portrait was not disabled, then this add-on did not hide
   -- it: the portrait itself must be inactive
   if not self.disabled then
      registerInactivePortrait(self)
   end
end

---@param self AnimatedPortraitState
local function onUpdateAnimatedPortrait(self)
   refreshWhetherPaused(self)
   -- we already try to track this via `SetTexture` etc, but there are
   -- myriad weird globals to override textures that we may be missing
   local isPortrait = TextureIsPortrait(self.portraitTexture)
   setWhetherTextureIsPortrait(self, isPortrait)
   -- if using raid-style party frames, and then going into edit mode to
   -- turn raid-style off, the party frames will not have their model mask
   -- set properly, because the frame size will be incorrect during the
   -- OnShow, and no OnSizeChanged will not fire: blizz cannot be trusted
   if self.doAlignOnNextUpdate then
      self.doAlignOnNextUpdate = nil
      AnimatedPortraitFrame.UpdateAlignments(self)
   end
end

---@param self Texture
local function onShowPortraitTexture(self)
   local animatedPortrait = animatedPortraits[self]
   if animatedPortrait then
      registerActivePortrait(animatedPortrait)
   end
end

---@param self Texture
local function onHidePortraitTexture(self)
   local animatedPortrait = animatedPortraits[self]
   -- if the animated portrait is disabled, then this add-on did not hide the
   -- baseline portrait: the portrait itself must be inactive
   if animatedPortrait and animatedPortrait.disabled then
      registerInactivePortrait(animatedPortrait)
   end
end

---@param portraitTexture SimpleTexture
---@param disableMasking boolean?
---@return AnimatedPortraitState?
local function getOrCreateAnimatedPortrait(portraitTexture, disableMasking)
   local extant = animatedPortraits[portraitTexture]
   if extant then
      return extant
   end

   if ShouldDisableFor(portraitTexture) then
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

   ---one animated portrait along with all state required to maintain it
   ---@class (exact) AnimatedPortraitState: AnimatedPortraitFrame
   ---@field portraitTexture Texture the replaced baseline portrait
   ---@field textureIsPortrait true?
   ---@field unit UnitToken? the unit that is expected to be in the portrait
   ---@field guid WOWGUID? the guid of the portrait unit
   ---@field disabled boolean? when disabled, the baseline portrait is shown
   ---@field blocked boolean? whether the portrait is occluded by other models
   ---@field hasModel boolean whether the up-to-date model was successfully set
   ---@field isInanimate true? if the portrait model should not be animated
   ---@field doAlignOnNextUpdate true?
   ---@field blockingModels { [Frame]: boolean? }
   ---@field animationVariantBlacklister AnimationVariantBlacklister
   local state = AnimatedPortraitFrame
       .Create(portraitTexture, not disableMasking, registerInternalModel)
   state.portraitTexture = portraitTexture
   state.hasModel = false
   state.blockingModels = {}
   state.animationVariantBlacklister = AnimationVariantBlacklister.Create(state)

   state:SetScript("OnShow", onShowAnimatedPortrait)
   state:SetScript("OnHide", onHideAnimatedPortrait)
   local onUpdate = ThrottledOnUpdate(UPDATE_PERIOD, onUpdateAnimatedPortrait)
   state:SetScript("OnUpdate", onUpdate)

   animatedPortraits[portraitTexture] = state
   if state:IsVisible() or portraitTexture:IsVisible() then
      registerActivePortrait(state)
   end

   portraitTexture:HookScript("OnShow", onShowPortraitTexture)
   portraitTexture:HookScript("OnHide", onHidePortraitTexture)
   hooksecurefunc(portraitTexture, "SetTexture", setTextureIsNotAPortrait)
   hooksecurefunc(portraitTexture, "SetAtlas", setTextureIsNotAPortrait)
   hooksecurefunc(portraitTexture, "SetColorTexture", setTextureIsNotAPortrait)

   return state
end

---update portrait model either to a new unit, or to refresh the extant unit
---(eg, gear change)
---@param self AnimatedPortraitState
local function updateUnitModel(self)
   local success = AnimatedPortraitFrame
       .UpdateUnit(self, self.portraitTexture, self.unit)
   if success then
      AnimationVariantBlacklister
          .UpdateAfterModelChanged(self.animationVariantBlacklister, self)
      self.isInanimate = IsInanimate(self.unit) or nil
      refreshWhetherPaused(self)
   end
   self.hasModel = success
   refreshWhetherDisabled(self)
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
   local state = getOrCreateAnimatedPortrait(portraitTexture, disableMasking)
   if not state then
      portraitsNotToAnimate[portraitTexture] = true
      return
   end
   state.unit = unit
   setWhetherTextureIsPortrait(state, true)
   -- resetting unit and refreshing camera will visibly reset the portrait:
   -- only do it when absolutely necessary, and let `UNIT_PORTRAIT_UPDATE`
   -- handle when the portrait unit changed appearance
   --
   -- if the underlying portrait is inactive (eg no target frame because no
   -- target), then we can no longer rely on `UNIT_PORTRAIT_UPDATE`: it is
   -- imperative that we do not skip any model updates then: the portrait is
   -- inactive if the animated portrait is not visible but also not disabled
   local guid = NilIfSecretValue(UnitGUID(unit))
   if not guid or not state.guid or not state.hasModel or state.guid ~= guid
       or (state:IsShown() and not state:IsVisible()) then
      state.guid = guid
      updateUnitModel(state)
   end
end

-- post-hook the global portrait texturing function with our animated variant
local function enableAnimatedPortraits()
   hooksecurefunc("SetPortraitTexture", setAnimatedPortraitTexture)
end

---@param self Frame
local function onShowExternalModel(self)
   visibleExternalModels[self] = true
   for blocked, _ in pairs(activePortraits) do
      if self:Intersects(blocked) then
         blockAnimatedPortrait(blocked, self)
      end
   end
end

---@param self Frame
local function onHideExternalModel(self)
   visibleExternalModels[self] = nil
   unblockAllPortraitModels(self)
end

---@param model Frame
local function registerExternalModel(model)
   -- do not register models owned by this add-on, and do not register twice
   if not model or internalModels[model] or externalModels[model] then
      return
   end
   externalModels[model] = true
   model:HookScript("OnShow", onShowExternalModel)
   model:HookScript("OnHide", onHideExternalModel)
   if model:IsVisible() then
      onShowExternalModel(model)
   end
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
local function preventExternalModelOcclusion()
   for widgetType, methods in pairs(METHODS_TO_HOOK_PER_MODEL_WIDGET) do
      local meta = getmetatable(CreateFrame(widgetType)).__index
      for _, method in ipairs(methods) do
         hooksecurefunc(meta, method, registerExternalModel)
      end
   end
end

-- re-texture the frames and enable the animated portraits
local function onEvent(_, event, ...)
   if event == "PLAYER_LOGIN" then
      enableAnimatedPortraits()
      preventExternalModelOcclusion()
   elseif event == "PORTRAITS_UPDATED" then
      for _, state in pairs(animatedPortraits) do
         if state.unit then
            updateUnitModel(state)
         end
      end
   elseif event == "UNIT_PORTRAIT_UPDATE" then
      ---@type UnitToken
      local unit = ...
      for _, state in pairs(animatedPortraits) do
         if state.unit == unit then
            updateUnitModel(state)
         end
      end
   end
end

-- re-use this to prevent memory from fluctuating by allocating new arrays every
-- update
local PORTRAIT_ARRAY_BUFFER = {}

-- unfortunately, since frames can move freely without event, model
-- intersections must be re-evaluated periodically
---@param _ Frame just the virtual-frame script handler
local function onUpdateAddOn(_)
   -- just write to the start of the buffer: because each animated portrait
   -- lives forever, trailing elements from last update will not stop any gc
   local n = 0
   for portrait, _ in pairs(activePortraits) do
      n = n + 1
      PORTRAIT_ARRAY_BUFFER[n] = portrait
   end
   for i = 1, n do
      local portrait = PORTRAIT_ARRAY_BUFFER[i]
      for j = i + 1, n do
         local otherPortrait = PORTRAIT_ARRAY_BUFFER[j]
         -- in my testing, `ScriptRegion:Intersects` is faster even than just
         -- querying the bounds of both frames, and it also handles regions with
         -- nil "rect"s: very optimal early guard
         if portrait:Intersects(otherPortrait)
             and AnimatedPortraitFrame.MayOcclude(portrait, otherPortrait) then
            if leftFrameShouldBlockRight(portrait, otherPortrait) then
               blockAnimatedPortrait(otherPortrait, portrait)
               unblockAnimatedPortrait(portrait, otherPortrait)
            else
               blockAnimatedPortrait(portrait, otherPortrait)
               unblockAnimatedPortrait(otherPortrait, portrait)
            end
         else
            unblockAnimatedPortrait(portrait, otherPortrait)
            unblockAnimatedPortrait(otherPortrait, portrait)
         end
      end
      for externalModel, _ in pairs(visibleExternalModels) do
         if portrait:Intersects(externalModel) then
            blockAnimatedPortrait(portrait, externalModel)
         else
            unblockAnimatedPortrait(portrait, externalModel)
         end
      end
   end
end

local function init()
   local f = CreateFrame("Frame")

   f:SetScript("OnEvent", onEvent)
   f:RegisterEvent("PLAYER_LOGIN")
   f:RegisterEvent("PORTRAITS_UPDATED")
   f:RegisterEvent("UNIT_PORTRAIT_UPDATE")

   local onUpdate = ThrottledOnUpdate(UPDATE_PERIOD, onUpdateAddOn)
   f:SetScript("OnUpdate", onUpdate)
end

init()

-------------------------------------------------------------------------------
-- DEV EXPORTS
-------------------------------------------------------------------------------

---@class Main
local lib = {
   AnimatedPortraits = animatedPortraits,
   BlockAnimatedPortrait = blockAnimatedPortrait,
   UnblockAnimatedPortrait = unblockAnimatedPortrait,
   RegisterInternalModel = registerInternalModel,
}
ns.Main = lib
return lib
