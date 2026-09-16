-- string.dump and load of binary chunks, compared against the reference

local function add(a, b) return a + b end
local bin = string.dump(add)
print(type(bin), bin:sub(1, 4) == "\27Lua", bin:byte(5) == 0x54)
local f = load(bin)
print(type(f), f(2, 3))

-- upvalues come back fresh (nil), except a main chunk's _ENV
local counter = 0
local function bump() counter = (counter or 0) + 1 return counter end
local bumped = load(string.dump(bump))
print(pcall(bumped))
print(debug.setupvalue(bumped, 1, 41), bumped())

-- a main chunk keeps its globals
local main = load("x_from_dump = 7 return x_from_dump * 2")
local again = load(string.dump(main))
print(again(), x_from_dump)

-- nested functions, constants of every kind, varargs and debug info
local src = [[
local t = { 1, 2.5, "s", true, false, nil, 0x7fffffffffffffff, -1.5e300, ("long"):rep(20) }
local function inner(...)
  local a, b = ...
  return #t, t[3] .. t[1], select("#", ...), a, b
end
return inner
]]
local chunk = assert(load(src, "=dumped"))
local inner = chunk()
local inner2 = load(string.dump(inner))()
print(inner2(10, 20))
print(debug.getinfo(inner2, "S").source, debug.getinfo(inner2, "S").linedefined, debug.getlocal(inner2, 1))

-- stripping removes debug information
local stripped = load(string.dump(inner, true))()
local ok, err = pcall(function() local n = nil; return stripped(n.x) end)
print(debug.getinfo(stripped, "S").source, debug.getlocal(stripped, 1), debug.getinfo(stripped, "l").currentline)
print(select(2, pcall(load(string.dump(function() error("e") end, true)))))
print(select(2, pcall(load(string.dump(function() error("e") end)))))

-- errors inside a loaded function report its original source
local failing = load(string.dump(load("local a = nil\nreturn a.b", "@orig.lua")))
print(pcall(failing))

-- mode checks and malformed chunks
print(load(bin, "b", "t"))
print(load("return 1", "t", "b"))
print(load("\27Lua", "junk", "b"))
print(load(bin:sub(1, 20), "cut", "b"))
print(load("\27Lua" .. string.char(0x53) .. bin:sub(6), "old", "b"))
print(load(bin:sub(1, 5) .. string.char(1) .. bin:sub(7), "fmt", "b"))
print(load(bin:sub(1, 11) .. "xx" .. bin:sub(14), "data", "b"))
print(load(bin:sub(1, 12) .. string.char(8) .. bin:sub(14), "isz", "b"))

-- non-Lua functions cannot be dumped
print(pcall(string.dump, print))
print(pcall(string.dump))

-- a dumped chunk loads as a function that behaves like the original
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
local fib2 = load(string.dump(fib))
debug.upvaluejoin(fib2, 1, fib, 1)
print(fib2(15), fib(15))
