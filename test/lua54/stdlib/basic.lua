-- Test basic library functions

-- Type checking
assert(type(nil) == "nil")
assert(type(true) == "boolean")
assert(type(42) == "number")
assert(type("hello") == "string")
assert(type({}) == "table")
assert(type(print) == "function")

-- Conversions
assert(tonumber("42") == 42)
assert(tonumber("3.14") == 3.14)
assert(tonumber("0xFF") == 255)
assert(tonumber("invalid") == nil)
assert(tostring(42) == "42")
assert(tostring(true) == "true")

-- Assertions
assert(true, "This should not fail")
-- assert(false, "This should fail")

-- Error handling
local ok, err = pcall(function() error("test error") end)
assert(not ok)
assert(string.find(err, "test error"))

-- stdlib_tests/table.lua

