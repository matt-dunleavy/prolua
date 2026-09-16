-- Lua 5.4: __name
-- A __name metafield names a type in tostring (when there is no __tostring)
-- and in error messages. The IO library uses FILE*. __tostring wins over
-- __name.

print("=== name: tostring uses __name as a prefix ===")
do
  local x = setmetatable({}, { __name = "My Type" })
  print(tostring(x):match("^My Type"))
  print(tostring(x):find("My Type:") ~= nil)
end

print("=== name: __tostring wins ===")
do
  local x = setmetatable({}, {
    __name = "My Type",
    __tostring = function() return "CUSTOM" end,
  })
  print(tostring(x))
end

print("=== name: errors mention __name ===")
do
  local x = setmetatable({}, { __name = "My Type" })
  local ok, err = pcall(function() return x + 1 end)
  print(ok, (err or ""):match("My Type"))
  ok, err = pcall(function() return x < x end)
  print(ok, (err or ""):match("My Type"))
  ok, err = pcall(function() return {} < x end)
  print(ok, (err or ""):match("My Type"))
  ok, err = pcall(function() return ~x end)
  print(ok, (err or ""):match("My Type"))
end

print("=== name: FILE* from the io library ===")
do
  print(getmetatable(io.stdin).__name)
  local ok, err = pcall(math.sin, io.stdin)
  print(ok, (err or ""):match("FILE%*"))
  ok, err = pcall(function() return ~io.stdin end)
  print(ok, (err or ""):match("FILE%*"))
end

print("=== name: io.input rejects a named table ===")
do
  local x = setmetatable({}, { __name = "My Type" })
  local ok, err = pcall(io.input, x)
  print(ok, (err or ""):match("FILE%*"), (err or ""):match("My Type"))
end

print("ok")
