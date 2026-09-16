-- table.concat: values, ranges, proxies, holes, formatting, and long string keys
print(table.concat({1, "a", 2.5, "b", 3}, ","), table.concat({}, ","), table.concat({"x"}, ",", 1, 1), table.concat({"a","b","c"}, "-", 2), table.concat({"a","b","c"}, "-", 2, 3), table.concat({"a","b","c"}, "", 3, 2))
print(pcall(table.concat, {1, {}, 3}), pcall(table.concat, {1, 2}, ",", 1, 3))
local p = setmetatable({}, {__index = function(_, i) return "v" .. i end, __len = function() return 3 end}) print(table.concat(p, "+"))
local h = {} h[1] = "a" h[2] = "b" h[4] = "d" print(pcall(table.concat, h, ",", 1, 4))
print(table.concat({1e15, 2^53, -0.0, 1/3, math.maxinteger}, " "))
local long = string.rep("k", 100) local t = {} t[long] = 1 t[string.rep("k", 100)] = 2 t[long .. "x"] = 3 print(t[long], t[long .. "x"], #long)
local ks = {} for i = 1, 3 do ks[string.rep("z", 60) .. i] = i end local n = 0 for k, v in pairs(ks) do n = n + v end print(n, ks[string.rep("z", 60) .. "2"])
