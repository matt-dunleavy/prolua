-- Lua 5.4: string.format %p and %q
-- %p prints a pointer; numbers, booleans and nil become "(null)". %q emits a
-- Lua literal that load can read back, including integers, floats, inf, NaN,
-- nil and booleans.

print("=== format: %p null vs object ===")
do
  local null = "(null)"
  print(string.format("%p", 4) == null)
  print(string.format("%p", true) == null)
  print(string.format("%p", nil) == null)
  print(string.format("%p", {}) ~= null)
  print(string.format("%p", print) ~= null)
  print(string.format("%p", coroutine.running()) ~= null)
  print(string.format("%p", io.stdin) ~= null)
  print(string.format("%p", io.stdin) == string.format("%p", io.stdin))
  print(string.format("%p", print) == string.format("%p", print))
  print(string.format("%p", print) ~= string.format("%p", assert))
end

print("=== format: %p interned vs long strings, distinct tables ===")
do
  local t1, t2 = {}, {}
  print(string.format("%p", t1) ~= string.format("%p", t2))
  local s1 = string.rep("a", 10)
  local s2 = string.rep("aa", 5)
  print(string.format("%p", s1) == string.format("%p", s2))
  s1 = string.rep("a", 300)
  s2 = string.rep("a", 300)
  print(string.format("%p", s1) ~= string.format("%p", s2))
end

print("=== format: %p width ===")
do
  print(#string.format("%90p", {}) == 90)
  print(#string.format("%-60p", {}) == 60)
  local null = "(null)"
  print(string.format("%10p", false) == string.rep(" ", 10 - #null) .. null)
end

print("=== format: %q round-trips ===")
do
  local function round(v)
    local s = string.format("%q", v)
    local nv = load("return " .. s)()
    return v == nv and math.type(v) == math.type(nv)
  end
  print(round("hello"), round("he\"llo\n\\x"), round("\0"))
  print(round(math.maxinteger), round(math.mininteger))
  print(round(true), round(false), round(nil), round(math.pi))
  print(string.format("%q", 0 / 0))
  print(string.format("%q", math.huge), string.format("%q", -math.huge))
end

print("=== format: %q errors ===")
do
  local ok, err = pcall(string.format, "%q", {})
  print(ok, (err or ""):match("no literal"))
  ok, err = pcall(string.format, "%5q", "x")
  print(ok, (err or ""):match("cannot have modifiers") or (err or ""):match("invalid"))
end

print("ok")
