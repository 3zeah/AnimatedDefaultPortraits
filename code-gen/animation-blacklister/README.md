# animation-blacklister

THIS IS A PROTOTYPE: MAINTAINING THE ANIMATION BLACKLIST IS STILL LABORIOUS, AND GETTING THIS SYSTEM TO RUN IS NON-TRIVIAL, BECAUSE IT IS HARDCODED FOR MY CURRENT WORKSPACE

comprising the most amount imaginable of system complexity relative its feature footprint, this is a code generator leveraging data mining to automate finding animations to blacklist for the animated default portraits add-on

## background

in animated portraits, the model is in its idle animation, which typically has several variations, chosen at random. certain variations bring certain models off frame. this is not the end of the world, but it is not optimal. world of warcraft provides no known way of blacklisting variations or even detecting which variation is playing.

## solution

maintain "animation playlists" for certain models, and blacklist variations from those, instead. an animation playlist is a list of animation variations along with a probability of playing. the add-on can thus simulate the baseline behavior by explicitly playing variations instead of relying on the automatic variation variety.


these playlists are constructed by data mining. given a list of blacklisted animation variations by model and product (eg, classic vs standard, since models differ between them), this system will parse the real variations, and their probabilities, from the actual model file in actual world of warcraft storage, and simply remove the bad ones along with adjusting the remaining probabilities.

## build

yes, this should all be automated

* you must provide a built [CascLib](https://github.com/ladislav-zezula/CascLib) dll, and ensure it is linked
    - like, just put it in _target/debug_
* you must fiddle with [build.rs of the CascLib wrapper](crates/casc-lib/build.rs)
    - point it to a [CascLib](https://github.com/ladislav-zezula/CascLib) build directory, also, for some reason...
    - point out the [CascLib](https://github.com/ladislav-zezula/CascLib) header locally for `bindgen`
* ensure `bindgen` requirements are satisfied (clang...): https://rust-lang.github.io/rust-bindgen/requirements.html

## run

* debug solution and animation comparisons with [wow-skeleton-render](crates/wow-skeleton-render/src/main.rs)
    - this renders the model and animation skeletons of given models
    - configured in [config.ron](config.ron) and [wow-skeleton-render/config.ron](crates/wow-skeleton-render/config.ron) (in particular, links wow installation location)
* generate blacklister code for add-on with [main module](src/main.rs)
    - this sucks up explicitly blacklisted animations from config and applies them also to similar animations for any other model
    - configured in [config.ron](config.ron) (in particular, links wow installation location)

when running main, there may be information logged regarding models and animations in world of warcraft that were similar to, but not deemed the same as, any of the blacklisted animations. these need to be manually investigated. [wow-skeleton-render](crates/wow-skeleton-render/src/main.rs) allows comparing the skeleton or animations of specific models without having to re-run the full main analysis, which reads ALL world of warcraft models
