-- Test error generation and messages

-- Uncomment to test error messages:
--[[
-- Syntax errors
if then end  -- missing condition
function end  -- missing name
local 123 = 5  -- invalid name
x = = 5  -- double equals

-- Runtime errors
local t = {}
t.nonexistent.field  -- index nil
t + 5  -- invalid arithmetic
#true  -- length of boolean
pairs(5)  -- pairs on number

-- Type errors
"string" + 5
true[1]
(function() end)[1] = 5
]]