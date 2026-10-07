local _, ns = ...
---@module "Require"
local require = ns.require

---@module "Const"
local Const = require(ns, "Const")

local ModelFileId = Const.ModelFileId

-- the playlists below are defined such that each key defines the idle-animation
-- variation, and the value is the probability that it plays. the base
-- variation, 0, plays if nothing else. for example, { 2 = 5% } := animation
-- (0,0) plays 95% of the time, (0,1) 5%
---@alias AnimationVariantPlaylist { [integer]: number }

local NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST = {}
-- observed baseline variations: 40% 0, 40% 1, 5% 2, 5% 3
-- bad variation is 1: undead male leans away
-- to account for a very common variation being removed, the rare variations
-- are made a bit more common
local UD_MALE_IDLE_ANIMATION_PLAYLIST = {
    [2] = 0.075,
    [3] = 0.075,
}
-- observed baseline variations: 90% 0, 5% 1, 5% 2
-- bad variation is 1: undead female crouches
-- roll variation 1 into 2, as they are both "rare variations"
local UNDEAD_FEMALE_IDLE_ANIMATION_PLAYLIST = { [2] = 0.1 }
-- zombies have a 1/3 of each of 3 variation: just remove the bad one
local ZOMBIE_IDLE_ANIMATION_PLAYLIST = { [2] = 1 / 3 }
-- baseline variations: 90% 0, 5% 1, 2.5% 2, 2.5% 3
-- variations 1 and 2 are bad: very extended periods with head somewhere else
-- (add some probability to 3 to make up for removal of other variations)
local HEX_EAGLE_ANIMATION_PLAYLIST = { [3] = 0.05 }

-- the set of known model id:s where an idle variation is awkwardly off-camera,
-- mapped to a table of whitelisted idle variations with probability of playing
---@type { [ModelFileId]: AnimationVariantPlaylist? }
local ANIMATION_OVERRIDES = {
    [ModelFileId.UNDEAD_MALE] = UD_MALE_IDLE_ANIMATION_PLAYLIST,
    [ModelFileId.SKELETON_MALE] = UD_MALE_IDLE_ANIMATION_PLAYLIST,
    [ModelFileId.CRACK_ELF_MALE] = UD_MALE_IDLE_ANIMATION_PLAYLIST,
    [ModelFileId.UNDEAD_FEMALE] = UNDEAD_FEMALE_IDLE_ANIMATION_PLAYLIST,
    [ModelFileId.UNDEAD_FEMALE_HD] = UNDEAD_FEMALE_IDLE_ANIMATION_PLAYLIST,
    -- birds fly far up
    [ModelFileId.CARRION_BIRD] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.CARRION_BIRD_OUTLAND] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.EAGLE] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.UNDEAD_EAGLE] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.EAGLE2] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.EAGLE_PET] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.GIANT_EAGLE] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.VULTURE] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.VULTURE_MOUNT] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.SPOTTING_EAGLE] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    -- zombie turns away
    [ModelFileId.ZOMBIE] = ZOMBIE_IDLE_ANIMATION_PLAYLIST,
    [ModelFileId.ZOMBIE_ARM] = ZOMBIE_IDLE_ANIMATION_PLAYLIST,
    [ModelFileId.ZOMBIE2] = ZOMBIE_IDLE_ANIMATION_PLAYLIST,
    -- scorpion clips into the camera while yelling...
    [ModelFileId.SCORPION] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.HORDE_SCORPION] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.HORDE_SCORPION_MOUNT] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    -- this guy is all over the fucking place
    [ModelFileId.SUPER_ZOMBIE] = NO_IDLE_VARIATIONS_ANIMATION_PLAYLIST,
    [ModelFileId.MYTHIC_HEX_EAGLE_MOUNT] = HEX_EAGLE_ANIMATION_PLAYLIST,
    [ModelFileId.HEX_EAGLE] = HEX_EAGLE_ANIMATION_PLAYLIST,
}

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
---@class AnimationVariantBlacklisterLib
local lib = {}

---attach to the given player model to play its idle animation, but preventing
---blacklisted idle-animation variants from playing. this otherwise preserves
---the baseline idle-animation behavior of cycling between different variations
---@param model PlayerModel
---@return AnimationVariantBlacklister
function lib.Create(model)
    ---@class (exact) AnimationVariantBlacklister
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

---@param state AnimationVariantBlacklister
---@param model PlayerModel
function lib.UpdateAfterModelChanged(state, model)
    local animationPlaylist = ANIMATION_OVERRIDES[model:GetModelFileID()]
    if animationPlaylist then
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

ns.AnimationVariantBlacklister = lib
return lib
