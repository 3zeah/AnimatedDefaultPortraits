local _, ns = ...

function ns.import(name)
    local result = ns[name]
    if result == nil then
        error(
            "ERROR: internal dependency \"" .. name .. "\" was not found during"
            .. " loading, probably due to previous loading errors"
        )
    end
    return result
end

function ns.GetDistanceSquared(xA, yA, xB, yB)
    return abs(xA - xB) ^ 2 + abs(yA - yB) ^ 2
end

do -- project id util
    local function setIfKeyExists(table, k, v)
        if k then
            table[k] = v
        end
    end

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

    ns.CLIENT_IS_CLASSIC = CLASSIC_RANK ~= nil

    function ns.ClientIsClassicBefore(projectId)
        return CLASSIC_RANK
            and CLASSIC_RANK < WOW_CLASSIC_PROJECT_ORDER[projectId]
    end
end

function ns.TextureIsPortrait(texture)
    return texture:GetTexture() == "RTPortrait1"
end

do -- frame strata util
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

    function ns.LeftStrataIsAboveRight(strataLhs, strataRhs)
        return FRAME_STRATA_GREATER_THAN_ORDERING[strataLhs][strataRhs] or false
    end
end

do -- draw layer util
    local DRAW_LAYER_ORDER = {
        "BACKGROUND",
        "BORDER",
        "ARTWORK",
        "OVERLAY",
        "HIGHLIGHT",
    }

    local function evalLowerDrawLayerMap()
        local result = {}
        for rank, layer in ipairs(DRAW_LAYER_ORDER) do
            result[layer] = DRAW_LAYER_ORDER[max(1, rank - 1)]
        end
        return result
    end
    local LOWER_DRAW_LAYER = evalLowerDrawLayerMap()

    function ns.LowerDrawLayer(layer)
        return LOWER_DRAW_LAYER[layer]
    end
end
