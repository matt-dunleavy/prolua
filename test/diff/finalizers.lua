-- finalizer frames and errors: debug.getinfo inside __gc, warnings for
-- errors in __gc, and finalizers at close
warn("@on")
local seen
setmetatable({}, { __gc = function()
  local t = debug.getinfo(1)
  seen = t.namewhat .. "/" .. tostring(t.name) .. "/" .. t.what
end })
collectgarbage()
print(seen)
setmetatable({}, { __gc = function() error("boom in gc") end })
collectgarbage()
setmetatable({}, { __gc = function() error({}) end })
collectgarbage()
setmetatable({}, { __gc = function() error("no position", 0) end })
collectgarbage()
print("after")
-- finalizers see their object intact, and run for objects alive at close
local T = setmetatable({ x = 1 }, { __gc = function(o) print("closing", o.x) end })
T.x = 2
