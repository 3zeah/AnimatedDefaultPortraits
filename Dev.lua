local _, ns = ...
---@module "Require"
local require = ns.require

---@module "Util"
local Util = require(ns, "Util")
---@module "FrameConfig"
local FrameConfig = require(ns, "FrameConfig")
---@module "Main"
local Main = require(ns, "Main")

local CreateBaselinePortraitLight = FrameConfig.CreateBaselinePortraitLight
local AnimatedPortraits = Main.AnimatedPortraits
local BlockAnimatedPortrait = Main.BlockAnimatedPortrait
local UnblockAnimatedPortrait = Main.UnblockAnimatedPortrait
local RegisterInternalModel = Main.RegisterInternalModel

function AdpNamedParent(frame)
   local result = frame:GetParent()
   while not result:GetName() do
      result = result:GetParent()
   end
   if result:GetName() then
      return result
   else
      return nil
   end
end

-- since many portraits are anon, this also finds the first named parent
function AdpId(portrait)
   local namedParent = AdpNamedParent(portrait)
   local parentName
   if not namedParent then
      parentName = "<anon>"
   else
      parentName = namedParent:GetName()
   end
   return [[{PORTRAIT "]] .. (portrait:GetName() or "<anon>")
       .. [[" IN "]] .. parentName .. [["}]]
end

-- access model frame associated with given portrait, else with the target frame
function Adp(portrait)
   if not portrait and TargetFramePortrait then
      print(
         "input portrait did not exists, using",
         TargetFramePortrait:GetName()
      )
      portrait = TargetFramePortrait -- classic
   elseif not portrait and TargetFrame.TargetFrameContainer.Portrait then
      print(
         "input portrait did not exists, using",
         "TargetFrame.TargetFrameContainer.Portrait"
      )
      portrait = TargetFrame.TargetFrameContainer.Portrait -- retail
   end
   local state = AnimatedPortraits[portrait]
   if not state then
      print("no model for", AdpId(portrait))
      return nil
   end
   return state
end

-- complete state, comprising all models (/dump friendly, at least if keying)
function AdpAll()
   return AnimatedPortraits
end

local function resolveStateFromDevInput(portraitOrModelOrNothing)
   if portraitOrModelOrNothing and AnimatedPortraits[portraitOrModelOrNothing] then
      return portraitOrModelOrNothing, AnimatedPortraits[portraitOrModelOrNothing]
   elseif portraitOrModelOrNothing then
      for portrait, state in pairs(AnimatedPortraits) do
         if state == portraitOrModelOrNothing then
            return portrait, state
         end
      end
      return nil
   else
      return nil
   end
end

local function devGetShowMasks(model)
   local mask = model.mask
   if not mask then
      return nil
   end
   local container = mask.circleMaskFull or mask.circleMaskTopLeft
   return container.model1:GetFrameStrata() == "HIGH"
end

local function devSetShowMask(mask, shouldShow)
   if shouldShow then
      mask:SetLight(true, {
         omnidirectional = false,
         point = CreateVector3D(0, 0, 0),
         ambientIntensity = 1,
         ambientColor = CreateColor(1, 0, 0),
         diffuseIntensity = 1,
         diffuseColor = CreateColor(1, 0, 0)
      })
      mask:SetFixedFrameStrata(false)
      mask:SetFrameStrata("HIGH")
      mask:SetFixedFrameStrata(true)
      mask:SetFixedFrameLevel(false)
      mask:SetFrameLevel(65535)
      mask:SetFixedFrameLevel(true)
      mask:SetAlpha(1)
      mask:SetModelAlpha(0.6)
   else
      mask:SetFixedFrameStrata(false)
      mask:SetFrameStrata("BACKGROUND")
      mask:SetFixedFrameStrata(true)
      mask:SetFixedFrameLevel(false)
      mask:SetFrameLevel(0)
      mask:SetFixedFrameLevel(true)
      mask:SetModelAlpha(0.01)
      mask:SetAlpha(0.01)
   end
end

local function devSetShowMasksInContainer(container, shouldShow)
   if not container then
      return
   end
   devSetShowMask(container.model1, shouldShow)
   devSetShowMask(container.model2, shouldShow)
end

local function devSetShowMasks(model, shouldShow)
   local mask = model.mask
   if not mask then
      return
   end
   devSetShowMasksInContainer(mask.circleMaskFull, shouldShow)
   devSetShowMasksInContainer(mask.circleMaskTopLeft, shouldShow)
   devSetShowMasksInContainer(mask.circleMaskTopRight, shouldShow)
   devSetShowMasksInContainer(mask.circleMaskBottomLeft, shouldShow)
end

-- toggles highlighting and showing the circular model mask to the, for tweaking
-- (for all or given portrait)
function AdpShowMask(portraitOrModelOrNothing)
   local _, given = resolveStateFromDevInput(portraitOrModelOrNothing)
   if given then
      devSetShowMasks(given, not devGetShowMasks(given))
   else
      -- portraits not yet loaded or that were hidden are desynced if all
      -- portraits are toggled independently
      local shouldShow
      for _, state in pairs(AnimatedPortraits) do
         if shouldShow == nil then
            shouldShow = not devGetShowMasks(state)
         end
         devSetShowMasks(state, shouldShow)
      end
   end
end

-- toggling unit-frame textures makes it easier to tweak aligns (eg, player
-- frame, unit frame, etc)
function AdpFrameTex()
   local playerFrameTexture
   if PlayerFrameTexture then
      playerFrameTexture = PlayerFrameTexture
   elseif PlayerFrame and PlayerFrame.PlayerFrameContainer then
      playerFrameTexture = PlayerFrame.PlayerFrameContainer.FrameTexture
   else
      print(
         "ERROR: neither PlayerFrameTexture nor",
         "PlayerFrame.PlayerFrameContainer.FrameTexture was found"
      )
      return
   end
   local shouldShow = not playerFrameTexture:IsShown()
   if PlayerFrameTexture then
      PlayerFrameTexture:SetShown(shouldShow)
   end
   if PlayerFrame and PlayerFrame.PlayerFrameContainer then
      PlayerFrame.PlayerFrameContainer.FrameTexture:SetShown(shouldShow)
   end
   if TargetFrameTextureFrameTexture then
      TargetFrameTextureFrameTexture:SetShown(shouldShow)
   end
   if TargetFrame and TargetFrame.TargetFrameContainer then
      TargetFrame.TargetFrameContainer.FrameTexture:SetShown(shouldShow)
   end
   if TargetFrameToTTextureFrameTexture then
      TargetFrameToTTextureFrameTexture:SetShown(shouldShow)
   end
   if TargetFrameToT and TargetFrameToT.FrameTexture then
      TargetFrameToT.FrameTexture:SetShown(shouldShow)
   end
   if FocusFrameToTTextureFrameTexture then
      FocusFrameToTTextureFrameTexture:SetShown(shouldShow)
   end
   if FocusFrameToT and FocusFrameToT.FrameTexture then
      FocusFrameToT.FrameTexture:SetShown(shouldShow)
   end
end

local DEV_BLOCKER = CreateFrame("Frame")
DEV_BLOCKER:Hide()

local function devSetAnimated(state, shouldAnimate)
   if shouldAnimate then
      UnblockAnimatedPortrait(state, DEV_BLOCKER)
   else
      BlockAnimatedPortrait(state, DEV_BLOCKER)
   end
end

-- toggle animated portrait for all or given portrait: this is the primary dev
-- tool for tweaking lighting and aligns etc etc etc
function AdpToggle(portraitOrModelOrNothing)
   local _, givenState =
       resolveStateFromDevInput(portraitOrModelOrNothing)
   if givenState then
      local shouldUnblock = givenState.blockingModels[DEV_BLOCKER] == true
      devSetAnimated(givenState, shouldUnblock)
   else
      -- portraits not yet loaded or that were hidden are desynced if all
      -- portraits are toggled independently
      local shouldUnblock
      for _, state in pairs(AnimatedPortraits) do
         if shouldUnblock == nil then
            shouldUnblock = state.blockingModels[DEV_BLOCKER] == true
         end
         devSetAnimated(state, shouldUnblock)
      end
   end
end

local function devPose(model)
   model:SetPaused(true)
   model:SetAnimation(0, 0)
   hooksecurefunc(model, "SetPaused", function(self, arg)
      if not arg then
         self:SetPaused(true)
      end
   end)
end

-- set the given or all animated portraits to freeze on the portrait pose. use
-- with `AdpToggle` to better compare appearance of animated portraits to
-- baseline
function AdpPose(portraitOrModelOrNothing)
   local _, given = resolveStateFromDevInput(portraitOrModelOrNothing)
   if given then
      devPose(given)
   else
      for _, state in pairs(AnimatedPortraits) do
         devPose(state)
      end
   end
end

local function devSetLight(model, light)
   local actualLight = CreateBaselinePortraitLight()
   for k, v in pairs(light) do
      actualLight[k] = v
   end
   model:SetLight(true, actualLight)
end

-- change lighting for all or given portrait. this function is nice enough that
-- you may provide a subset of properties and all others default to standard,
-- for tweaking
function AdpLight(light, portraitOrModelOrNothing)
   local _, given = resolveStateFromDevInput(portraitOrModelOrNothing)
   if given then
      devSetLight(given, light)
   else
      for _, state in pairs(AnimatedPortraits) do
         devSetLight(state, light)
      end
   end
end

do -- animation probability research
   ---@type PlayerModel?
   local ANIMATION_DURATION_MODEL_A = nil
   ---@type PlayerModel?
   local ANIMATION_DURATION_MODEL_B = nil

   local ANIMATION_DURATION_PER_VARIATION = {}

   ---@param variation number
   ---@param modelFileId number
   ---@param model PlayerModel
   local function trackAnimationDurationsForVariation(
       variation, modelFileId, model
   )
      model:SetScript("OnModelLoaded", function(self)
         self:SetAnimation(0, variation)
      end)
      local t0 = nil
      model:SetScript("OnAnimStarted", function(_)
         t0 = GetTime()
      end)
      model:SetScript("OnAnimFinished", function(_)
         local t = GetTime()
         if not t0 then return end
         local td = RoundToSignificantDigits(t - t0, 3) -- ms precision
         if not ANIMATION_DURATION_PER_VARIATION[modelFileId] then
            ANIMATION_DURATION_PER_VARIATION[modelFileId] = {}
         end
         if not ANIMATION_DURATION_PER_VARIATION[modelFileId][variation] then
            ANIMATION_DURATION_PER_VARIATION[modelFileId][variation] = {}
         end
         local durations =
             ANIMATION_DURATION_PER_VARIATION[modelFileId][variation]
         table.insert(durations, td)
         local n = 0
         local durationSum = 0
         for _, duration in ipairs(durations) do
            durationSum = durationSum + duration
            n = n + 1
         end
         print(
            "variation", variation, "for model", modelFileId, "took", td,
            "s, with avg =", RoundToSignificantDigits(durationSum / n, 3), "s"
         )
         t0 = GetTime() -- OnAnimStarted does not fire when looping variation
      end)
   end

   ---set up a couple of models for the given file id, or else the current
   ---target, and print the animation duration for the given idle-animation
   ---variation. also, play the animation visually to confirm that the variation
   ---actually exists: when playing a variation that does not exist, blizzard
   ---will play some other variation, but if you start with 0 and move up, you
   ---should be able to identify when the unique variations stop
   ---
   ---the idea behind the method is to use it to compile a list of all idle
   ---animations for a given mode, mapped to their duration, for use later with
   ---[`AdpAnim`](lua://AdpAnim), which compiles the probability of each
   ---animation duration. put together, then, you will have the probability of
   ---each variation, which you may use to blacklist an animation in
   ---[`AnimationVariantBlacklisterLib`](lua://AnimationVariantBlacklisterLib)
   ---@param variation number
   ---@param model number
   function AdpAnimPre(model, variation)
      if not variation then
         print("AdpAnimPre cancelled: no idle-animation variation provided")
         if ANIMATION_DURATION_MODEL_A then
            ANIMATION_DURATION_MODEL_A:Hide()
         end
         if ANIMATION_DURATION_MODEL_B then
            ANIMATION_DURATION_MODEL_B:Hide()
         end
         return
      end
      local actualFileId
      if model then
         actualFileId = model
      else
         local target = Adp()
         if not target then
            print("AdpAnimPre cancelled: no model provided and no target")
            if ANIMATION_DURATION_MODEL_A then
               ANIMATION_DURATION_MODEL_A:Hide()
            end
            if ANIMATION_DURATION_MODEL_B then
               ANIMATION_DURATION_MODEL_B:Hide()
            end
            return
         end
         actualFileId = target:GetModelFileID()
      end
      if not ANIMATION_DURATION_MODEL_A then
         ANIMATION_DURATION_MODEL_A = CreateFrame("PlayerModel", nil, UIParent)
         RegisterInternalModel(ANIMATION_DURATION_MODEL_A)
         ANIMATION_DURATION_MODEL_A:SetPoint("RIGHT", UIParent, "CENTER")
         ANIMATION_DURATION_MODEL_A:SetSize(100, 100)
         ANIMATION_DURATION_MODEL_A:SetFrameStrata("HIGH")
      end
      if not ANIMATION_DURATION_MODEL_B then
         ANIMATION_DURATION_MODEL_B = CreateFrame("PlayerModel", nil, UIParent)
         RegisterInternalModel(ANIMATION_DURATION_MODEL_B)
         ANIMATION_DURATION_MODEL_B:SetPoint("LEFT", UIParent, "CENTER")
         ANIMATION_DURATION_MODEL_B:SetSize(100, 100)
         ANIMATION_DURATION_MODEL_B:SetFrameStrata("HIGH")
      end
      ANIMATION_DURATION_MODEL_A:Show()
      trackAnimationDurationsForVariation(
         variation, actualFileId, ANIMATION_DURATION_MODEL_A
      )
      ANIMATION_DURATION_MODEL_B:Show()
      trackAnimationDurationsForVariation(
         variation, actualFileId, ANIMATION_DURATION_MODEL_B
      )

      ANIMATION_DURATION_MODEL_A:SetModel(actualFileId)
      ANIMATION_DURATION_MODEL_A:SetPortraitZoom(1)
      ANIMATION_DURATION_MODEL_A:SetAnimation(0, variation)

      ANIMATION_DURATION_MODEL_B:SetModel(actualFileId)
      ANIMATION_DURATION_MODEL_B:SetAnimation(0, variation)
   end

   ---@type PlayerModel[]
   local ANIMATION_RESEARCH_MODEL_POOL = {}
   local ANIMATION_RESEARCH_MODELS_DEFAULT_N = 10
   local ANIMATION_RESEARCH_DATA = {}

   ---@return PlayerModel
   local function createAnimationResearchModel()
      local result = CreateFrame("PlayerModel", nil, UIParent)
      RegisterInternalModel(result)
      result:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 50, -50)
      result:SetPoint("BOTTOMRIGHT", UIParent, "TOPLEFT", 100, -100)
      return result
   end

   ---set up many models to play the idle animation of the current target, and
   ---periodically print the proportion of idle-animation variations per duration,
   ---eg something like the following
   ---```
   ---AdpAnim: ANIMATION DURATIONS FOR MODEL 959310
   ---  2.3 s: 137 - 6.8%
   ---  1.8 s: 133 - 6.3%
   ---  2.7 s: 1864 - 85.9%
   ---```
   ---this is useful chiefly in conjunction with
   ---[`AdpAnimPre`](lua://AdpAnimPre), which will map durations to variation
   ---id:s. ie, put together with this, you will have the probability of each
   ---variation, which you may use to blacklist an animation in
   ---[`AnimationVariantBlacklisterLib`](lua://AnimationVariantBlacklisterLib)
   ---
   ---`n`: number of models to spin: the higher this is, the faster the data
   ---will be accurate, but because there will be more lag, the durations will
   ---have more -variance. default: 10
   ---
   ---`precision`: the precision of the durations wrt considering variations
   ---identical: eg, 2.645s and 2.63s will both be rounded to 2.6s for the
   ---purposes of the stat compilation. default: 0.1
   ---
   ---depending on the variation in actual animation-variation durations, you
   ---might get away with setting a very high `n` and `precision`
   ---@param n number
   ---@param precision number
   ---@param model ModelFileId file id for the model, else the target will be used
   function AdpAnim(n, precision, model)
      if n and n <= 0 then
         print(
            "AdpAnim cancelled: desired number of models was non-positive:", n
         )
      end
      local actualPrecision = precision or 0.1
      local actualN = n or ANIMATION_RESEARCH_MODELS_DEFAULT_N
      local actualFileId
      if model then
         actualFileId = model
      else
         local target = Adp()
         if not target then
            print("AdpAnim cancelled: no model provided and no target")
            for _, researchModel in ipairs(ANIMATION_RESEARCH_MODEL_POOL) do
               researchModel:Hide()
            end
            return
         end
         actualFileId = target:GetModelFileID()
      end
      print("AdpAnim: using model file id:", actualFileId)
      do -- allocate models in pool, and hide any extras already pooled
         local i = 1
         for _, extantModel in ipairs(ANIMATION_RESEARCH_MODEL_POOL) do
            if i > actualN then
               extantModel:Hide()
            else
               if extantModel then
                  extantModel:Show()
               else
                  ANIMATION_RESEARCH_MODEL_POOL[i] =
                      createAnimationResearchModel()
               end
            end
            i = i + 1
         end
         while i <= actualN do
            ANIMATION_RESEARCH_MODEL_POOL[i] = createAnimationResearchModel()
            i = i + 1
         end
      end
      for i = 1, actualN do
         local researchModel = ANIMATION_RESEARCH_MODEL_POOL[i]
         researchModel:SetModel(actualFileId)
         researchModel:SetAnimation(0)
         local t0 = nil
         researchModel:SetScript("OnAnimStarted", function(self)
            t0 = GetTime()
         end)
         researchModel:SetScript("OnAnimFinished", function(self)
            local t = GetTime()
            if not t0 then return end
            local td = Round((t - t0) / actualPrecision) * actualPrecision
            if not ANIMATION_RESEARCH_DATA[actualFileId] then
               ANIMATION_RESEARCH_DATA[actualFileId] = {}
            end
            ANIMATION_RESEARCH_DATA[actualFileId][td] =
                (ANIMATION_RESEARCH_DATA[actualFileId][td] or 0) + 1
         end)
      end
      ANIMATION_RESEARCH_MODEL_POOL[1]:SetScript("OnUpdate", Util
         .ThrottledOnUpdate(1, function()
            for m, stats in pairs(ANIMATION_RESEARCH_DATA) do
               print("AdpAnim: ANIMATION DURATIONS FOR MODEL", m)
               local total = 0
               for _, count in pairs(stats) do
                  total = total + count
               end
               for duration, count in pairs(stats) do
                  print(
                     "  ", duration, "s:", count, "-",
                     tostring(RoundToSignificantDigits(count / total, 3) * 100)
                     .. "%")
               end
            end
         end))
   end
end
