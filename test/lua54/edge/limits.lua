-- Test various limits and edge cases

-- Table limits
local big_table = {}
for i = 1, 10000 do
  big_table[i] = i
end

-- String limits
local long_string = string.rep("a", 1000)

-- Deep nesting
local deep = {{{{{{{{{{}}}}}}}}}}

-- Many locals
local function many_locals()
  local a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 = 1,2,3,4,5,6,7,8,9,10
  local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10 = 1,2,3,4,5,6,7,8,9,10
  -- ... up to 200 locals
end

-- Deep recursion
local function deep_recursion(n)
  if n <= 0 then return 0 end
  return 1 + deep_recursion(n - 1)
end
-- deep_recursion(1000)  -- May hit stack limit