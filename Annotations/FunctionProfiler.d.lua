---@meta _

---@class NumyFunctionProfiler
NumyFunctionProfiler = {}

--- @generic T: fun(...): ...
--- @param owner string
--- @param obj string?
--- @param name string
--- @param func T
--- @return T
function NumyFunctionProfiler:Wrap(owner, obj, name, func) end

--- @param owner string
--- @param objectName string
--- @param object table
--- @param funcName string
function NumyFunctionProfiler:WrapInPlace(owner, objectName, object, funcName) end

--- @param owner string
--- @param currName string?
--- @param module table
--- @param maxDepth number? max recursion depth, defaults to 1
--- @param currentDepth number? current recursion depth, should not be set
function NumyFunctionProfiler:WrapModules(owner, currName, module, maxDepth, currentDepth) end
