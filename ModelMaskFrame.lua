---responsible for creating and maintaining the model mask that allows animated
---portraits to fit into circular containers
---
---the model mask is itself a model, but abuses a probably-fragile quirk in the
---ui-model rendering system: models rendered on a lower frame will occlude
---parts of models rendered on higher frames, as long as the lower model would
---have occluded the higher model were they rendered to the same camera. this
---model-mask system abuses this by creating and aligning a model with a
---circular hole in it, beneath the portrait model in frame space, but very near
---to the camera. effectively, the portrait model is rendered through a hole,
---and thus "masked". other mask shapes may be configured similarly

local _, ns = ...
---@module "Require"
local require = ns.require

---@module "Const"
local Const = require(ns, "Const")
---@module "FrameConfig"
local FrameConfig = require(ns, "FrameConfig")

local MaskShape = Const.MaskShape
local MASK_MODEL_CONFIG = FrameConfig.MASK_MODEL_CONFIG

-- # NOTA BENE ON ALL THIS RANDOM FUCKING MATH
-- ## MODEL SIZE MANIPULATION
-- symmetrical insets are used to zoom in and out. in particular,
-- `SetViewInsets(x,x,x,x)` will for negative `x` zoom in by some margin.
-- the intuition for how much `x` will zoom is that `SetViewInsets(x,x,x,x)`,
-- given a frame of size `s`, is equivalent in zoom to a model frame of size
-- `s - 2 * x`. that is, negative view insets are effectively adding a margin
-- size to the model frame, in frame space units, but cropping the render to
-- the actual frame size, which remains smaller. a corollary of this is that,
-- because the effective render size of the model frame needs to be
-- proportional to the size of the visible model frame, `s - 2 * x` must be a
-- linear function on `s` => `x` must be a linear function on `s`. here,
-- `x = MASK_DIGITAL_ZOOM_FACTOR * s`
-- ## MODEL POSITION MANIPULATION
-- the asymmetrical (margin) insets are merely for shifting the model by
-- coordinate differences in frame space: `SetViewInsets(x,-x,0,0)` will
-- simply shift the model to the right by `x` frame-space units, equivalent
-- to adding `x` to the x of the model frame, wrt to the position of the
-- rasterized model
local function tryToAlignModelMaskWithRegion(mask, region)
    local leftSrc, bottomSrc, sizeSrc, _ = mask:GetRect() -- expect square size
    -- but this is only possible if the positions have been initialized
    if not leftSrc then
        return nil
    end
    local leftDst, bottomDst, widthDst, heightDst = region:GetRect()
    if not leftDst then
        return nil
    end
    -- the model mask must be square, because i do not know of a way to
    -- stretch the model only on one axis: target the minimum destination size
    -- when resizing, since having a portrait be too big is worse than too
    -- small (bleeds outside frames)
    local minSizeDst = min(widthDst, heightDst)
    local sizeInset = (sizeSrc - minSizeDst) / 2
    -- zoom in as if the frame were the size of the destination region, but
    -- leave margin accounting for the size of the actual source region
    local digitalZoomInset = MASK_MODEL_CONFIG.digitalZoomFactor
        * minSizeDst + sizeInset
    -- a lot of terms here... given that the zoom inset effectively resizes
    -- the mask with respect to the center, the size inset must be subtracted
    -- from the effective margin, lest the size inset effectively be applied
    -- twice. additionally, because the destination region is treated as
    -- square, half the real-to-square size difference must be added to center
    -- the destination square within its potentially larger real region
    local leftMargin = (leftDst - leftSrc) - sizeInset
        + (widthDst - minSizeDst) / 2
    local bottomMargin = (bottomDst - bottomSrc) - sizeInset
        + (heightDst - minSizeDst) / 2
    return
        digitalZoomInset + leftMargin,
        digitalZoomInset - leftMargin,
        digitalZoomInset - bottomMargin,
        digitalZoomInset + bottomMargin
end

