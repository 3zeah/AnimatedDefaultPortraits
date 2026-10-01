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

---mask texture with a known shape
---@class (exact) ShapedMaskTexture
---@field texture MaskTexture
---@field shape MaskShape

---find a mask texture, preferring one that has a supported shape, such that
---the model mask may mirror it
---@param texture Texture
---@return ShapedMaskTexture?
local function findSupportedMaskTexture(texture)
   local maskCount = texture:GetNumMaskTextures()
   if maskCount == 0 then
      return nil
   end
   for i = 1, maskCount do
      local mask = texture:GetMaskTexture(i)
      local shape = SUPPORTED_MASK_TEXTURE_SHAPES[mask:GetTexture()]
      if shape then
         return { texture = mask, shape = shape }
      end
   end
   -- portraits are usually circles: maybe it is a good idea to assume circle
   return { texture = texture:GetMaskTexture(1), shape = MaskShape.CIRCLE }
end

---@param model PlayerModel
---@param portraitTexture SimpleTexture
---@param portraitTextureIsCircle boolean
---@return Texture
---@return ShapedMaskTexture?
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
   local shapedMaskTexture = findSupportedMaskTexture(portraitTexture)
   if shapedMaskTexture then
      local maskTexture = shapedMaskTexture.texture
      local mask = model:CreateMaskTexture()
      mask:SetAllPoints(maskTexture)
      mask:SetTexture(
         maskTexture:GetTexture(),
         "CLAMPTOBLACKADDITIVE",
         "CLAMPTOBLACKADDITIVE"
      )
      bg:AddMaskTexture(mask)
      return bg, shapedMaskTexture
   else
      return bg
   end
end

---@param model AnimatedPortraitFrame
---@param a number
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

---@param model AnimatedPortraitFrame
---@param r number
---@param g number
---@param b number
---@param a number?
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
---@param portraitTexture SimpleTexture
---@param model AnimatedPortraitFrame
local function mirrorPortraitVertexColor(portraitTexture, model)
   hooksecurefunc(portraitTexture, "SetVertexColor", function(_, ...)
      setVertexColor(model, ...)
   end)
   hooksecurefunc(portraitTexture, "SetAlpha", function(_, ...)
      setAlpha(model, ...)
   end)
end

---@param self AnimatedPortraitFrame
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
---@param self AnimatedPortraitFrame
local function updateScale(self)
   self:SetModelScale(1 / self:GetEffectiveScale())
   updateCamera(self)
end

