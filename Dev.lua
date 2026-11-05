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
