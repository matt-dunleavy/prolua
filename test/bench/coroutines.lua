-- resume/yield round trips
local t = os.clock()
local co = coroutine.wrap(function() local i = 0 while true do i = i + 1 coroutine.yield(i) end end)
local s = 0
for _ = 1, 2000000 do s = s + co() end
io.write(string.format("s=%d  %.3fs\n", s, os.clock() - t))
