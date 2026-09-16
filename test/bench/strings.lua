-- string building, patterns and formatting
local t = os.clock()
local parts = {}
for i = 1, 200000 do parts[#parts + 1] = string.format("%d:%s", i, ("x"):rep(i % 10)) end
local s = table.concat(parts, ",")
local n = 0
for w in s:gmatch("%d+") do n = n + 1 end
local r = s:gsub("x+", "y")
io.write(string.format("n=%d len=%d  %.3fs\n", n, #r, os.clock() - t))
