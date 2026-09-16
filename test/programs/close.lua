-- Lua 5.4: <close> locals and the __close metamethod
-- A to-be-closed local is also const. When it leaves scope, Lua calls
-- __close unless the value is nil or false. Close order is reverse of
-- declaration. The generic for's 4th result is closed when the loop ends.

local function closer(name, log)
  return setmetatable({}, {
    __close = function(_, err)
      log[#log + 1] = name
      if err ~= nil then
        log[#log + 1] = tostring(err)
      end
    end,
  })
end

print("=== close: LIFO order on block exit ===")
do
  local log = {}
  do
    local a <close> = closer("a", log)
    local b <close> = closer("b", log)
    log[#log + 1] = "in"
  end
  log[#log + 1] = "out"
  print(table.concat(log, ","))
end

print("=== close: nil and false are not closed ===")
do
  local log = {}
  do
    local a <close> = false
    local b <close> = closer("b", log)
    local c <close> = nil
    log[#log + 1] = "in"
  end
  print(table.concat(log, ","))
end

print("=== close: return still closes, values are preserved ===")
do
  local log = {}
  local function foo(x)
    local _ <close> = closer("ret", log)
    return x, 23
  end
  local a, b, c = foo(1.5)
  print(a, b, c, table.concat(log, ","))
end

print("=== close: error still closes; handler gets the error object ===")
do
  local log = {}
  local ok, err = pcall(function()
    local x <close> = closer("x", log)
    error("boom", 0)
  end)
  print(ok, err, table.concat(log, ","))
end

print("=== close: later __close error is seen by earlier handlers ===")
do
  local log = {}
  local ok, err = pcall(function()
    local a <close> = setmetatable({}, {
      __close = function(_, e)
        log[#log + 1] = "a:" .. tostring(e)
      end,
    })
    local b <close> = setmetatable({}, {
      __close = function(_, e)
        log[#log + 1] = "b:" .. tostring(e)
        error("from b", 0)
      end,
    })
    error("orig", 0)
  end)
  print(ok, err, table.concat(log, ","))
end

print("=== close: assignment after declaration is a compile error ===")
do
  local fn, err = load("local x <close> = nil; x = 2")
  print(fn, err ~= nil)
  print((err or ""):match("attempt to assign to const variable"))
end

print("=== close: two <close> names in one local list is a compile error ===")
do
  local fn, err = load("local a <close>, b <close> = 1, 2")
  print(fn, err ~= nil)
  print((err or ""):match("multiple to%-be%-closed variables in local list"))
end

print("=== close: non-closable value is a runtime error ===")
do
  local ok, err = pcall(function()
    local x <close> = {}
  end)
  print(ok)
  print((err or ""):match("variable 'x' got a non%-closable value"))
end

print("=== close: generic for closes the 4th iterator result ===")
do
  local log = {}
  local i = 0
  local function iter()
    i = i + 1
    if i <= 2 then return i end
  end
  for v in iter, nil, nil, closer("for", log) do
    log[#log + 1] = v
  end
  print(table.concat(log, ","))
end

print("=== close: break in generic for still closes ===")
do
  local log = {}
  local n = 0
  local function iter()
    n = n + 1
    if n <= 5 then return n end
  end
  for v in iter, nil, nil, closer("brk", log) do
    log[#log + 1] = v
    if v == 1 then break end
  end
  print(table.concat(log, ","))
end

print("ok")