local function evalInsets(mask, shapeRegion)
    if shapeRegion then
        local left, right, top, bottom =
            tryToAlignModelMaskWithRegion(mask, shapeRegion)
        if left then
            return left, right, top, bottom
        end
    end
    -- fallback is simply to align with the model frame itself
    local frameSize, _ = mask:GetSize() -- expect square size
    local digitalZoomInset = MASK_MODEL_CONFIG.digitalZoomFactor * frameSize
    return digitalZoomInset, digitalZoomInset, digitalZoomInset, digitalZoomInset
end

local function applyOrEvalModelMaskInsetsToContainer(
    container,
    shapeRegion,
    left, right, top, bottom
)
    if not container then
        return nil
    end
    if not left then
        left, right, top, bottom = evalInsets(container.model1, shapeRegion)
    end
    container.model1:SetViewInsets(left, right, top, bottom)
    container.model2:SetViewInsets(left, right, top, bottom)
    return left, right, top, bottom
end

---@param mask Model
local function updateModelMaskCamera(mask)
    mask:SetModelScale(MASK_MODEL_CONFIG.scale / mask:GetEffectiveScale())
    mask:SetCameraPosition(
        0, MASK_MODEL_CONFIG.cameraDistance * MASK_MODEL_CONFIG.scale, 0
    )
end

---@param parent Model | ModelMaskClippingContainer
---@param regionToMask Region
---@param createModelCallback fun(model: Model)?
---@return Model
local function createMaskModel(parent, regionToMask, createModelCallback)
    local mask = CreateFrame("Model", nil, parent)
    if createModelCallback then createModelCallback(mask) end
    mask:SetFrameStrata("BACKGROUND") -- lowest: below any portraits
    mask:SetFixedFrameStrata(true)
    mask:SetFrameLevel(0)
    mask:SetFixedFrameLevel(true)
    mask:SetAllPoints(regionToMask)
    mask:SetModel(MASK_MODEL_CONFIG.fileId)
    mask:SetPaused(true)
    mask:MakeCurrentCameraCustom()
    mask:SetCameraFacing(MASK_MODEL_CONFIG.cameraFacing)
    mask:SetPosition(MASK_MODEL_CONFIG.posX, 0, MASK_MODEL_CONFIG.posZ)
    updateModelMaskCamera(mask)
    mask:SetScript("OnSizeChanged", updateModelMaskCamera)
    -- culling behavior is optimized away if mask model is actually hidden:
    -- make it pseudo-invisible
    mask:SetIgnoreParentAlpha(true)
    mask:SetAlpha(0.0001)      -- anything lower seems to get rounded to 0 = hide
    mask:SetModelAlpha(0.0001) -- compounds with frame alpha
    return mask
end

---@param parent Model | ModelMaskClippingContainer
---@param regionToMask Region
---@param roll number
---@param createModelCallback fun(model: Model)?
---@return Model
---@return Model
local function createMaskModels(
    parent, regionToMask, roll, createModelCallback
)
    local model1 = createMaskModel(parent, regionToMask, createModelCallback)
    local model2 = createMaskModel(parent, regionToMask, createModelCallback)
    local baseRoll = roll + MASK_MODEL_CONFIG.cameraRoll
    model1:SetCameraRoll(baseRoll)
    -- mask-model circle has 12 vertices: by adding a second model rolled by 1/24
    -- revolution, the effective circle has 24 vertices
    model2:SetCameraRoll(baseRoll + math.pi / 12)
    return model1, model2
end

---@param parent Model
---@param roll number
---@param createModelCallback fun(model: Model)?
---@return ModelMaskClippingContainer
local function createClippingMaskContainer(parent, roll, createModelCallback)
    ---a clipping frame-container for a model mask, effectively cropping the
    ---mask without altering its alignment
    ---@class (exact) ModelMaskClippingContainer: Frame, ModelMaskModels
    local container = CreateFrame("Frame", nil, parent)
    container:SetUsingParentLevel(true)
    -- use container to crop model mask without having to re-evaluate alignment
    -- (the mask model frame itself is still aligned with full portrait model)
    container:SetClipsChildren(true)
    local model1, model2 = createMaskModels(
        container, parent, roll, createModelCallback
    )
    container.model1 = model1
    container.model2 = model2
    return container
