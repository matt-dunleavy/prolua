-- Lua 5.4: collectgarbage modes
-- 5.4 added collectgarbage("generational") and ("incremental"). The default
-- is incremental. Each call returns the previous mode name. Extra integer
-- arguments are accepted as tuning parameters.

print("=== gc: default mode ===")
print(collectgarbage("incremental"))
print(collectgarbage("incremental"))

print("=== gc: switch generational / incremental ===")
print(collectgarbage("generational"))
print(collectgarbage("generational"))
print(collectgarbage("incremental"))
print(collectgarbage("incremental"))

print("=== gc: extra integer args are accepted ===")
print(collectgarbage("generational", 20, 100))
print(collectgarbage("incremental", 200, 100, 13))
print(collectgarbage("incremental"))

print("=== gc: isrunning, stop, restart ===")
print(collectgarbage("isrunning"))
collectgarbage("stop")
print(collectgarbage("isrunning"))
collectgarbage("restart")
print(collectgarbage("isrunning"))

print("=== gc: count is a finite number ===")
do
  local n = collectgarbage("count")
  print(type(n), n > 0, n == n)
end

print("=== gc: step returns a boolean ===")
do
  local r = collectgarbage("step", 0)
  print(type(r))
end

print("=== gc: collect runs finalizers in both modes ===")
do
  local log = {}
  collectgarbage("incremental")
  do
    local _ = setmetatable({}, { __gc = function() log[#log + 1] = "inc" end })
  end
  collectgarbage("collect")
  collectgarbage("generational")
  do
    local _ = setmetatable({}, { __gc = function() log[#log + 1] = "gen" end })
  end
  collectgarbage("collect")
  print(table.concat(log, ","))
  collectgarbage("incremental")
end

print("=== gc: bad option and bad extra args ===")
do
  local ok, err = pcall(collectgarbage, "nope")
  print(ok, (err or ""):match("invalid option"))
  ok, err = pcall(collectgarbage, "generational", "x")
  print(ok, (err or ""):match("number expected") or (err or ""):match("integer expected"))
end

print("ok")