---responsible for the [animated-portrait frame](lua://AnimatedPortraitFrame)
---@class AnimatedPortraitFrameLib
local lib = {}

---create a new animated-portrait frame, aligned with and otherwise matching the
---given portrait. even without any mask textures, portrait textures may be
---circular (depending on arguments to
---[`SetPortraitTexture`](lua://SetPortraitTexture)), and thus this is also
---required input to this function
---@param portrait SimpleTexture
---@param portraitTextureIsCircle boolean
---@param createModelCallback fun(model: Model)?
---@return AnimatedPortraitFrame
function lib.Create(portrait, portraitTextureIsCircle, createModelCallback)
   local parent = portrait:GetParent()
   ---animated portrait frame, comprising a model along with associated elements
   ---such as the background texture and model mask, which altogether visually
   ---emulates a baseline world of warcraft portrait (which are produced by
   ---[`SetPortraitTexture`](lua://SetPortraitTexture))
   ---@class (exact) AnimatedPortraitFrame: PlayerModel
   ---@field package shape MaskShape?
   ---@field package mask ModelMaskFrame?
   ---@field package bgTexture Texture
   local model = CreateFrame("PlayerModel", nil, parent)
   if createModelCallback then createModelCallback(model) end
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
      local modelMask = ModelMaskFrame
          .Create(model, shape, shapeRegion, createModelCallback)
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
---@param self AnimatedPortraitFrame
---@param portrait SimpleTexture
---@param unit UnitToken
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
---@param self AnimatedPortraitFrame
function lib.UpdateAlignments(self)
   if self.mask then
      ModelMaskFrame.UpdateAlignment(self.mask)
   end
end

-- update model scale after any change to the frame scale
lib.UpdateScale = updateScale

-- just to provide some visual margin to the occlusion checker
local CIRCLE_INTERSECT_MARGIN = 0.99

---return whether some part of either model may occlude the other, because they
---visibly intersect
---
---considers model masking. model-mask models will not occlude each other, but
---will occlude visible models, eg portrait models. thus, this function returns
---true exactly when some visible section of either model intersects with the
---bounds of the other model frame
---@param modelA Frame | AnimatedPortraitFrame
---@param modelB Frame | AnimatedPortraitFrame
---@return boolean
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
   local radiusA = CIRCLE_INTERSECT_MARGIN * max(widthA, heightA) / 2
   local radiusB = CIRCLE_INTERSECT_MARGIN * max(widthB, heightB) / 2
   if distanceSquared < (radiusA + radiusB) ^ 2 then
      return true
   end
   -- since the bounds intersect, but the regions are not close enough to
   -- circle-intersect, exactly one corner of one region is intersecting:
   -- if both this corner and the closest corner of the other region is
   -- un-masked, this is definitely an intersection
   local bIsToRight = centerXA < centerXB
   local bIsToBottom = centerYB < centerYA
   local bIsToBottomRight = bIsToRight and bIsToBottom
   local bIsToTopLeft = not bIsToRight and not bIsToBottom
   -- `PORTRAIT_SHAPE_PLAYER_FRAME` is the only non-circle shape: it has an
   -- un-masked lower-right corner
   if (shapeA == MaskShape.MAINLINE_PLAYER_PORTRAIT and bIsToBottomRight)
       or (shapeB == MaskShape.MAINLINE_PLAYER_PORTRAIT and bIsToTopLeft) then
      return true
   end

   -- finally, by now, the intersecting corners must be masked: this is an
   -- intersection exactly when either region seen as a circle intersects with
   -- the other seen as a rectangle. check rectangle-circle-intersection in two
   -- steps: either the circle is intersecting a line but not a corner, or just
   -- a corner

   -- corner intersections will be checked later: it suffices, therefore, to
   -- checking for line intersections only when the circle center is within the
   -- bounds of the line axis
   --
   -- check for "easy" line intersection: B as circle, A as rectangle
   if leftA <= centerXB and centerXB <= rightA then
      local verticalDistance
      if bIsToBottom then
         verticalDistance = bottomA - centerYB
      else
         verticalDistance = centerYB - topA
      end
      if verticalDistance < radiusB then
         return true
      end
   end
   if bottomA <= centerYB and centerYB <= topA then
      local horizontalDistance
      if bIsToRight then
         horizontalDistance = centerXB - rightA
      else
         horizontalDistance = leftA - centerXB
      end
      if horizontalDistance < radiusB then
         return true
      end
   end
   -- ditto, but vice versa: A as circle, B as rectangle
   if leftB <= centerXA and centerXA <= rightB then
      local verticalDistance
      if bIsToBottom then
         verticalDistance = centerYA - topB
      else
         verticalDistance = bottomB - centerYA
      end
      if verticalDistance < radiusA then
         return true
      end
   end
   if bottomB <= centerYA and centerYA <= topB then
      local horizontalDistance
      if bIsToRight then
         horizontalDistance = leftB - centerXA
      else
         horizontalDistance = centerXA - rightB
      end
      if horizontalDistance < radiusA then
         return true
      end
   end

   local cornerXA, cornerYA
   local cornerXB, cornerYB
   if bIsToBottomRight then
      cornerXA, cornerYA = rightA, bottomA
      cornerXB, cornerYB = leftB, topB
   elseif bIsToTopLeft then
      cornerXA, cornerYA = leftA, topA
      cornerXB, cornerYB = rightB, bottomB
   elseif bIsToRight and not bIsToBottom then
      -- B is to top right
      cornerXA, cornerYA = rightA, topA
      cornerXB, cornerYB = leftB, bottomB
   else
      -- B is to bottom left
      cornerXA, cornerYA = leftA, bottomA
      cornerXB, cornerYB = rightB, topB
   end
   -- are the intersecting corners inside the circle shape?
   local cornerDistanceSquaredA =
       GetDistanceSquared(cornerXA, cornerYA, centerXB, centerYB)
   if cornerDistanceSquaredA < radiusB ^ 2 then
      return true
   end
   local cornerDistanceSquaredB =
       GetDistanceSquared(cornerXB, cornerYB, centerXA, centerYA)
   return cornerDistanceSquaredB < radiusA ^ 2
end

ns.AnimatedPortraitFrame = lib
return lib