end

---@param self ModelMaskFrame
local function updateAlignment(self)
    local shapeRegion = self.shapeRegion
    local left, right, top, bottom
    -- all masks share the same region rect: eval insets only once
    left, right, top, bottom = applyOrEvalModelMaskInsetsToContainer(
        self.circleMaskFull,
        shapeRegion,
        left, right, top, bottom
    )
    left, right, top, bottom = applyOrEvalModelMaskInsetsToContainer(
        self.circleMaskTopLeft,
        shapeRegion,
        left, right, top, bottom
    )
    applyOrEvalModelMaskInsetsToContainer(
        self.circleMaskTopRight,
        shapeRegion,
        left, right, top, bottom
    )
    applyOrEvalModelMaskInsetsToContainer(
        self.circleMaskBottomLeft,
        shapeRegion,
        left, right, top, bottom
    )
end

---system responsible for creating and updating
---[model-mask frames](lua://ModelMaskFrame)
---@class ModelMaskFrameLib
local lib = {}

---one model-mask frame. any ui-rendered model intersecting the masking shape
---of this frame will be occluded, and thus effectively masked
---@class (exact) ModelMaskFrame
---@field package shapeRegion Region?
---@field package circleMaskFull ModelMaskModels
---@field package circleMaskTopLeft ModelMaskClippingContainer
---@field package circleMaskTopRight ModelMaskClippingContainer
---@field package circleMaskBottomLeft ModelMaskClippingContainer

---create a model-mask frame for the given model. the mask will have the given
---shape and this shape will be aligned with the given shape region. for
---example, given a 100x100 model @(10,10), a circular mask shape, and a shape
---region of 50x50 @(30,20), the visible part of the model will be inside a
---50x50 circle at position (20,10) from the bottom left of the model
---@param modelToMask Model
---@param shape MaskShape
---@param shapeRegion Region?
---@param createModelCallback fun(model: Model)?
---@return ModelMaskFrame
function lib.Create(modelToMask, shape, shapeRegion, createModelCallback)
    local state = {}
    if shape == MaskShape.MAINLINE_PLAYER_PORTRAIT then
        -- then create special mask containers for each masked corner
        local topLeft = createClippingMaskContainer(
            modelToMask, 0, createModelCallback
        )
        topLeft:SetPoint("TOPLEFT", modelToMask, "TOPLEFT")
        topLeft:SetPoint("BOTTOMRIGHT", modelToMask, "CENTER")
        local topRight = createClippingMaskContainer(
            modelToMask, math.pi / 2, createModelCallback
        )
        topRight:SetPoint("TOPRIGHT", modelToMask, "TOPRIGHT")
        topRight:SetPoint("BOTTOMLEFT", modelToMask, "CENTER")
        local bottomLeft = createClippingMaskContainer(
            modelToMask, 3 * math.pi / 4, createModelCallback
        )
        bottomLeft:SetPoint("BOTTOMLEFT", modelToMask, "BOTTOMLEFT")
        bottomLeft:SetPoint("TOPRIGHT", modelToMask, "CENTER")
        state.circleMaskTopLeft = topLeft
        state.circleMaskTopRight = topRight
        state.circleMaskBottomLeft = bottomLeft
    else -- `MaskShape.CIRCLE`
        local mask1, mask2 = createMaskModels(
            modelToMask, modelToMask, 0, createModelCallback
        )
        ---the set of models comprising one model mask
        ---@class (exact) ModelMaskModels
        ---@field package model1 Model
        ---@field package model2 Model
        state.circleMaskFull = { model1 = mask1, model2 = mask2 }
    end
    state.shapeRegion = shapeRegion
    updateAlignment(state)
    return state
end

---update the alignment of the model mask: required after any size change,
---either by the masked frame itself, or the shape region defined at creation
lib.UpdateAlignment = updateAlignment

ns.ModelMaskFrame = lib
return lib
