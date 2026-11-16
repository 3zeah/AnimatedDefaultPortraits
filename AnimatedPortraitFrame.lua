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

---@param shapeLhs MaskShape
---@param shapeRhs MaskShape
---@return boolean
local function leftShapeInscribesRight(shapeLhs, shapeRhs)
   return shapeLhs == shapeRhs
       or shapeLhs == MaskShape.SMALLER_CIRCLE
       or (shapeLhs == MaskShape.CIRCLE
          and shapeRhs == MaskShape.MAINLINE_PLAYER_PORTRAIT)
end

---@param a ShapedMaskTexture?
---@param b ShapedMaskTexture
---@return ShapedMaskTexture
local function mergeShapeTextures(a, b)
   if not a then
      return b
   end
   if leftShapeInscribesRight(a.shape, b.shape) then
      return a
   else
      return b
   end
end

---find a mask texture, preferring one that has a supported shape, such that
---the model mask may mirror it
---@param texture Texture
---@return ShapedMaskTexture?
local function findSupportedMaskTexture(texture)
   local maskCount = texture:GetNumMaskTextures()
   if maskCount == 0 then
      return nil
   end
   ---@type ShapedMaskTexture?
   local shapeTexture = nil
   for i = 1, maskCount do
      local mask = texture:GetMaskTexture(i)
      local shape = SUPPORTED_MASK_TEXTURE_SHAPES[mask:GetTexture()]
      if shape then
         shapeTexture = mergeShapeTextures(
            shapeTexture,
            { texture = mask, shape = shape }
         )
      end
   end
   if shapeTexture then
      return shapeTexture
   end
   -- portraits are usually circles: maybe it is a good idea to assume circle
   return { texture = texture:GetMaskTexture(1), shape = MaskShape.CIRCLE }
end

---@param frame Frame
---@param portraitTexture SimpleTexture
---@return MaskTexture
local function createBasePortraitMask(frame, portraitTexture)
   local mask = frame:CreateMaskTexture()
   mask:SetAllPoints(portraitTexture)
   mask:SetTexture(
      TextureFileId.TEMP_PORTRAIT_ALPHA_MASK,
      "CLAMPTOBLACKADDITIVE",
      "CLAMPTOBLACKADDITIVE"
   )
   return mask
end

---@param frame Frame
---@param source MaskTexture
---@return MaskTexture
local function copyMaskTexture(frame, source)
   local mask = frame:CreateMaskTexture()
   mask:SetAllPoints(source)
   mask:SetTexture(
      source:GetTexture(),
      "CLAMPTOBLACKADDITIVE",
      "CLAMPTOBLACKADDITIVE"
   )
   return mask
end

---@param model PlayerModel
---@param portraitTexture SimpleTexture
---@param portraitTextureIsCircle boolean
---@param maskTexture MaskTexture?
---@return BackgroundTexture
local function createBackground(
    model,
    portraitTexture,
    portraitTextureIsCircle,
    maskTexture
)
   local layer, subLayer = model:GetModelDrawLayer()
   -- it APPEARS the model is always drawn above the background at same level,
   -- but if we ever cannot rely on that, note that the classic trade frame will
   -- break: TradeFrameRecipientPortrait is at (OVERLAY, 1), but
   -- TradeFrame.TopBorder is at (OVERLAY,0), so there is no way to sandwich
   -- both our elements to separate draw layers
   ---@class (exact) BackgroundTexture : Texture
   ---@field baseMask MaskTexture?
   ---@field baseMaskIsApplied boolean
   ---@field shapeMask MaskTexture?
   ---@field shapeMaskIsApplied boolean
   local bg = model:CreateTexture(nil, layer, nil, subLayer)
   bg:SetColorTexture(
      PORTRAIT_BACKGROUND_COLOR.r,
      PORTRAIT_BACKGROUND_COLOR.g,
      PORTRAIT_BACKGROUND_COLOR.b
   )
   bg:SetAllPoints(portraitTexture)

   if portraitTextureIsCircle then
      local mask = createBasePortraitMask(model, portraitTexture)
      bg:AddMaskTexture(mask)
      bg.baseMask = mask
      bg.baseMaskIsApplied = true
   else
      bg.baseMaskIsApplied = false
   end

   -- there may also be a mask texture, even if portrait masking is disabled.
   -- in retail, both masks are typically applied, eg for the target frame
   if maskTexture then
      local mask = copyMaskTexture(model, maskTexture)
      bg:AddMaskTexture(mask)
      bg.shapeMask = mask
      bg.shapeMaskIsApplied = true
   else
      bg.shapeMaskIsApplied = false
   end
   return bg
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

