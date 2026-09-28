# Animated Default Portraits

World of Warcraft add-on. Animate the default unit-frame portraits with minimal side effects. Apart from being animated, the portraits are otherwise indistinguishable from the baseline portraits. Supports all clients: both mainline and classic.

## Limitations

* Only one portrait is animated if two are very close together. Custom UI layouts may have to be adapted for optimal results
    - Technical limitation by Blizzard: UI models occlude each other when intersecting
* Compatibility not guaranteed (but possible) with add-ons that alter unit frames or other portrait frames

## Technical details

### Background

Traditional texture masking may not be applied to models in the UI (`ModelFrame` or `ModelScene`). This is why other add-ons elect either to alter portrait containers to be rectangular, or to inscribe portaits within the circle beneath some visual smoothing. Either solution alters the look of the UI beyond simply animating the portraits.

### Solution

This add-on leverages a quirk in the UI model renderer to apply a circular mask to its animated-portrait models. Put briefly, a frame-widget model _A_ will appear to participate in the occlusion of frame-widget model B, although _A_ is below _B_ in frame space (eg, _A_ has lower frame level), as long as _B_ is deeper than _A_ in 3D-camera space (ie, _A_ is closer to its camera).

Given a portrait model, this add-on creates another model frame, the "mask model," and places it below the portrait frame. This mask model is set to some model with a small circular hole and zoomed in heavily to ensure it is nearer all parts of all possible portrait models wrt camera space. The mask model is then made imperceptibly transparent. In conclusion, the portrait model is effectively rendered through a circular hole.

This quirk may not have been present in the original classic client, and also feels fragile, but, for now, it works. The quirk is observed in all present clients: 1509, 20506, 50504, and 120100.

#### Observations

1. If model _A_ is above model _B_ in frame space, the rasterized _A_ will blend over the rasterized _B_
2. If model _A_ is below model _B_ in frame space, _A_ will participate in the occlusion of _B_ such that any part of _B_ that would be occluded by _A_ - were they rendered by the same camera - is not rendered
3. The occlusion-clipping effect above is with respect to the shared camera space: moving one model camera _X_ units deeper is effectively negated by moving the corresponding model _X_ camera-units closer (ie, the position of either camera does not matter whatsoever, only how close each model is to its camera)

#### Corollary limitations

By observation 3, there is no known way to circumvent that two models may interfere with each other when intersecting, without altering the look of the model.

The above is the only significant limitation of this add-on. Were it resolved, portraits could be placed arbitrarily close together, or even made to overlap.

* It is possible to alter camera distance and offset the perceived distance with frame-view insets, but this will necessarily alter the perspective of the model
* It is possible to alter camera distance and offset the zoom by scaling the model, but this does not play nice with particles
    - Fails the skeletal warhorse test: creature with display id 10720 shuld amass background glow
* Another problem with trying to scale the model is that frustum clipping becomes an issue. It is possible with `ModelScene` (instead of `PlayerModel`) explicitly to set the clipping planes, but `ModelScene` does not work properly (as far as I can tell...)
    - `ModelScene` has a baseline ambient light, at zero configured lighting, that is brighter than the portrait lighting
    - `ModelScene` apparently cannot display textured non-players without providing the display ID (all we have is unit token)
    - `ModelScene` does not have `SetPortraitZoom`, and its camera space apparently does not correspond to `PlayerModel` camera space, so even using a hidden reference model is laborious (maybe not impossible, though)
