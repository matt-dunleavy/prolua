-- The global namespace and every library's contents, sorted: what a script
-- can see must be what the reference exposes (no 5.1-era `loadstring`, no
-- LUA_COMPAT_MATHLIB `math.frexp`, and nothing missing).
local function keys(t)
  local k = {}
  for name, v in pairs(t) do k[#k + 1] = name .. ":" .. type(v) end
  table.sort(k)
  return table.concat(k, " ")
end
print("_G", keys(_G))
for _, lib in ipairs { "string", "table", "math", "os", "io", "coroutine", "debug", "utf8", "package" } do
  print(lib, keys(_G[lib]))
end
print("string metatable", keys(getmetatable("").__index), getmetatable("").__index == string)
print("file metatable", keys(getmetatable(io.stdout)), keys(getmetatable(io.stdout).__index))
print(keys(package.loaded))
