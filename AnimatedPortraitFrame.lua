---responsible for creating the animated-portrait model, along with associated
---elements such as the background texture and model mask

local _, ns = ...
---@module "Require"
local require = ns.require

---@module "Const"
local Const = require(ns, "Const")
---@module "Util"
local Util = require(ns, "Util")
---@module "FrameConfig"
local FrameConfig = require(ns, "FrameConfig")
---@module "ModelMaskFrame"
local ModelMaskFrame = require(ns, "ModelMaskFrame")

local MaskShape = Const.MaskShape
local TextureFileId = Const.TextureFileId
local GetDistanceSquared = Util.GetDistanceSquared
local LowerDrawLayer = Util.LowerDrawLayer
local ShouldRenderToFrameBuffer = FrameConfig.ShouldRenderToFrameBuffer
local CreateBaselinePortraitLight = FrameConfig.CreateBaselinePortraitLight
local PORTRAIT_BACKGROUND_COLOR = FrameConfig.PORTRAIT_BACKGROUND_COLOR
local SUPPORTED_MASK_TEXTURE_SHAPES = FrameConfig.SUPPORTED_MASK_TEXTURE_SHAPES

---find a mask texture, preferring one that has a supported shape, such that
---the model mask may mirror it
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
   -- portraits are usually circles: maybe it is a good idea to assume circle
   return texture:GetMaskTexture(1), MaskShape.CIRCLE
end

local function createBackground(model, portraitTexture, portraitTextureIsCircle)
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

   if portraitTextureIsCircle then
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
      return bg, { texture = maskTexture, shape = shape }
   else
      return bg
   end
end

local function setAlpha(model, a)
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
      model.bgTexture:SetAlpha(alphaComponent)
      model:SetModelAlpha(alphaComponent)
   end
end

local function setVertexColor(model, r, g, b, a)
   local light = CreateBaselinePortraitLight()
   light.ambientColor = CreateColor(r, g, b)
   light.diffuseColor = CreateColor(r, g, b)
   model:SetLight(true, light)
   model.bgTexture:SetVertexColor(r, g, b)
   if not a then
      return
   end
   setAlpha(model, a)
end

-- post-hook the portrait coloring to also color the model
local function mirrorPortraitVertexColor(portraitTexture, model)
   hooksecurefunc(portraitTexture, "SetVertexColor", function(_, ...)
      setVertexColor(model, ...)
   end)
   hooksecurefunc(portraitTexture, "SetAlpha", function(_, ...)
      setAlpha(model, ...)
   end)
end

local function updateCamera(self)
   self:RefreshCamera()
   self:SetPortraitZoom(1)
end

-- increasing the frame scale (appears to) effectively increases the model
-- scale, which makes portrait-model particles appear different, because they
-- are not properly scaled with the model. additionally, scaling the model also
-- causes the camera distance to scale, to preserve perspective, which may run
-- into frustum clipping at extreme ui scales
--
-- backing observations:
-- * decreasing the scale of a unit frame to something crazy low, like 0.2,
--   induces near-clipping if this function is disabled
-- * increasing the scale of a unit frame comprising the skeletal warhorse
--   (creature with display id 10720), visibly alters the appearance of the
--   particle glow (particles take some time to amass, however)
local function updateScale(self)
   self:SetModelScale(1 / self:GetEffectiveScale())
   updateCamera(self)
end

local lib = {}

---create a new animated-portrait frame, aligned with and otherwise matching the
---given portrait. even without any mask textures, portrait textures may be
---circular (depending on parameters to `SetPortraitTexture`), and thus this is
---also required input to this function
function lib.Create(portrait, portraitTextureIsCircle)
   local parent = portrait:GetParent()
   local model = CreateFrame("PlayerModel", nil, parent)
   model:SetAllPoints(portrait)
   model:SetUsingParentLevel(true)
   -- there is no way to set draw sub-layer on models? (haha!!!!!): since the
   -- model draw layer defaults to 0, it is only safe to place the model on the
   -- same draw layer as the portrait if the portrait is on sub-level 0 or above
   -- (the risk is greater that the model covers something than vice versa)
   local drawLayer, subLevel = portrait:GetDrawLayer()
   if subLevel >= 0 then
      model:SetModelDrawLayer(drawLayer)
   else
      model:SetModelDrawLayer(LowerDrawLayer(drawLayer))
   end

   local light = CreateBaselinePortraitLight()
   model:SetLight(true, light)
   model:SetKeepModelOnHide(true)

   local bgTexture, maskTexture =
       createBackground(model, portrait, portraitTextureIsCircle)
   local shape = (maskTexture and maskTexture.shape)
       or (portraitTextureIsCircle and MaskShape.CIRCLE)

   if shape then
      local shapeRegion = maskTexture and maskTexture.texture
      local modelMask = ModelMaskFrame.Create(model, shape, shapeRegion)
      model.shape = shape
      model.mask = modelMask
   end

   if ShouldRenderToFrameBuffer(portrait) then
      model:SetFlattensRenderLayers(true)
      model:SetIsFrameBuffer(true)
      bgTexture:SetIgnoreParentAlpha(true)
   end

   model.bgTexture = bgTexture

   mirrorPortraitVertexColor(portrait, model)

   return model
end

---update model either to a new unit, or to refresh the extant unit (eg, gear
---change)
function lib.UpdateUnit(self, portrait, unit)
   self:SetUnit(unit)
   updateScale(self)
   setVertexColor(self, portrait:GetVertexColor())
   setAlpha(self, portrait:GetAlpha())
end

---update camera after any size change to the frame, or other model manipulation
lib.UpdateCamera = updateCamera

---update required alignments after any size change, either to the portrait
---itself or its mask textures, with which the model mask aligns
function lib.UpdateAlignments(self)
   if self.mask then
      ModelMaskFrame.UpdateAlignment(self.mask)
   end
end

-- update model scale after any change to the frame scale
lib.UpdateScale = updateScale

---return whether some part of either model may occlude the other, because they
---visibly intersect
---
---considers model masking. model-mask models will not occlude each other, but
---will occlude visible models, eg portrait models. thus, this function returns
---true exactly when some visible section of either model intersects with the
---bounds of the other model frame
function lib.MayOcclude(modelA, modelB)
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
   local shapeA = modelA.shape
   local shapeB = modelB.shape
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

ns.AnimatedPortraitFrame = lib
return lib
