-- Test table constructors

-- Empty table
local t1 = {}

-- Array-style
local t2 = {1, 2, 3, 4, 5}

-- Record-style
local t3 = {
  name = "John",
  age = 30,
  active = true
}

-- Mixed style
local t4 = {
  "first",
  "second",
  key = "value",
  ["computed" .. "key"] = 42,
  [1.5] = "float key",
  [true] = "bool key",
  [{}] = "table key"
}

-- Nested tables
local t5 = {
  {1, 2, 3},
  {4, 5, 6},
  matrix = {
    {1, 0},
    {0, 1}
  }
}

-- Function values
local t6 = {
  add = function(a, b) return a + b end,
  sub = function(a, b) return a - b end
}

-- Trailing comma
local t7 = {
  1,
  2,
  3,
}