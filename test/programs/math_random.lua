-- Lua 5.4: math.random / math.randomseed
-- randomseed takes one or two integers and returns them. The generator is
-- xoshiro256**. math.random() is a float in [0, 1); math.random(0) is a
-- full-width integer; math.random(m, n) is uniform in that inclusive range.

print("=== randomseed: returns the two seed components ===")
do
  local x, y = math.randomseed(1007, 0)
  print(x, y)
  x, y = math.randomseed(1007)
  print(x, y)
end

print("=== random: known sequence after seed 1007 ===")
do
  math.randomseed(1007, 0)
  print(math.random(0))
  math.randomseed(1007, 0)
  print(string.format("%.16a", math.random()))
end

print("=== randomseed: restoring the returned seeds repeats the state ===")
do
  local x, y = math.randomseed(42, 99)
  local a = math.random(0)
  local b = math.random(1, 1000)
  local c = math.random()
  math.randomseed(x, y)
  print(math.random(0) == a, math.random(1, 1000) == b, math.random() == c)
end

print("=== random: ranges ===")
do
  math.randomseed(1, 2)
  local r = math.random()
  print(math.type(r), r >= 0, r < 1)
  local n = math.random(10)
  print(math.type(n), n >= 1, n <= 10)
  local m = math.random(5, 8)
  print(math.type(m), m >= 5, m <= 8)
  local z = math.random(0)
  print(math.type(z))
  print(math.random(-2, -2))
end

print("=== random: errors ===")
do
  local ok, err = pcall(math.random, 5, 1)
  print(ok, (err or ""):match("interval is empty"))
  ok, err = pcall(math.random, 1, 2, 3)
  print(ok, (err or ""):match("wrong number of arguments"))
  ok, err = pcall(math.random, 1.5)
  print(ok, (err or ""):match("number has no integer representation") or (err or ""):match("integer"))
end

print("ok")
