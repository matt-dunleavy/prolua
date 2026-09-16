-- Integer arithmetic and numeric for loops at the boundary of the 48-bit
-- inline integer range: the interpreter encodes small integers inline and
-- boxes the rest, and a loop's step is kept inline only when its initial
-- value and its count are. The reference has one integer representation,
-- so every line must agree.

local lim = 1 << 47

-- loops that start, end or cross the inline boundary
for i = lim - 3, lim + 2 do io.write(i, " ") end print()
for i = lim - 2, lim + 4, 3 do io.write(i, " ") end print()
for i = -lim + 2, -lim - 3, -1 do io.write(i, " ") end print()
for i = -lim - 2, -lim + 2, 2 do io.write(i, " ") end print()
for i = lim + 5, lim + 1, -2 do io.write(i, " ") end print()

-- the extremes, where the count is small but the values are boxed
for i = math.maxinteger - 2, math.maxinteger do io.write(i, " ") end print()
for i = math.mininteger, math.mininteger + 2 do io.write(i, " ") end print()
for i = math.maxinteger, math.maxinteger - 2, -1 do io.write(i, " ") end print()

-- a count beyond the inline range, left early
local n = 0
for i = 1, math.maxinteger do n = n + 1; if n == 4 then io.write(i, " "); break end end print()
for i = math.mininteger, math.maxinteger, 1 << 40 do n = n + 1; if n == 7 then io.write(i, " "); break end end print()

-- the index crosses the boundary in the middle of a loop
local s = 0
for i = lim - 5, lim + 5 do s = s + i end print(s)
for i = -lim + 5, -lim - 5, -1 do s = s - i end print(s)

-- add and subtract on the encoded words, crossing the boundary both ways
local a, b = lim - 1, 1
print(a + b, a + b - b, -a - b - 1, -a - b - 1 + 1)
print(lim - 1 + 1, -lim - 1, (-lim) - 1 + 1, lim + lim, -lim - lim)
print(a + 3, a - (-3), b - a, (b - a) - 3)
local big = lim * 4
print(big + 1, big - 1, big + big, -big + big, big - big)
print(a * 2, a * 2 - a, -a * 2, a * a, (a * a) // a, -a * -a)
print(3 + a, 3 - a, a % 7, (a + 3) % 7, (-a - 3) % 7, big % 7)
print(a + 1 == lim, a + 1 - 1 == a, -lim - 1 == math.tointeger(-lim - 1))
print(math.maxinteger + 1 == math.mininteger, math.mininteger - 1 == math.maxinteger)
print(math.maxinteger * 2, math.mininteger * 2, math.maxinteger * math.maxinteger)

-- immediates and constants at the boundary
local x = lim - 1
print(x + 1, x + 2, x - (-1), x + 100, x - 100)
x = -lim
print(x - 1, x - 2, x + 1, x - 100, x + 100)
print(x * 1, x * -1, (x + 1) * -1, x // -1, x % -1)
