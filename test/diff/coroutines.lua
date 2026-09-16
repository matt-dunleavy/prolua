-- coroutines, compared against the reference interpreter's own output

-- basics: values in both directions, status transitions
local co = coroutine.create(function(a, b)
  print("start", a, b)
  local c = coroutine.yield(a + b)
  print("got", c)
  local d, e = coroutine.yield(c * 2)
  print("got", d, e)
  return "done", d + e
end)
print(type(co), tostring(co):match("^thread:") ~= nil)
print(coroutine.status(co))
print(coroutine.resume(co, 1, 2))
print(coroutine.status(co))
print(coroutine.resume(co, 10))
print(coroutine.resume(co, 3, 4))
print(coroutine.status(co))
print(coroutine.resume(co))
print(coroutine.resume(co))

-- running, isyieldable
print(coroutine.isyieldable(), select(2, coroutine.running()))
coroutine.wrap(function()
  print(coroutine.isyieldable(), select(2, coroutine.running()))
  local t, ismain = coroutine.running()
  print(type(t), ismain, coroutine.status(t))
end)()

-- generators through wrap and a generic for
local function range(n)
  return coroutine.wrap(function()
    for i = 1, n do coroutine.yield(i) end
  end)
end
local acc = {}
for i in range(5) do acc[#acc + 1] = i end
print(table.concat(acc, ","))

-- yield from nested Lua calls and through varargs and tail calls
local function inner(...) return coroutine.yield(...) end
local function middle(...) return inner("m", ...) end
co = coroutine.create(function(...) local r = { middle(...) } return #r, table.unpack(r) end)
print(coroutine.resume(co, 1, 2, 3))
print(coroutine.resume(co, "x", "y"))

-- yield across pcall, then keep going; errors after a yield are still caught
co = coroutine.create(function()
  local ok, v = pcall(function()
    local x = coroutine.yield("in pcall")
    if x == "boom" then error("exploded") end
    return x .. "!"
  end)
  print("pcall gave", ok, v)
  local ok2, v2 = pcall(function()
    coroutine.yield("again")
    error({ code = 7 })
  end)
  print("second", ok2, type(v2), v2.code)
  return "finished"
end)
print(coroutine.resume(co))
print(coroutine.resume(co, "fine"))
print(coroutine.resume(co))
print(coroutine.resume(co))
print(coroutine.status(co))

-- xpcall with a traceback handler after a yield
co = coroutine.create(function()
  local ok, tb = xpcall(function()
    coroutine.yield()
    local t = nil
    return t.field
  end, debug.traceback)
  print(ok)
  print((tb:gsub("\n.*", "")))
  print(tb:find("stack traceback:", 1, true) ~= nil)
  return "ok"
end)
print(coroutine.resume(co))
print(coroutine.resume(co))

-- nested pcalls with yields at each level
co = coroutine.wrap(function()
  return pcall(function()
    return pcall(function()
      coroutine.yield(1)
      coroutine.yield(2)
      return "deep"
    end)
  end)
end)
print(co()) print(co()) print(co())

-- yields inside metamethods
local mt = {}
mt.__index = function(t, k) return coroutine.yield("index " .. k) end
mt.__newindex = function(t, k, v) rawset(t, k, coroutine.yield("newindex " .. k)) end
mt.__add = function(a, b) return coroutine.yield("add") end
mt.__concat = function(a, b) return coroutine.yield("concat") end
mt.__lt = function(a, b) return coroutine.yield("lt") end
mt.__le = function(a, b) return coroutine.yield("le") end
mt.__eq = function(a, b) return coroutine.yield("eq") end
mt.__len = function(a) return coroutine.yield("len") end
mt.__unm = function(a) return coroutine.yield("unm") end
mt.__call = function(self, x) return coroutine.yield("call " .. x) end
mt.__close = function(o, e) coroutine.yield("close") end
local obj = setmetatable({}, mt)
local obj2 = setmetatable({}, mt)
co = coroutine.wrap(function()
  print("field", obj.foo)
  obj.bar = 1
  print("stored", rawget(obj, "bar"))
  print("sum", obj + 1)
  print("cat", obj .. "s", "x" .. obj)
  print("cmp", obj < obj2, obj <= obj2, obj > obj2, obj == obj2, obj ~= obj2)
  print("len", #obj)
  print("neg", -obj)
  print("called", obj(42))
  do
    local c <close> = obj
    print("in scope")
  end
  print("after close")
  for i, v in coroutine.wrap(function() coroutine.yield(1, "a") coroutine.yield(2, "b") end) do
    print("iter", i, v)
  end
  return "meta done"
end)
local v = co()
while v ~= "meta done" do
  v = co(v and (type(v) == "string" and v:upper() or v))
end
print(v)

-- yielding across a native boundary is an error, in both directions
co = coroutine.create(function()
  local ok, err = pcall(table.sort, { 3, 1, 2 }, function(a, b) coroutine.yield() return a < b end)
  print(ok, err)
  ok, err = pcall(string.gsub, "abc", "%w", function(c) coroutine.yield(c) end)
  print(ok, err)
  return "boundary done"
end)
print(coroutine.resume(co))
print(pcall(coroutine.yield, 1))
print(select(2, pcall(function() coroutine.yield() end)))

-- errors kill a coroutine
co = coroutine.create(function() local x = nil; return x.y end)
print(coroutine.resume(co))
print(coroutine.status(co), coroutine.resume(co))
co = coroutine.create(function() error({ tag = "t" }) end)
local ok, e = coroutine.resume(co)
print(ok, type(e), e.tag)

-- wrap propagates errors with position, and non-string objects untouched
local w = coroutine.wrap(function() error("wrapped failure") end)
print(pcall(w))
w = coroutine.wrap(function() error({ n = 1 }) end)
local ok2, e2 = pcall(w)
print(ok2, type(e2), e2.n)
w = coroutine.wrap(function() coroutine.yield() end)
w() w()
print(pcall(w))

-- resuming things that cannot be resumed
co = coroutine.create(function()
  local self = coroutine.running()
  print(coroutine.resume(self))
  print(coroutine.status(self))
  local outer = coroutine.wrap(function() return coroutine.status(self), coroutine.resume(self) end)
  print(outer())
end)
print(coroutine.resume(co))
print(pcall(coroutine.resume, 42))
print(pcall(coroutine.status, "x"))
print(pcall(coroutine.wrap, 1))

-- close: suspended with pending to-be-closed variables, dead with error, running
co = coroutine.create(function()
  local a <close> = setmetatable({}, { __close = function(_, e) print("closing a", e) end })
  local b <close> = setmetatable({}, { __close = function(_, e) print("closing b", e) end })
  coroutine.yield("suspended with tbc")
  print("never reached")
end)
print(coroutine.resume(co))
print(coroutine.close(co))
print(coroutine.status(co), coroutine.resume(co))
co = coroutine.create(function() error("died") end)
print(coroutine.resume(co))
print(coroutine.close(co))
print(coroutine.close(co))
co = coroutine.create(function()
  local c <close> = setmetatable({}, { __close = function() error("close failed") end })
  coroutine.yield()
end)
coroutine.resume(co)
print(coroutine.close(co))
print(pcall(coroutine.close, coroutine.running()))
co = coroutine.create(function() print(pcall(coroutine.close, coroutine.running())) end)
coroutine.resume(co)
print(coroutine.close(coroutine.create(print)))

-- a to-be-closed variable inside a coroutine that finishes or errors
co = coroutine.wrap(function()
  local x <close> = setmetatable({}, { __close = function(_, e) print("x closed with", e) end })
  coroutine.yield(1)
  error("after yield")
end)
co()
print(pcall(co))

-- many yields and a growing stack
co = coroutine.wrap(function()
  local function rec(n)
    if n == 0 then coroutine.yield("bottom") return 0 end
    return 1 + rec(n - 1)
  end
  coroutine.yield(rec(200))
  local s = 0
  for i = 1, 10000 do s = s + coroutine.yield(i) end
  return s
end)
print(co()) print(co())
local n = co()
local total = 0
while type(n) == "number" and n < 10000 do n = co(1) end
print(n)

-- stack overflow inside a coroutine is a catchable error
co = coroutine.create(function() local function f() return f() + 1 end return f() end)
local ok3, e3 = coroutine.resume(co)
print(ok3, e3:match("stack overflow") ~= nil)

-- closures capturing upvalues of a coroutine survive its collection
local getters = {}
for i = 1, 20 do
  local c = coroutine.wrap(function()
    local v = i * 10
    getters[i] = function() return v end
    coroutine.yield()
    v = -1
  end)
  c()
end
collectgarbage() collectgarbage()
local sum = 0
for i = 1, 20 do sum = sum + getters[i]() end
print(sum)

-- debug functions see other threads
co = coroutine.create(function(a) local b = a * 2; coroutine.yield(); return b end)
coroutine.resume(co, 21)
print(debug.getinfo(co, 1, "l").currentline ~= nil, debug.getlocal(co, 1, 1), debug.getlocal(co, 1, 2))
print(debug.traceback(co):gsub("\n.*", ""))
print(coroutine.resume(co))

-- an uncaught error inside a coroutine reports the coroutine's own position
co = coroutine.wrap(function() local t = {} t.x.y = 1 end)
print(pcall(co))
