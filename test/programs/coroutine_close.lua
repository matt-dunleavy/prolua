-- Lua 5.4: coroutine.close
-- Closes a suspended or dead thread: pending <close> variables run, then
-- the coroutine is dead. A running or normal (resumed another) thread
-- cannot be closed. Closing a dead-with-error thread returns that error
-- once; a later close succeeds.

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

print("=== close: unused coroutine ===")
do
  local co = coroutine.create(function() end)
  print(coroutine.status(co))
  print(coroutine.close(co))
  print(coroutine.status(co), coroutine.resume(co))
  print(coroutine.close(co))
end

print("=== close: finished normally ===")
do
  local co = coroutine.create(function() return "ok" end)
  print(coroutine.resume(co))
  print(coroutine.status(co))
  print(coroutine.close(co))
  print(coroutine.close(co))
end

print("=== close: after an error, then a second close ===")
do
  local co = coroutine.create(function(e) error(e, 0) end)
  print(coroutine.resume(co, "died"))
  print(coroutine.close(co))
  print(coroutine.status(co))
  print(coroutine.close(co))
end

print("=== close: suspended with pending <close> variables ===")
do
  local log = {}
  local co = coroutine.create(function()
    local a <close> = closer("a", log)
    local b <close> = closer("b", log)
    coroutine.yield("suspended")
    log[#log + 1] = "never"
  end)
  print(coroutine.resume(co))
  print(coroutine.close(co))
  print(table.concat(log, ","))
  print(coroutine.status(co), coroutine.resume(co))
end

print("=== close: error inside __close while closing a coroutine ===")
do
  local log = {}
  local co = coroutine.create(function()
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
    coroutine.yield()
  end)
  coroutine.resume(co)
  print(coroutine.close(co))
  print(table.concat(log, ","))
  print(coroutine.status(co))
  print(coroutine.close(co))
end

print("=== close: cannot close a running coroutine ===")
do
  local ok, err = pcall(coroutine.close, coroutine.running())
  print(ok, (err or ""):match("cannot close a running coroutine"))
  local co = coroutine.create(function()
    local ok2, err2 = pcall(coroutine.close, coroutine.running())
    return ok2, (err2 or ""):match("cannot close a running coroutine")
  end)
  print(coroutine.resume(co))
end

print("=== close: cannot close a normal coroutine ===")
do
  local main = coroutine.running()
  ;(coroutine.wrap(function()
    local ok, err = pcall(coroutine.close, main)
    print(ok, (err or ""):match("cannot close a normal coroutine"))
  end))()
end

print("=== close: cannot close a coroutine while closing it ===")
do
  local co
  co = coroutine.create(function()
    local x <close> = setmetatable({}, {
      __close = function()
        coroutine.close(co)
      end,
    })
    coroutine.yield(20)
  end)
  print(coroutine.resume(co))
  local st, msg = coroutine.close(co)
  print(st, (msg or ""):match("cannot close a running coroutine"))
end

print("ok")
