-- `#t` on tables with holes: the border luaH_getn picks depends on its
-- `alimit` hint, which moves with `#`, integer reads and writes beyond it,
-- and the table library. Every line must match the reference.
local out = {}
local function p(...) out[#out + 1] = table.concat({...}, " ") end

-- trailing nils in a power-of-two array
local t = {1, 2, 3, 4, 5, 6, 7, 8}
p("a", #t); t[8] = nil; p("a", #t); t[7] = nil; p("a", #t)
t[8] = 8; p("a", #t); t[7] = 7; p("a", #t)
t[6] = nil; p("a", #t); t[5] = nil; p("a", #t); t[3] = nil; p("a", #t)
t[6] = 6; p("a", #t); local _ = t[7]; p("a", #t); t[8] = nil; p("a", #t)

-- non power-of-two constructor: the hint never leaves the real size
t = {1, 2, 3}
t[3] = nil; p("b", #t); t[2] = nil; p("b", #t); t[3] = 3; p("b", #t)
t = {1, 2, 3, 4, 5, 6}
t[6] = nil; p("b", #t); t[5] = nil; t[3] = nil; p("b", #t); t[6] = 6; p("b", #t)

-- reads and writes beyond the hint move it
t = {}
for i = 1, 16 do t[i] = i end
t[16] = nil; t[15] = nil; t[14] = nil; p("c", #t)
t[10] = nil; p("c", #t); _ = t[12]; p("c", #t); _ = t[14]; p("c", #t)
t[14] = 14; p("c", #t); t[16] = 16; p("c", #t); t[15] = 15; p("c", #t)
t[13] = nil; p("c", #t); t[14] = nil; p("c", #t)

-- holes plus a hash part continuing the sequence
t = {}
for i = 1, 8 do t[i] = i end
t[9] = 9; t[10] = 10; p("d", #t); t[8] = nil; p("d", #t); t[8] = 8; t[10] = nil; p("d", #t)
t[9] = nil; p("d", #t); t[9] = 9; t[10] = 10; t[11] = 11; p("d", #t)
t[4] = nil; p("d", #t); t[4] = 4; t[7] = nil; p("d", #t)

-- the library routes: insert/remove/unpack/concat/ipairs
t = {}
for i = 1, 12 do t[i] = i end
t[12] = nil; t[11] = nil; p("e", #t)
table.insert(t, 99); p("e", #t, t[11]); table.insert(t, 3, 77); p("e", #t, t[3], t[12])
t[12] = nil; t[11] = nil; t[10] = nil; p("e", #t)
p("e", select("#", table.unpack(t, 1, 13)), table.concat(t, ",", 1, 9)); p("e", #t)
_ = select("#", table.unpack(t, 1, 12)); p("e", #t)
t[6] = nil; p("e", #t); for i in ipairs(t) do _ = i end; p("e", #t)
table.remove(t); p("e", #t); table.remove(t, 1); p("e", #t)
t[9] = 9; t[10] = 10; table.remove(t, #t + 1); p("e", #t)
_ = t[16]; p("e", #t); t[16] = 16; p("e", #t); t[16] = nil; p("e", #t)

-- a growing sequence with pruning, as programs really do it
t = {}
for i = 1, 200 do
  t[#t + 1] = i
  if i % 7 == 0 then t[#t] = nil end
  if i % 31 == 0 then t[#t - 3] = nil; p("f", i, #t); t[#t - 3] = 1 end
end
p("f", #t)
for i = 200, 1, -3 do t[i] = nil end
p("f", #t); _ = t[150]; p("f", #t); t[150] = 1; p("f", #t)

-- deterministic mixed patterns over power-of-two and other sizes
for size = 1, 20 do
  local u = {}
  for i = 1, size do u[i] = i end
  local line = {"g", size}
  for k = size, 1, -2 do
    u[k] = nil; line[#line + 1] = #u
    if k > 2 then local _ = u[k - 1] end
    line[#line + 1] = #u
  end
  p(table.unpack(line))
end

print(table.concat(out, "\n"))
