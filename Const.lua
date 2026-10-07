---project constants
---@class Const
local lib = {}

---@enum MaskShape
lib.MaskShape = {
    CIRCLE = 0,
    MAINLINE_PLAYER_PORTRAIT = 1,
}

---@enum ModelFileId
lib.ModelFileId = {
    -- character/scourge/female/scourgefemale.m2
    UNDEAD_FEMALE = 121608,
    -- character/scourge/male/scourgemale.m2
    UNDEAD_MALE = 121768,
    -- character/skeleton/male/skeletonmale.m2
    SKELETON_MALE = 121942,
    -- creature/carrionbird/carrionbird.m2
    CARRION_BIRD = 123137,
    -- creature/carrionbirdoutland/carrionbirdoutland.m2
    CARRION_BIRD_OUTLAND = 123148,
    -- creature/crackelf/crackelfmale.m2
    CRACK_ELF_MALE = 123299,
    -- creature/eagle/eagle.m2
    EAGLE = 123715,
    -- creature/scorpion/scorpion.m2
    SCORPION = 125815,
    -- creature/superzombie/superzombie.m2
    SUPER_ZOMBIE = 126101,
    -- creature/undead_eagle/undead_eagle.m2
    UNDEAD_EAGLE = 126300,
    -- creature/zombie/zombie.m2
    ZOMBIE = 126570,
    -- creature/zombie/zombiearm.m2
    ZOMBIE_ARM = 126571,
    -- creature/hordescorpionmount/hordescorpion.m2
    HORDE_SCORPION = 461265,
    -- creature/hordescorpionmount/hordescorpionmount.m2
    HORDE_SCORPION_MOUNT = 463776,
    -- Interface/Buttons/TalkToMe_Gears.M2
    TALK_TO_ME_GEARS = 587744,
    -- character/scourge/female/scourgefemale_hd.m2
    UNDEAD_FEMALE_HD = 997378,
    -- creature/eagle2/eagle2.m2
    EAGLE2 = 1100483,
    -- creature/eagle2/eaglepet.m2
    EAGLE_PET = 1100485,
    -- creature/gianteagle/gianteagle.m2
    GIANT_EAGLE = 1375465,
    -- creature/vulture/vulture.m2
    VULTURE = 1661349,
    -- creature/zombie2/zombie2.m2
    ZOMBIE2 = 1888300,
    -- creature/vulturemount/vulturemount.m2
    VULTURE_MOUNT = 1926505,
    -- creature/spottingeagle/spottingeagle.m2
    SPOTTING_EAGLE = 6367105,
}

---@enum TextureFileId
lib.TextureFileId = {
    -- interface/characterframe/tempportraitalphamask.blp
    TEMP_PORTRAIT_ALPHA_MASK = 130924,
    -- interface/masks/circlemask.blp
    CIRCLE_MASK = 3528314,
    -- interface/hud/uiunitframeplayerportraitmask.blp
    UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK = 4682541,
    -- interface/hud/uiunitframeplayerportraitmask2x.blp
    UI_UNIT_FRAME_PLAYER_PORTRAIT_MASK_2X = 5321198,
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
