---utility functions that abstract details of math, lua, or world of warcraft
---@class Util
local lib = {}

---@generic T
---@param ... T
---@return { [T]: true? }
function lib.Set(...)
    local result = {}
    for _, v in ipairs({ ... }) do
        result[v] = true
    end
    return result
end

---@param xA number
---@param yA number
---@param xB number
---@param yB number
---@return number
function lib.GetDistanceSquared(xA, yA, xB, yB)
    return abs(xA - xB) ^ 2 + abs(yA - yB) ^ 2
end

do -- project id util
    local function setIfKeyExists(table, k, v)
        if k then
            table[k] = v
        end
    end

    ---@return { [integer]: integer? }
    local function evalWowClassicProjectOrder()
        local result = {}
        setIfKeyExists(result, WOW_PROJECT_CLASSIC, 0)
        setIfKeyExists(result, WOW_PROJECT_BURNING_CRUSADE_CLASSIC, 1)
        setIfKeyExists(result, WOW_PROJECT_WRATH_CLASSIC, 2)
        setIfKeyExists(result, WOW_PROJECT_CATACLYSM_CLASSIC, 3)
        setIfKeyExists(result, WOW_PROJECT_MISTS_CLASSIC, 4)
        return result
    end
    local WOW_CLASSIC_PROJECT_ORDER = evalWowClassicProjectOrder()
    local CLASSIC_RANK = WOW_CLASSIC_PROJECT_ORDER[WOW_PROJECT_ID]
    local CLIENT_IS_CLASSIC = CLASSIC_RANK ~= nil

    lib.CLIENT_IS_CLASSIC = CLIENT_IS_CLASSIC

    ---@param projectId integer
    ---@return boolean
    function lib.ClientIsClassicBefore(projectId)
        return CLIENT_IS_CLASSIC
            and CLASSIC_RANK < WOW_CLASSIC_PROJECT_ORDER[projectId]
    end
end

---throttles the given function such that it only runs every `period` seconds
---@generic T
---@param period number
---@param onUpdate fun(self: T)
---@return fun(self: T, elapsed: number)
function lib.ThrottledOnUpdate(period, onUpdate)
    local secondsSinceUpdate = 0
    return function(self, elapsed)
        secondsSinceUpdate = secondsSinceUpdate + elapsed
        if secondsSinceUpdate <= period then
            return
        end
        secondsSinceUpdate = 0
        onUpdate(self)
    end
end

---@param texture TextureBase
---@return boolean
function lib.TextureIsPortrait(texture)
    return texture:GetTexture() == "RTPortrait1"
end

do -- frame strata util
    ---@type FrameStrata[]
    local FRAME_STRATA_ORDER = {
        "WORLD",
        "BACKGROUND",
        "LOW",
        "MEDIUM",
        "HIGH",
        "DIALOG",
        "FULLSCREEN",
        "FULLSCREEN_DIALOG",
        "TOOLTIP",
    }

    ---@return { [FrameStrata]: { [FrameStrata]: boolean? } }
    local function evalFrameStrataGreaterThanOrdering()
        local result = {}
        for i, strata in ipairs(FRAME_STRATA_ORDER) do
            local result_i = {}
            for j = 1, i - 1 do
                result_i[FRAME_STRATA_ORDER[j]] = true
            end
            result[strata] = result_i
        end
        return result
    end
    local FRAME_STRATA_GREATER_THAN_ORDERING =
        evalFrameStrataGreaterThanOrdering()

    ---@param strataLhs FrameStrata
    ---@param strataRhs FrameStrata
    ---@return boolean
    function lib.LeftStrataIsAboveRight(strataLhs, strataRhs)
        return FRAME_STRATA_GREATER_THAN_ORDERING[strataLhs][strataRhs] or false
    end
end

do -- draw layer util
    ---@type DrawLayer[]
    local DRAW_LAYER_ORDER = {
        "BACKGROUND",
        "BORDER",
        "ARTWORK",
        "OVERLAY",
        "HIGHLIGHT",
    }

    ---@return { [DrawLayer]: DrawLayer }
    local function evalLowerDrawLayerMap()
        local result = {}
        for rank, layer in ipairs(DRAW_LAYER_ORDER) do
            result[layer] = DRAW_LAYER_ORDER[max(1, rank - 1)]
        end
        return result
    end
    local LOWER_DRAW_LAYER = evalLowerDrawLayerMap()

    ---@param layer DrawLayer
    ---@return DrawLayer
    function lib.LowerDrawLayer(layer)
        return LOWER_DRAW_LAYER[layer]
    end
end

local _, ns = ...
ns.Util = lib
return lib
