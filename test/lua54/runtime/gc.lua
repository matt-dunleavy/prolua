-- Test garbage collection

-- Weak tables
local weak_keys = setmetatable({}, {__mode = "k"})
local weak_values = setmetatable({}, {__mode = "v"})
local weak_both = setmetatable({}, {__mode = "kv"})

local key = {}
local value = {}

weak_keys[key] = value
weak_values[key] = value
weak_both[key] = value

-- Force collection
collectgarbage()

-- Test finalizers
local finalized = false
local obj = setmetatable({}, {
  __gc = function()
    finalized = true
  end
})
obj = nil
collectgarbage()
assert(finalized)