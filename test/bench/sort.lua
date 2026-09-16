-- table.sort with and without a comparator
local t = os.clock()
math.randomseed(42)
local a = {}
for i = 1, 300000 do a[i] = math.random(1, 1000000) end
local b = { table.unpack(a) }
table.sort(a)
table.sort(b, function(x, y) return x > y end)
io.write(string.format("first=%d last=%d  %.3fs\n", a[1], b[1], os.clock() - t))
