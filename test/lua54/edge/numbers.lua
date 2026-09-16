-- Test special numeric values

local inf = math.huge
local neg_inf = -math.huge
local nan = 0/0

-- NaN comparisons
assert(nan ~= nan)
assert(not (nan == nan))
assert(not (nan < 1))
assert(not (nan > 1))
assert(not (nan <= 1))
assert(not (nan >= 1))

-- Infinity arithmetic
assert(inf + 1 == inf)
assert(inf * 2 == inf)
assert(inf / inf ~= inf / inf)  -- NaN
assert(1 / inf == 0)

-- Integer overflow
local max = math.maxinteger
local min = math.mininteger
-- These should wrap or convert to float
local overflow = max + 1
local underflow = min - 1