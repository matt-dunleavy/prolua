-- recursive calls
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
local t = os.clock()
local r = fib(30)
io.write(string.format("fib(30)=%d  %.3fs\n", r, os.clock() - t))
