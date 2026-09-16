-- Open upvalues of threads that die mid-cycle (lgc.c `twups` / remarkupvals).
-- A coroutine creates a closure over one of its locals, publishes the
-- closure, then keeps overwriting the local (stack writes have no barrier)
-- and is dropped while a collection cycle is in progress. The closure must
-- still see the last value, never a collected object.
collectgarbage("incremental")
collectgarbage("setpause", 100)
collectgarbage("setstepmul", 50)

local keep = {}
local function spawn(i)
  local co = coroutine.create(function()
    local slot = "first" .. i
    keep[i] = function() return slot end
    coroutine.yield()
    for j = 1, 50 do
      slot = { "value", i, j, string.rep("x", 32) }  -- fresh objects, no barrier
      collectgarbage("step", 1)
    end
    slot = "last" .. i
  end)
  coroutine.resume(co)
  return co
end

for round = 1, 200 do
  local co = spawn(round)
  coroutine.resume(co)              -- runs to the end: last value written
  co = nil                          -- thread is garbage while the cycle may be open
  if round % 7 == 0 then collectgarbage("step", 0) end
end
collectgarbage()
collectgarbage()

local bad = 0
for i = 1, 200 do
  local v = keep[i]()
  if v ~= "last" .. i then bad = bad + 1 end
end
print("closures", #keep, "wrong", bad)

-- The same with the thread suspended (not finished) when it is dropped
local keep2 = {}
for round = 1, 200 do
  local co = coroutine.wrap(function()
    local slot = {}
    keep2[round] = function() return slot end
    for j = 1, 20 do
      slot = { j }
      collectgarbage("step", 1)
      coroutine.yield()
    end
  end)
  for _ = 1, 5 do co() end
end
collectgarbage()
collectgarbage()
local ok = 0
for i = 1, 200 do
  local t = keep2[i]()
  if type(t) == "table" and t[1] == 5 then ok = ok + 1 end
end
print("suspended", ok)

-- generational mode, same shapes
collectgarbage("generational")
local keep3 = {}
for round = 1, 100 do
  local co = coroutine.create(function()
    local slot = 0
    keep3[round] = function() return slot end
    coroutine.yield()
    for j = 1, 30 do slot = { j }; collectgarbage("step", 1) end
    slot = round * 2
  end)
  coroutine.resume(co); coroutine.resume(co)
end
collectgarbage(); collectgarbage()
local ok3 = 0
for i = 1, 100 do if keep3[i]() == i * 2 then ok3 = ok3 + 1 end end
print("generational", ok3)
