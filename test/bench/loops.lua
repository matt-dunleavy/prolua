-- numeric loops and arithmetic
local t = os.clock()
local s = 0
for i = 1, 30000000 do s = s + i % 7 * 2 end
io.write(string.format("sum=%d  %.3fs\n", s, os.clock() - t))
