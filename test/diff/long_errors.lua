-- Error messages longer than any fixed buffer: the reference builds them
-- on the heap, so a searcher that reports every path it tried and a
-- runtime error naming a very long variable both come through whole.
local long = string.rep("p", 700)
table.insert(package.searchers, 2, function(name)
  return "no file '" .. long .. "'"
end)
local ok, err = pcall(require, "nosuchmodule")
print(ok, err:sub(1, 60))
print((err:find(long, 1, true)) ~= nil)

-- a runtime error whose message carries a 600-byte local name
local src = "local " .. string.rep("v", 600) .. " = nil; return " .. string.rep("v", 600) .. ".x"
local ok2, err2 = pcall(load(src, "=chunk"))
print(ok2, #err2, err2:sub(1, 45))

-- luaL_error with a long argument: a long format string in string.format
local ok3, err3 = pcall(string.format, "%" .. string.rep("9", 600) .. "d", 1)
print(ok3, #err3)
