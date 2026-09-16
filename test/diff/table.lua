-- table library, compared against the reference interpreter's own output

local function dump(t, n)
  local parts = {}
  for i = 1, (n or #t) do parts[#parts + 1] = tostring(t[i]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- concat
print(table.concat({ 1, 2, 3 }))
print(table.concat({ 1, 2, 3 }, "-"))
print(table.concat({ 1, 2, 3, 4, 5 }, ",", 2, 4))
print(table.concat({}), table.concat({}, ","))
print(table.concat({ "a", 1, "b" }, "|"))

-- insert
local t = { 1, 2, 3 }
table.insert(t, 4); print(dump(t))
table.insert(t, 1, 0); print(dump(t))
table.insert(t, #t + 1, 9); print(dump(t))

-- remove
t = { 1, 2, 3, 4, 5 }
print(table.remove(t), dump(t))
print(table.remove(t, 1), dump(t))
print(table.remove(t, 2), dump(t))
local single = { 42 }
print(table.remove(single), dump(single), #single)
local empty = {}
print(table.remove(empty))

-- pack and unpack
local p = table.pack(1, 2, 3)
print(p.n, dump(p, p.n))
local p2 = table.pack()
print(p2.n)
local p3 = table.pack(1, nil, 3)
print(p3.n, tostring(p3[2]))
print(table.unpack({ 1, 2, 3 }))
print(table.unpack({ 1, 2, 3 }, 2))
print(table.unpack({ 1, 2, 3 }, 2, 3))
print(table.unpack({ 1, 2, 3 }, 1, 1))
print(select("#", table.unpack({}, 1, 0)))

-- move, including overlapping ranges in both directions
print(dump(table.move({ 1, 2, 3 }, 1, 3, 2)))
print(dump(table.move({ 1, 2, 3, 4, 5 }, 2, 4, 1)))
print(dump(table.move({ 1, 2, 3, 4, 5 }, 1, 3, 3)))
print(dump(table.move({ 1, 2, 3 }, 1, 3, 1, {})))
print(dump(table.move({ 1, 2, 3 }, 2, 1, 1)))

-- sort
t = { 5, 2, 8, 1, 9, 3 }
table.sort(t); print(dump(t))
table.sort(t, function(a, b) return a > b end); print(dump(t))
t = { "banana", "apple", "cherry" }
table.sort(t); print(dump(t))
t = {}
table.sort(t); print(dump(t), #t)
t = { 1 }
table.sort(t); print(dump(t))
t = { 2, 1 }
table.sort(t); print(dump(t))

-- a larger sort, verified by a property rather than a literal
local big = {}
for i = 1, 300 do big[i] = (i * 7919) % 1000 end
table.sort(big)
local sorted = true
for i = 2, #big do if big[i - 1] > big[i] then sorted = false end end
print("300 sorted:", sorted, #big)

-- sort with equal keys must not fall over
local eq = {}
for i = 1, 50 do eq[i] = 1 end
table.sort(eq)
print("equal keys:", #eq)

-- an invalid order function must raise, not crash or hang
local bad = {}
for i = 1, 60 do bad[i] = i end
print(pcall(table.sort, bad, function() return true end))

-- errors
print(pcall(table.insert, { 1, 2 }, 10, "x"))
print(pcall(table.insert, { 1, 2 }))
print(pcall(table.insert, { 1, 2 }, 1, 2, 3))
print(pcall(table.remove, { 1, 2, 3 }, 10))
print(pcall(table.concat, { {} }))
print(pcall(table.concat, "notatable"))
