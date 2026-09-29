# Animated Default Portraits

World of Warcraft add-on. Animate the default unit-frame portraits with minimal side effects and without user configuration. The animated portraits are otherwise indistinguishable from the baseline portraits. Supports all clients: both mainline and classic.

## Limitations

* Only one portrait is animated if two are very close together. Custom UI layouts may have to be adapted for optimal results
    - Technical limitation by Blizzard: UI models occlude each other when intersecting
* Compatibility not guaranteed (but possible) with add-ons that alter unit frames or other portrait frames

## Dev

### Technical details

#### Background

Traditional texture masking may not be applied to models in the UI (`Model` or `ModelScene`). This is why other add-ons elect either to alter portrait containers to be rectangular, or to inscribe portaits within the circle beneath some visual smoothing. Either solution alters the look of the UI beyond simply animating the portraits.

#### Solution

This add-on leverages a quirk in the UI model renderer to apply a circular mask to its animated-portrait models. Put briefly, a frame-widget model _A_ will appear to participate in the occlusion of frame-widget model _B_, although _A_ is below _B_ in frame space (eg, _A_ has lower frame level), as long as _B_ is deeper than _A_ in 3D-camera space (ie, _A_ is closer to its camera).

Given a portrait model, this add-on creates another model frame, the "mask model," and places it below the portrait frame. This mask model is set to some model with a small circular hole and zoomed in heavily to ensure it is nearer all parts of all possible portrait models wrt camera space. The mask model is then made imperceptibly transparent. In conclusion, the portrait model is effectively rendered through a circular hole.

This quirk may not have been present in the original classic client, and also feels fragile, but, for now, it works. The quirk is observed in all present clients: 1509, 20506, 50504, and 120100.

##### Observations

1. If model _A_ is above model _B_ in frame space, the rasterized _A_ will blend over the rasterized _B_
2. If model _A_ is below model _B_ in frame space, _A_ will participate in the occlusion of _B_ such that any part of _B_ that would be occluded by _A_ - were they rendered by the same camera - is not rendered
3. The occlusion-clipping effect above is with respect to the shared camera space: moving one model camera _X_ units deeper is effectively negated by moving the corresponding model _X_ camera-units closer (ie, the position of either camera does not matter whatsoever, only how close each model is to its camera)

##### Corollary limitations

By observation 3, there is no known way to circumvent that two models may interfere with each other when intersecting, without altering the look of the model. This is the only significant limitation of this add-on. Were it resolved, portraits could be placed arbitrarily close together, or even made to overlap.

* It is possible to alter camera distance and offset the perceived distance with frame-view insets, but this will necessarily alter the perspective of the model
* It is possible to alter camera distance and offset the zoom by scaling the model, but this does not play nice with particles
    - Fails the skeletal warhorse test: creature with display id 10720 shuld amass background glow
* Another problem with trying to scale the model is that frustum clipping becomes an issue. It is possible with `ModelScene` (instead of `PlayerModel`) explicitly to set the clipping planes, but `ModelScene` does not work properly (as far as I can tell...)
    - `ModelScene` has a baseline ambient light, at zero configured lighting, that is brighter than the portrait lighting
    - `ModelScene` apparently cannot display textured non-players without providing the display ID (all we have is unit token)
    - `ModelScene` does not have `SetPortraitZoom`, and its camera space apparently does not correspond to `PlayerModel` camera space, so even using a hidden reference model is laborious (maybe not impossible, though)

### Systems configuration

Look to configure one of these extant systems if something looks off. Otherwise, the issue is novel.

#### Portrait-mask support

Although most portrait textures are circular out of the box, they often also have texture masks. Support must be explicitly configured for each type of mask texture (eg the main-line player portrait, which has one rectangular corner but is otherwise circular): configure new ones when encountered.

#### Model-occlusion workaround

Because other UI models may overlap with user-placed unit-frame portraits, animated portraits are temporarily disabled when intersecting with other models (eg the character-frame model). But each potentially-intersecting UI model must be explicitly registered: register new ones when encountered.

#### Clipping-model workaround

Some animations of some models may clip out of the model-mask occlusion space, by bringing parts very close to the camera (eg scorpid waving claws). This results in parts of the portrait model rendering outside of its container. The workaround is to alter the model scale: configure new ones when encountered.

#### Unfilmable animation blacklist

Some animation variants of some models are blacklisted, because they bring the model off-frame (eg classic ud males when they stand upright): configure new ones when encountered.

Unfortunately, "blacklisting" animation variants actually requires simulating the Blizzard animation-variant system, by rolling for a new, whitelisted animation variant whenever the previous finished. Thus, the probability must be estimated of each whitelisted animation variant, based on observations of baseline behavior.

