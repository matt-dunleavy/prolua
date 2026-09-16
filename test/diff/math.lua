-- math library, compared against the reference interpreter's own output

-- constants and subtypes
print(math.pi)
print(math.huge, -math.huge)
print(math.maxinteger, math.mininteger)
print(math.type(1), math.type(1.0), math.type("1"), math.type(nil))

-- rounding keeps the integer subtype where Lua does
print(math.floor(3.7), math.ceil(3.2), math.floor(-3.7), math.ceil(-3.2))
print(math.type(math.floor(3.7)), math.type(math.ceil(3.2)))
print(math.floor(3), math.type(math.floor(3)))
print(math.floor(2^60), math.type(math.floor(2 ^ 60)))

-- abs preserves subtype, and wraps at the integer minimum
print(math.abs(-5), math.abs(5), math.abs(-5.5))
print(math.type(math.abs(-5)), math.type(math.abs(-5.5)))
print(math.abs(math.mininteger))

-- max/min over several arguments
print(math.max(1, 2, 3), math.min(1, 2, 3))
print(math.max(1, 2.5), math.min(1, 2.5))
print(math.type(math.max(1, 2)), math.type(math.max(1, 2.0)))
print(math.max(5), math.min(5))

-- sqrt and friends
print(math.sqrt(16), math.sqrt(2))
print(math.exp(0), math.exp(1))
print(math.log(1), math.log(math.exp(1)))
print(math.log(8, 2), math.log(100, 10), math.log(1000, 10))
print(math.sin(0), math.cos(0))
print(string.format("%.6f %.6f", math.sin(math.pi / 2), math.tan(0)))
print(string.format("%.6f", math.asin(1)))
print(string.format("%.6f %.6f", math.acos(1), math.atan(1)))
print(string.format("%.6f", math.atan(1, 1)))
print(string.format("%.6f", math.atan(1, -1)))

-- fmod and modf
print(math.fmod(7, 3), math.fmod(-7, 3), math.fmod(7.5, 2))
print(math.type(math.fmod(7, 3)))
print(math.modf(3.7))
print(math.modf(-3.7))
print(math.modf(5))
print(math.type((math.modf(3.7))))

-- tointeger
print(math.tointeger(3.0), math.tointeger(3.5), math.tointeger("3"))
print(math.tointeger(2 ^ 53), math.tointeger("abc"))

-- ult compares as unsigned
print(math.ult(1, 2), math.ult(-1, 2), math.ult(2, -1))

-- random: only properties can be compared across implementations
math.randomseed(42)
local ok = true
for _ = 1, 200 do
  local r = math.random()
  if r < 0 or r >= 1 then ok = false end
end
print("random unit range:", ok)
ok = true
for _ = 1, 200 do
  local r = math.random(10)
  if r < 1 or r > 10 or math.type(r) ~= "integer" then ok = false end
end
print("random 1..10:", ok)
ok = true
for _ = 1, 200 do
  local r = math.random(5, 8)
  if r < 5 or r > 8 then ok = false end
end
print("random 5..8:", ok)
print("random(m,m):", math.random(3, 3))
print("random(0) is integer:", math.type(math.random(0)) == "integer")

-- errors
print(pcall(math.random, 5, 1))
print(pcall(math.fmod, 1, 0))
print(pcall(math.sqrt, "abc"))
print(pcall(math.floor))
print(pcall(math.max))
