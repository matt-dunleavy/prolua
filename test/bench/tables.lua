-- table construction, array and hash access
local t = os.clock()
local a = {}
for i = 1, 2000000 do a[i] = i * 2 end
local h = {}
for i = 1, 500000 do h["k" .. i] = i end
local s = 0
for i = 1, #a do s = s + a[i] end
for i = 1, 500000 do s = s + h["k" .. i] end
io.write(string.format("s=%d  %.3fs\n", s, os.clock() - t))
