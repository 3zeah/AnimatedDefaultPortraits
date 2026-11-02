---project constants
---@class Const
local lib = {}

---@enum MaskShape
lib.MaskShape = {
    -- reference texture: 130924
    -- ([`TEMP_PORTRAIT_ALPHA_MASK`](lua://TextureFileId.TEMP_PORTRAIT_ALPHA_MASK))
    CIRCLE = 0,
    -- reference texture: 3605349
    -- ([`CIRCLE_MASK_SCALABLE`](lua://TextureFileId.CIRCLE_MASK_SCALABLE))
    SMALLER_CIRCLE = 1,
    -- reference texture: 4682541
    -- ([`UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK`](lua://TextureFileId.UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK))
    MAINLINE_PLAYER_PORTRAIT = 2,
}

---@enum ModelFileId
lib.ModelFileId = {
    -- Interface/Buttons/TalkToMe_Gears.M2
    TALK_TO_ME_GEARS = 587744,
}

---@enum TextureFileId
lib.TextureFileId = {
    -- interface/characterframe/tempportraitalphamask.blp
    TEMP_PORTRAIT_ALPHA_MASK = 130924,
    -- interface/characterframe/tempportraitalphamasksmall.blp
    TEMP_PORTRAIT_ALPHA_MASK_SMALL = 130925,
    -- interface/masks/circlemask.blp
    CIRCLE_MASK = 3528314,
    -- interface/masks/circlemaskscalable.blp
    CIRCLE_MASK_SCALABLE = 3605349,
    -- interface/talentframe/talentsmasknodecircle.blp
    TALENTS_MASK_NODE_CIRCLE = 4633068,
    -- interface/hud/uiunitframeplayerportraitmask.blp
    UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK = 4682541,
    -- interface/hud/uiunitframeplayerportraitmask2x.blp
    UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK_2X = 5321198,
    -- interface/common/commonmaskcircle.blp
    COMMON_MASK_CIRCLE = 5757702,
    -- interface/hud/uiunitframeplayerportraitmask2xc60.blp
    UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK_2X_C60 = 8524951,
    -- interface/hud/uiunitframeplayerportraitmaskc60.blp
    UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK_C60 = 8524953,
}

---@enum NpcId
lib.CreatureId = {
    MANNEQUIN = 185672,
    LIFELIKE_DOLL = 191463,
    MANNEQUIN_IN_DORNOGAL = 220968,
    MANNEQUIN_IN_DORNOGAL_2 = 235262,
    MANNEQUIN_IN_DORNOGAL_3 = 235263,
    MANNEQUIN_IN_DORNOGAL_4 = 235264,
    MANNEQUIN_IN_DUN_MOROGH = 241047,
    MANNEQUIN_IN_DUROTAR = 241289,
    MIDSUMMER_MANNEQUIN = 267833,
    MANNEQUIN_IN_SILVERMOON_CITY = 268179,
    MANNEQUIN_IN_SILVERMOON_CITY_2 = 268195,
    MANNEQUIN_IN_SILVERMOON_CITY_3 = 268199,
}

local _, ns = ...
ns.Const = lib
return lib
