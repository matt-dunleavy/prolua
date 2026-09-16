-- table.sort: orders, comparators, metamethods, and comparators that break the table
local function show(t) local o = {} for i = 1, #t do o[i] = tostring(t[i]) end print(table.concat(o, ",")) end
local t = {5, 3, 9, 1, 7, 2, 8, 6, 4, 0} table.sort(t) show(t)
table.sort(t, function(a, b) return a > b end) show(t)
local s = {"pear", "apple", "fig", "kiwi", "banana"} table.sort(s) show(s)
local m = {3, 1.5, 2, -1, 2^53, 0.1} table.sort(m) show(m)
local big = {} for i = 1, 5000 do big[i] = (i * 7919) % 1009 end table.sort(big) local ok = true for i = 2, #big do if big[i-1] > big[i] then ok = false end end print("big sorted", ok, big[1], big[#big])
local V = setmetatable({}, {__lt = function(a, b) return a.v < b.v end}) V.__index = V
local objs = {} for i = 1, 20 do objs[i] = setmetatable({v = (i * 13) % 20}, getmetatable(V)) end table.sort(objs) local o = {} for i = 1, 20 do o[i] = objs[i].v end print(table.concat(o, ","))
print(pcall(table.sort, {3, 1, 2, 5, 4, 7, 6, 9, 8, 0, 11, 13, 12}, function(a, b) return true end))
print(pcall(table.sort, {1, "x", 3}))
local r = {4, 2, 3, 1} print(pcall(table.sort, r, function(a, b) r[#r + 1] = 9 return a < b end)) show(r)
local h = setmetatable({}, {__index = function(_, i) return 10 - i end, __len = function() return 5 end}) table.sort(h) show(h)
local shrink = {} for i = 1, 300 do shrink[i] = 300 - i end print(pcall(table.sort, shrink, function(a, b) for k = 1, 300 do shrink[k] = nil end return a < b end))
print(pcall(table.sort, {1, 2, 3}, 5))