---update camera after any size change to the frame, or other model manipulation
---@param self AnimatedPortraitFrame
local function updateCamera(self)
   self:RefreshCamera()
   self:SetPortraitZoom(1)
end

---update required alignments after any size change, either to the portrait
---itself or its mask textures, with which the model mask aligns
---@param self AnimatedPortraitFrame
local function updateAlignments(self)
   if self.mask then
      ModelMaskFrame.UpdateAlignment(self.mask)
   end
end

---@param portrait SimpleTexture
---@param portraitTextureIsCircle boolean
---@return MaskShape? shape
---@return MaskTexture? shapeTexture
local function deduceShape(portrait, portraitTextureIsCircle)
   local maskTexture = findSupportedMaskTexture(portrait)
   if portraitTextureIsCircle then
      if maskTexture
          -- because mask textures may have resize points, prefer to align with
          -- mask textures over the portrait, which is `CIRCLE` shaped
          and leftShapeInscribesRight(maskTexture.shape, MaskShape.CIRCLE) then
         return maskTexture.shape, maskTexture.texture
      else
         -- of course, technically,  that the base portrait circle strictly
         -- inscribes the mask-texture shape does not mean that the base
         -- portrait actually inscribes the mask texture, since the mask texture
         -- may be moved and resized, but dealing with that shit is a lot of
         -- complexity for a pretty dumb use case: if there is a mask texture
         -- added to something, it is presumably usually with the intent
         -- actually to mask the base texture
         return MaskShape.CIRCLE, nil
      end
   else
      if maskTexture then
         return maskTexture.shape, maskTexture.texture
      else
         return nil, nil
      end
   end
end

---update model scale after any change to the frame scale
---
---increasing the frame scale (appears to) effectively increases the model
---scale, which makes portrait-model particles appear different, because they
---are not properly scaled with the model. additionally, scaling the model also
---causes the camera distance to scale, to preserve perspective, which may run
---into frustum clipping at extreme ui scales
---
---backing observations:
---* decreasing the scale of a unit frame to something crazy low, like 0.2,
---  induces near-clipping if this function is disabled
---* increasing the scale of a unit frame comprising the skeletal warhorse
---  (creature with display id 10720), visibly alters the appearance of the
---  particle glow (particles take some time to amass, however)
---@param self AnimatedPortraitFrame
local function updateScale(self)
   self:SetModelScale(1 / self:GetEffectiveScale())
   updateCamera(self)
end

---@param self AnimatedPortraitFrame
local function onSizeChanged(self)
   updateScale(self)
   updateAlignments(self)
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
   ---@field portraitTexture Texture the replaced baseline portrait
   ---@field package portraitTextureIsCircle boolean
   ---@field package shape MaskShape?
   ---@field package mask ModelMaskFrame?
   ---@field package bgTexture BackgroundTexture
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

   local shape, maskTexture = deduceShape(portrait, portraitTextureIsCircle)
   model.portraitTextureIsCircle = portraitTextureIsCircle

   local bgTexture = createBackground(
      model,
      portrait,
      portraitTextureIsCircle,
      maskTexture
   )

   if shape then
      local modelMask = ModelMaskFrame
          .Create(model, shape, maskTexture, createModelCallback)
      model.shape = shape
      model.mask = modelMask
   end

   if ShouldRenderToFrameBuffer(portrait) then
      model:SetFlattensRenderLayers(true)
      model:SetIsFrameBuffer(true)
      bgTexture:SetIgnoreParentAlpha(true)
   end

   model.portraitTexture = portrait
   model.bgTexture = bgTexture

   model:SetScript("OnSizeChanged", onSizeChanged)
   mirrorPortraitVertexColor(portrait, model)

   return model
end

---update model either to a new unit, or to refresh the extant unit (eg, gear
---change)
---@param self AnimatedPortraitFrame
---@param portrait SimpleTexture
---@param unit UnitToken
function lib.UpdateUnit(self, portrait, unit)
   -- units not "visible" to the client cannot have their model loaded
   if not UnitIsVisible(unit) then
      return false
   end
   local success = self:SetUnit(unit)
   if success then
      updateScale(self)
      setVertexColor(self, portrait:GetVertexColor())
      setAlpha(self, portrait:GetAlpha())
   end
   return success
