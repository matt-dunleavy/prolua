-- Test table library

local t = {3, 1, 4, 1, 5, 9}

-- Insert and remove
table.insert(t, 2)
table.insert(t, 3, 42)
local removed = table.remove(t)
local removed2 = table.remove(t, 3)

-- Concatenation
assert(table.concat({1, 2, 3}, ", ") == "1, 2, 3")
assert(table.concat({"a", "b", "c"}) == "abc")

-- Sorting
table.sort(t)
table.sort(t, function(a, b) return a > b end)

-- Length
assert(#t == 6)

-- Pack and unpack
local packed = table.pack(1, 2, 3, nil, 5)
assert(packed.n == 5)
local a, b, c, d, e = table.unpack(packed)