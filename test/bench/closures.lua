-- closure creation, upvalues and method calls
local t = os.clock()
local Acc = {}
Acc.__index = Acc
function Acc.new() return setmetatable({ n = 0 }, Acc) end
function Acc:add(v) self.n = self.n + v return self end
local acc = Acc.new()
local function make(i) return function() return i end end
local s = 0
for i = 1, 3000000 do
  local f = make(i)
  s = s + f()
  acc:add(1)
end
io.write(string.format("s=%d n=%d  %.3fs\n", s, acc.n, os.clock() - t))