end

lib.UpdateCamera = updateCamera

lib.UpdateAlignments = updateAlignments

---attempt to deduce the shape of the underlying portrait texture, and update
---the model mask if that shape changed since the last call to this, or since
---creation
---
---you may not want to call this too often, for performance, since doing this
---requires re-checking each mask texture of the portrait texture
---@param self AnimatedPortraitFrame
---@param portraitTextureIsCircle boolean?
function lib.UpdateMaskShape(self, portraitTextureIsCircle)
   if portraitTextureIsCircle ~= nil then
      self.portraitTextureIsCircle = portraitTextureIsCircle
   end
   local shape, maskTexture =
       deduceShape(self.portraitTexture, self.portraitTextureIsCircle)
   -- if the portrait was and is unshaped, there is nothing to do, since there
   -- are no masks or alignments to update. otherwise, first check whether
   -- portrait went from unshaped to shaped or vice versa
   if not shape and not self.shape then
      return
   elseif not shape then
      self.shape = nil
      ModelMaskFrame.Disable(self.mask)
      if self.bgTexture.baseMask then
         self.bgTexture:RemoveMaskTexture(self.bgTexture.baseMask)
      end
      if self.bgTexture.shapeMask then
         self.bgTexture:RemoveMaskTexture(self.bgTexture.shapeMask)
      end
      return
   elseif not self.shape then
      self.shape = shape
      ModelMaskFrame.Enable(self.mask)
      if self.bgTexture.baseMaskIsApplied then
         self.bgTexture:AddMaskTexture(self.bgTexture.baseMask)
      end
      if self.bgTexture.shapeMaskIsApplied then
         self.bgTexture:AddMaskTexture(self.bgTexture.shapeMask)
      end
      -- do not return tho: the portrait went from unshaped to shaped, and the
      -- new shape may be different from whatever the shape was before
      --
      -- this particular guard is only to maintain invariants: an enabled model
      -- mask has a shape and, if the bg texture claims to have applied its
      -- masks, then they are actually applied. this is not optimal performance,
      -- since the later code may override these calls, but an actual portrait
      -- re-shape is not common
   end
   -- ensure background texture has a mask corresponding to base portrait mask,
   -- if a new base portrait shape was sent
   if portraitTextureIsCircle ~= nil then
      if portraitTextureIsCircle then
         if not self.bgTexture.baseMask then
            self.bgTexture.baseMask =
                createBasePortraitMask(self, self.portraitTexture)
         end
         if not self.bgTexture.baseMaskIsApplied then
            self.bgTexture:AddMaskTexture(self.bgTexture.baseMask)
            self.bgTexture.baseMaskIsApplied = true
         end
      else
         if self.bgTexture.baseMaskIsApplied then
            self.bgTexture:RemoveMaskTexture(self.bgTexture.baseMask)
            self.bgTexture.baseMaskIsApplied = false
         end
      end
   end
   -- update and re-align the model mask shape
   local wasChanged = ModelMaskFrame.SetShape(self.mask, shape, maskTexture)
   if not wasChanged then
      return
   end
   -- update background texture mask to mirror the portrait mask texture, but
   -- only if the model-mask system detected any changes to its shape or
   -- alignment
   if maskTexture then
      if self.bgTexture.shapeMask then
         self.bgTexture.shapeMask:ClearAllPoints()
         self.bgTexture.shapeMask:SetAllPoints(maskTexture)
         self.bgTexture.shapeMask:SetTexture(maskTexture:GetTexture())
      else
         local mask = copyMaskTexture(self, maskTexture)
         self.bgTexture.shapeMask = mask
      end
      if not self.bgTexture.shapeMaskIsApplied then
         self.bgTexture:AddMaskTexture(self.bgTexture.shapeMask)
         self.bgTexture.shapeMaskIsApplied = true
      end
   else
      if self.bgTexture.shapeMaskIsApplied then
         self.bgTexture:RemoveMaskTexture(self.bgTexture.shapeMask)
         self.bgTexture.shapeMaskIsApplied = false
      end
   end
   self.shape = shape
end

---@param self AnimatedPortraitFrame
---@param portraitTextureIsCircle boolean
function lib.UpdateBaseShape(self, portraitTextureIsCircle)
   if portraitTextureIsCircle ~= self.portraitTextureIsCircle then
      lib.UpdateMaskShape(self, portraitTextureIsCircle)
   end
end

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
