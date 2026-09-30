---return the module by the given name from the add-on namespace, or crash if it
---does not exist
---
---### purpose
---* dependent modules will not load if any of its dependencies did not load,
---avoiding unforeseen errors at runtime, or unrecoverable error loops that hang
---the game
---* facilitate pattern of leveraging `@meta` annotations to link modules for
---the benefit of the lua language server
---
---### example usage
---```lua
---local _, ns = ...
------@module "Require"
---local require = ns.require
---
------@module "Util"
---local Util = require(ns, "Util")
---```
---@param namespace any
---@param name string
local function require(namespace, name)
    local result = namespace[name]
    if result == nil then
        error(
            "ERROR: internal module \"" .. name .. "\" was not found during"
            .. " loading, probably due to a previous error"
        )
    end
    return result
end

local _, ns = ...
ns.require = require
-- this does not do anything in world of warcraft, because `require` is not
-- available, but this paired with a `@module` annotation simulates a require to
-- the language server. there is an example of this pattern in the doc above,
-- for `require`
return require
