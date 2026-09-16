-- base library, compared against the reference interpreter's own output

print(_VERSION)
print(type(nil), type(true), type(1), type("s"), type({}), type(print))
print(tostring(nil), tostring(true), tostring(12), tostring(1.5))
print(tonumber("42"), tonumber("3.5"), tonumber("0x1F"), tonumber("abc"))
print(tonumber("10", 2), tonumber("ff", 16), tonumber("z", 36))
print(tonumber(" 42 "), tonumber(""), tonumber("4 2"))
print(math.type(tonumber("42")), math.type(tonumber("42.0")))

-- select
print(select("#"), select("#", 1, 2, 3))
print(select(2, "a", "b", "c"))
print(select(-1, "a", "b", "c"))
print(pcall(select, 0, "a"))

-- rawget/rawset/rawequal/rawlen
local t = setmetatable({}, {
  __index = function() return "meta" end,
  __newindex = function() error("no writes") end,
  __len = function() return 99 end,
  __eq = function() return true end,
})
print(t.missing, rawget(t, "missing"))
rawset(t, "k", 1)
print(t.k, rawget(t, "k"))
print(#t, rawlen(t))
print(rawequal(t, t), rawequal(t, {}))
print(rawequal(t, setmetatable({}, getmetatable(t))), t == setmetatable({}, getmetatable(t)))
print(rawlen({ 1, 2, 3 }), rawlen("hello"))

-- ipairs and pairs
local arr = { 10, 20, 30, nil, 50 }
local sum = 0
for _, v in ipairs(arr) do sum = sum + v end
print("ipairs sum:", sum)
local keys = {}
for k in pairs({ a = 1, b = 2, c = 3 }) do keys[#keys + 1] = k end
table.sort(keys)
print(table.concat(keys, ","))

-- next
print(next({}))
local one = { x = 1 }
local k, v = next(one)
print(k, v, next(one, k))

-- assert
print(pcall(assert, false))
print(pcall(assert, nil, "custom message"))
print(pcall(assert, false, 42))
print(assert(1, 2, 3))

-- error and pcall
print(pcall(error, "plain"))
print(pcall(error, "plain", 0))
print(pcall(error))
-- an error object passes through unchanged; its address would differ per run
local eok, eobj = pcall(error, { code = 1 })
print(eok, type(eobj), eobj.code)
print(pcall(function() error("in function", 0) end))
print(pcall(function() return 1, 2, 3 end))
print(select("#", pcall(function() end)))

-- xpcall
print(xpcall(function() error("boom", 0) end, function(m) return "handled: " .. m end))
print(xpcall(function(a, b) return a + b end, print, 3, 4))

-- metatables
local mt = { __metatable = "locked" }
local prot = setmetatable({}, mt)
print(getmetatable(prot))
print(pcall(setmetatable, prot, {}))
print(getmetatable("string") == string)

-- __tostring and __name
print(tostring(setmetatable({}, { __tostring = function() return "CUSTOM" end })))

-- __call
local callable = setmetatable({}, { __call = function(_, x) return x * 2 end })
print(callable(21))

-- __index chains
local base = { greet = function() return "hi" end }
local derived = setmetatable({}, { __index = base })
print(derived.greet())

-- arithmetic and comparison metamethods
local V = {}
V.__index = V
V.__add = function(a, b) return setmetatable({ n = a.n + b.n }, V) end
V.__lt = function(a, b) return a.n < b.n end
V.__le = function(a, b) return a.n <= b.n end
V.__unm = function(a) return setmetatable({ n = -a.n }, V) end
V.__concat = function(a, b) return tostring(a.n) .. "/" .. tostring(b.n) end
local a, b = setmetatable({ n = 1 }, V), setmetatable({ n = 2 }, V)
print((a + b).n, a < b, a <= b, (-a).n, a .. b)

-- load
local f = load("return 1 + 1")
print(f())
local lf, lerr = load("syntax ~~ error")
print(lf, lerr)
print(load(string.rep("(", 300)))
print(load("return ...")("x"))
local env = { y = 7 }
local g = load("return y", "chunk", "t", env)
print(g())
local counter = 0
local pieces = { "return ", "40 + 2" }
print(load(function() counter = counter + 1 return pieces[counter] end)())

-- tostring/tonumber round trips
print(tonumber(tostring(1 / 3)) == 1 / 3)
print(0.1 + 0.2 == 0.3, math.abs((0.1 + 0.2) - 0.3) < 1e-15)

-- integer/float distinction in output
print(1, 1.0, 1e2, 10 // 3, 10 / 5, 7 % 3, 2 ^ 2)
print(math.type(10 // 3), math.type(10 / 5), math.type(2 ^ 2))
print(3 // 0.0, -3 // 0.0)
print(pcall(function() return 1 // 0 end))
print(pcall(function() return 1 % 0 end))
