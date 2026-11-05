local _, ns = ...

---@module "Require"
local require = ns.require

-- animation playlists per model file id
---@type { [integer]: AnimationVariantPlaylist? }
local ANIMATION_OVERRIDES = require(ns, "ANIMATION_OVERRIDES")

-- the playlists are defined such that each key defines the idle-animation
-- variation, and the value is the probability that it plays. the base
-- variation, 0, plays if nothing else. for example, { 2 = 5% } := animation
-- (0,0) plays 95% of the time, (0,1) 5%
---@alias AnimationVariantPlaylist { [integer]: number? }

local function rollIdleAnimationVariation(playlist)
    if next(playlist) == nil then
        return 0
    end
    local rng = fastrandom()
    local total_p = 0
    for variation, p in pairs(playlist) do
        total_p = total_p + p
        if rng < total_p then
            return variation
        end
    end
    return 0
end

---animated portraits play the generic idle animation, which typically cycles
---between several animation variants. this system is responsible for ensuring
---that no variation plays that places the model outside of the portrait
---viewport
---
---this library is internally configured: the list of blacklisted animation
---variants is maintained directly in this system
---@class AnimationBlacklisterLib
local lib = {}

---attach to the given player model to play its idle animation, but preventing
---blacklisted idle-animation variants from playing. this otherwise preserves
---the baseline idle-animation behavior of cycling between different variations
---@param model PlayerModel
---@return AnimationBlacklister
function lib.Create(model)
    ---@class (exact) AnimationBlacklister
    ---@field package playlist AnimationVariantPlaylist
    ---@field package nextVariation integer?
    local state = {}
    model:SetScript("OnAnimFinished", function(self)
        local playlist = state.playlist
        if not playlist then
            return
        end
        local nextVariation = state.nextVariation
        if not nextVariation then
            return
        end
        state.nextVariation = rollIdleAnimationVariation(playlist)
        self:SetAnimation(0, nextVariation)
    end)
    return state
end

---@param state AnimationBlacklister
---@param model PlayerModel
function lib.UpdateAfterModelChanged(state, model)
    local animationPlaylist = ANIMATION_OVERRIDES[model:GetModelFileID()]
    if animationPlaylist then
        if animationPlaylist ~= state.playlist then
            if next(animationPlaylist) == nil then
                print(
                    "info: AnimationBlacklister: setting empty playlist for model",
                    AdpNamedParent(model):GetName()
                )
            else
                print(
                    "info: AnimationBlacklister: setting playlist for model",
                    AdpNamedParent(model):GetName() .. ":"
                )
                for variation_id, probability in pairs(animationPlaylist) do
                    print(" *", variation_id .. ":", tostring(probability * 100) .. "%")
                end
            end
        end
        state.playlist = animationPlaylist
        state.nextVariation = rollIdleAnimationVariation(animationPlaylist)
        -- any time the model-unit is refreshed, it appears the model
        -- unavoidably starts a new animation: immediately start a whitelisted
        -- variation instead
        model:SetAnimation(0, rollIdleAnimationVariation(animationPlaylist))
    else
        state.playlist = nil
        state.nextVariation = nil
    end
end

ns.AnimationBlacklister = lib
return lib
