-- Lua 5.4: <const> locals
-- A const local may be assigned only in its declaration. Later writes
-- are a compile-time error. Reads, captures, and mixing with mutable
-- locals in the same declaration are allowed.

print("=== const: declaration and use ===")
do
  local a <const> = 10
  local b <const> = a + 1
  print(a, b)
  print(a + b, a * b)
end

print("=== const: all value types ===")
do
  local n <const> = 1
  local f <const> = 1.5
  local s <const> = "ok"
  local t <const> = { n }
  local fn <const> = function() return n end
  local z <const> = nil
  local b <const> = true
  print(n, f, s, t[1], fn(), z, b)
end

print("=== const: mixed declaration ===")
do
  local x, y <const>, z = 1, 2, 3
  x = 10
  z = 30
  print(x, y, z)
end

print("=== const: captured by nested function ===")
do
  local k <const> = 7
  local function get() return k end
  print(get())
  local function make()
    return function() return k + 1 end
  end
  print(make()())
end

print("=== const: for-loop control vars are not writable ===")
do
  local n = 0
  for i = 1, 3 do
    n = n + i
  end
  print(n)
end

print("=== const: assignment after declaration is a compile error ===")
do
  local chunk = "local x <const> = 1; x = 2"
  local fn, err = load(chunk)
  print(fn, err ~= nil)
  print((err or ""):match("attempt to assign to const variable"))
end

print("=== const: missing initializer is a compile error ===")
do
  local fn, err = load("local x <const>")
  print(fn, err ~= nil)
  print((err or ""):match("<const> variable"))
end

print("=== const: cannot assign through a nested function ===")
do
  local chunk = [[
    local x <const> = 1
    local function f() x = 2 end
    f()
  ]]
  local fn, err = load(chunk)
  print(fn, err ~= nil)
  print((err or ""):match("attempt to assign to const variable"))
end

print("=== const: unknown attribute is a compile error ===")
do
  local fn, err = load("local x <foo> = 1")
  print(fn, err ~= nil)
  print((err or ""):match("unknown attribute"))
end

print("ok")
