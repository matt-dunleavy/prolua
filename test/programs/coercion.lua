-- Lua 5.4: string arithmetic vs missing VM coercion
-- The VM no longer coerces strings to numbers. Numeral strings still add
-- through the string metatable. Bitwise ops do not coerce strings.
-- Mixed number/string order comparisons remain errors.

print("=== coercion: numeral strings still arithmetic via the string mt ===")
print("10" + 5, 5 + "10", "2" * "3.5")
print("10" - 1, "9" / "3", "10" // "3", "10" % 3)
print(-"10", "2" ^ 3)
print(math.type("10" + 5), math.type("10" + 5.0), math.type("10.0" + 5))

print("=== coercion: tonumber is explicit ===")
print(tonumber("10") + 5)
print(tonumber("  0x10  "), tonumber("10", 2), tonumber("zz"))

print("=== coercion: concat is not arithmetic ===")
print("10" .. 5, 5 .. "10")

print("=== coercion: non-numerals fail arithmetic ===")
do
  local ok, err = pcall(function() return "10x" + 1 end)
  print(ok, (err or ""):match("attempt to"))
  ok, err = pcall(function() return "hello" * 2 end)
  print(ok, (err or ""):match("attempt to"))
  ok, err = pcall(function() return true + 1 end)
  print(ok, (err or ""):match("attempt to"))
end

print("=== coercion: bitwise ops do not coerce strings ===")
do
  local ok, err = pcall(function() return "1" & 1 end)
  print(ok, (err or ""):match("number has no integer representation") or (err or ""):match("integer"))
  ok, err = pcall(function() return "1" << 1 end)
  print(ok, (err or ""):match("number has no integer representation") or (err or ""):match("integer"))
  print(1 & 3, 1 << 3, ~0 & 0xF)
end

print("=== coercion: mixed order comparison is an error ===")
do
  local ok, err = pcall(function() return "10" < 2 end)
  print(ok, (err or ""):match("attempt to compare"))
  ok, err = pcall(function() return 2 < "10" end)
  print(ok, (err or ""):match("attempt to compare"))
  print("10" < "2", 10 < 2)
end

print("ok")
