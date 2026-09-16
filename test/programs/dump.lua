-- Lua 5.4: string.dump / load of binary chunks
-- A dumped prototype starts with ESC Lua and version 0x54. load's mode "b"/"t"
-- rejects the other form. dump(..., true) strips debug info.

print("=== dump: 5.4 binary header ===")
do
  local function add(a, b) return a + b end
  local bin = string.dump(add)
  print(type(bin), bin:sub(1, 4) == "\27Lua", bin:byte(5) == 0x54)
  local f = load(bin)
  print(type(f), f(2, 3))
end

print("=== dump: upvalues come back nil ===")
do
  local counter = 0
  local function bump()
    counter = (counter or 0) + 1
    return counter
  end
  local dumped = load(string.dump(bump))
  print(pcall(dumped))
  print(debug.setupvalue(dumped, 1, 41), dumped())
end

print("=== dump: strip removes debug info ===")
do
  local function inner(a)
    return a + 1
  end
  local full = load(string.dump(inner))
  local stripped = load(string.dump(inner, true))
  print(debug.getinfo(full, "S").source ~= "=?", debug.getlocal(full, 1))
  print(debug.getinfo(stripped, "S").source, debug.getlocal(stripped, 1))
  print(full(3), stripped(3))
end

print("=== dump: load mode t vs b ===")
do
  local bin = string.dump(function() return 1 end)
  local f, err = load(bin, "b", "t")
  print(f, (err or ""):match("attempt to load a binary chunk"))
  f, err = load("return 1", "t", "b")
  print(f, (err or ""):match("attempt to load a text chunk"))
  print(load(bin, "b", "b")())
  print(load("return 2", "t", "t")())
end

print("=== dump: C functions cannot be dumped ===")
do
  local ok, err = pcall(string.dump, print)
  print(ok, (err or ""):match("unable to dump"))
end

print("ok")
