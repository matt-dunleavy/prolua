-- collector modes: generational and incremental behave the same as the
-- reference on live data, weak tables, finalizers, coroutines and mode
-- switches (counts are compared only against wide margins)
collectgarbage("generational")
local live = {}
for i = 1, 200 do live[i] = { i } end
local weak = setmetatable({}, { __mode = "v" })
local fin = 0
for round = 1, 50 do
  for i = 1, 2000 do local t = { i, round }; if i % 100 == 0 then weak[#weak + 1] = t end end
  setmetatable({}, { __gc = function() fin = fin + 1 end })
  local co = coroutine.wrap(function(a) local x = { a }; coroutine.yield(x[1]); return x[1] + 1 end)
  assert(co(round) == round and co() == round + 1)
  live[#live + 1] = tostring(round)
end
for i = 1, 200 do assert(live[i][1] == i) end
collectgarbage()
local n = 0 for _ in pairs(weak) do n = n + 1 end
print("live", #live, "weak left", n, "finalized", fin)
print(collectgarbage("incremental"), collectgarbage("incremental"), collectgarbage("generational"), collectgarbage("generational"))
print(collectgarbage("generational", 25, 150), collectgarbage("incremental", 300, 200, 13))
for i = 1, 100000 do local s = "x" .. i end
print(collectgarbage("count") < 20000, collectgarbage("step"), collectgarbage("isrunning"))
collectgarbage("stop") print(collectgarbage("isrunning")) collectgarbage("restart") print(collectgarbage("isrunning"))
-- a young collection does not lose old objects reached only through new ones
collectgarbage("generational")
local old = { 10 }
collectgarbage()
old[1] = { "hello" }
collectgarbage("step", 0)
collectgarbage("step", 0)
print(old[1][1])
-- an object finalized while old is still reachable from its anchor afterwards
local A = {}
A[1] = false
collectgarbage()
setmetatable({}, { __gc = function(o) A[1] = o; collectgarbage("step", 0); print("anchor", type(getmetatable(A[1]))) end })
collectgarbage("step", 0)
collectgarbage("step", 0)
collectgarbage()
print(collectgarbage("incremental"))
