-- Test all operators
local a, b = 1, 2
local arithmetic = a + b - a * b / a % b ^ a // b
local relational = a < b and a > b or a <= b or a >= b or a == b or a ~= b
local logical = not a and b or a
local bitwise = a & b | a ~ b << a >> b
local concat = "hello" .. "world"
local len = #"test"
local t = {field = 1}
local access = t.field
local index = t["field"]