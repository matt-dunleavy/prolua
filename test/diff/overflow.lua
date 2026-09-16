-- stack overflow: the message, recovery of the stack afterwards, and repeated overflows
local C = 0
local function auxy () C = C + 1; auxy() end
function YY () collectgarbage("stop"); auxy(); collectgarbage("restart") end
for round = 1, 3 do
  local ok, m = pcall(load("YY()"))
  print(round, ok, type(m), C > 100000, type(m) == "string" and m:gsub("^.-:%d+: ", "") or m)
  C = 0
end
local ok, m = xpcall(YY, debug.traceback) print(ok, type(m), #m < 4000)
local t = {} for i = 1, 100 do t[i] = i end print(#t, select("#", table.unpack(t)))
print(pcall(string.rep, "x", -1), pcall(setmetatable, {}, {__index = function(t, k) return t[k] end).x)
-- an overflow while handling an overflow is "error in error handling"
local function loop(x, y, z) return 1 + loop(x, y, z) end
local res, msg = xpcall(loop, function(m)
  local ok, m2 = pcall(loop)
  return (m:gsub("^.-:%d+: ", "")) .. " / " .. tostring(ok) .. " / " .. tostring(m2) .. " / " .. tostring(math.sin(0) == 0)
end)
print(res, msg)
print(xpcall(loop, function(m) error("handler fails") end))
print(pcall(loop))
