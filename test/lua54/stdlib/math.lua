-- Test math library

-- Constants
assert(math.pi > 3.14 and math.pi < 3.15)
assert(math.huge > 0)
assert(math.huge == 1/0)
assert(math.mininteger < 0)
assert(math.maxinteger > 0)

-- Basic functions
assert(math.abs(-5) == 5)
assert(math.ceil(3.2) == 4)
assert(math.floor(3.8) == 3)
assert(math.max(1, 5, 3, 2) == 5)
assert(math.min(1, 5, 3, 2) == 1)
assert(math.sqrt(16) == 4)

-- Trigonometry
assert(math.sin(0) == 0)
assert(math.cos(0) == 1)
assert(math.tan(0) == 0)

-- Random numbers
math.randomseed(12345)
local r1 = math.random()  -- [0, 1)
local r2 = math.random(10)  -- 1 to 10
local r3 = math.random(5, 15)  -- 5 to 15