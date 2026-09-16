-- Test expression parsing and precedence

-- Arithmetic precedence
local a = 1 + 2 * 3  -- 7, not 9
local b = (1 + 2) * 3  -- 9
local c = 2 ^ 3 ^ 2  -- 512 (right associative)
local d = 2 ^ (3 ^ 2)  -- 512
local e = (2 ^ 3) ^ 2  -- 64

-- Logical precedence
local x = true or false and false  -- true
local y = (true or false) and false  -- false
local z = not true or true  -- true

-- Comparison chains
local same = 1 < 2 and 2 < 3  -- can't chain comparisons directly

-- String concatenation (right associative)
local s = "a" .. "b" .. "c"  -- "abc"

-- Mixed operations
local complex = 1 + 2 * 3 ^ 2 .. " result"

-- parser_tests/errors.lua
-- Test parser error recovery

-- Missing 'then'
--[[ Should error:
if true
  print("missing then")
end
]]

-- Missing 'end'
--[[ Should error:
if true then
  print("missing end")
]]

-- Invalid assignment target
--[[ Should error:
1 = 2
"string" = 3
nil = 4
]]

-- Break outside loop
--[[ Should error:
break
]]