#### Disabling animations per portrait

This is unfortunately a necessarily opinionated stylistic judgement, but there are, to me, some obvious examples of portraits that should not be animated, chiefly the "micro button", which opens the character frame (eg target-of-target portraits are not animated because they are relatively visually insignificant)

### Testing

Use the `dev` branch and ensure it is rebased on main, or on whatever changes you are testing. The `dev` branch comprises dev functions as well as some debug printing. In particular, a typical appearance test will first run `AdpPose()` to freeze the animated portraits to their baseline pose, followed by `AdpToggle()` repeatedly to toggle the animated portraits with the baseline ones. Another useful call is `Adp()` which returns the animated target-frame model, for comfortable in-game scripting experiments.

#### Test expectations

For each new client (or for all clients if some client actually regressed: several behaviors actually change per client, not per Classic vs Mainline)

* The portrait lighting and background color match baseline
    - Test: `AdpPose();AdpFrameTex()` -> repeat `AdpToggle()`
* The circular portrait-model mask tightly inscribes circular portrait textures without a mask texture
    - Test: `AdpFrameTex();AdpShowMask()` -> repeat `AdpToggle()` and or `AdpShowMask()`
    - Circular texture edges are subject to blurring and anti-aliasing: ensure that the opaque pixels are inscribed
* The portrait-model mask is aligned with the mask texture of portraits that have one
    - Test: same as above

For each new or updated type of portrait

* The portrait model does not peek out from portrait-container frames (eg the unit-frame texture frames)
    - Test: `AdpFrameTex()`, or otherwise hiding Blizzard UI elements, may help to identify close calls
* The portrait model is not incorrectly layered: it is behind foreground textures and above background textures, wrt the baseline portrait
    - Test: `AdpToggle()`

Other considerations

* Intersecting portraits should not occlude each other: the more important portrait should remain animated
    - Test: edit mode
    - Give extra consideration to special shapes such as the mainline player frame
* UI scale or edit-mode scaling should induce no visual changes
    - Test: edit mode and or UI-scale graphics setting
* Portraits that have their opacity altered or become tinted should become so even when animated, and this should look as identical as possible
    - Test: the only known example is low-health units in classc, for the target, focus and party frames

### Known unit portraits

Each applies to all clients unless otherwise stated.

* Unit frames
    - Player
    - Pet
    - Target
    - Target of target
    - Large focus
    - Small focus
    - Target of focus
    - Party frames
    - Party pets
* Corner of NPC-dialogue frames
    - Regular dialogue (gossip frame)
    - Quest-description dialogue
    - Merchant
    - Bank
    - Class/professions/skill trainer
    - Pet-stable
    - Flight-point selection (classic)
    - Tabard design (guild master: "I want to create a guild crest.")
    - Guild registration (guild master: "How do I form a guild?")
    - Guild-rename prompt
* Character "micro button" (the button that opens the character frame)
* Character frame corner: all tabs
* Character-stats button in character frame (cata+)
* Talent frame corner
* Dress-up frame corner (ctrl-click item preview)
* Auction-house frame corner
* Profession-crafting frame corner
    - In classic, both `TradeSkillFrame` (eg First Aid) and `CraftFrame` (eg Enchanting), because do not ask me the difference
* Inspect frame corner
* Trade frame, player and recipient
    - Mainline: `/run ShowUIPanel(TradeFrame, 1);SetPortraitTexture(TradeFramePortrait, "player");SetPortraitTexture(TradeFrame.RecipientOverlay.portrait, "target")`
    - Classic: `/run ShowUIPanel(TradeFrame, 1);SetPortraitTexture(TradeFramePlayerPortrait,"player");SetPortraitTexture(TradeFrameRecipientPortrait, "target")`
* Achievement-comparison target header (wrath+)
* Ready-check alert corner (`/run ShowReadyCheck("target")`)

#### IDK

Identified in source code but not confirmed or properly tested

* `BarberShopAlternateFormTopPortrait` / `BarberShopAlternateFormBottomPortrait` (classic)
* Some "challenge-mode" party frames (via `ChallengeModeBannerPartyMemberMixin`): something about mythic+?
* Voice activity notification? (via `VoiceActivityNotificationMixin`)
* Party sync participants? (via `QuestSessionMemberMixin`)
* `GarrisonRecruiterFrame.PortraitTexture`
* `ItemInteractionFrame.PortraitContainer.portrait`
* Party-member super-tracking??? (via `SuperTrackedFrameMixin`)
* `GarrisonCapacityDisplayFrame.PortraitContainer.portrait`
* `OrderHallTalentFrame.PortraitContainer.portrait`
* `ProfessionsCustomerOders.PortraitContainer.portrait`
