-- <const> locals: compile-time constants fold, keep their values through
-- nested functions and remain assignable only by error
local x <const> = 3
local s <const> = "abc"
local n <const> = nil
local b <const> = true
local y <const> = x + 2
local f <const> = 1.5
local function g() return x + 1, s .. "d", x * x, y, n, b, f * 2 end
print(g())
print(x, s, n, b, y, f, select("#", x, n))
local t = {} t[x] = s t[s] = x print(t[3], t.abc)
local function outer() local function inner() return x, y, s end return inner() end
print(outer())
local _ENV <const> = { print = print }
print(rawequal(_ENV, nil), type(_ENV))
local function h()
  local z <const> = 10
  local w <close> = nil
  local q <const> = { 1 }
  q[1] = 2
  return z, q[1]
end
print(h())
print(load("local x <const> = 1; x = 2", "=c1"))
print(load("local x <const> = 1; local function f() x = 2 end", "=c2"))
print(load("local x <const> = 1; local y <const> = x; y = 2", "=c3"))
print(load("local x <const>, y = 1; x = 2", "=c4"))
print(load("local x <close> = 1; x = 2", "=c5"))
print(load("local x <foo> = 1", "=c6"))
