-- Lua 5.4: string.pack / unpack / packsize
-- Explicit endian prefixes keep the bytes host-independent.

print("=== pack: fixed integers, endian ===")
do
  print(string.packsize("B"), string.packsize("<I4"), string.packsize(">i2"))
  print(string.unpack("B", string.pack("B", 0xff)))
  print(string.unpack("<I4", string.pack("<I4", 0xAABBCCDD)) == 0xAABBCCDD)
  print(string.pack("<I2", 0xAABB) == "\xBB\xAA")
  print(string.pack(">I2", 0xAABB) == "\xAA\xBB")
  print(string.unpack("<i2", string.pack("<i2", -2)))
end

print("=== pack: strings z, c, s ===")
do
  local p = string.pack("z", "hi")
  print(#p, string.unpack("z", p))
  p = string.pack("c5", "ab")
  print(#p, string.unpack("c5", p))
  p = string.pack("<s4", "xyz")
  local s, pos = string.unpack("<s4", p)
  print(s, pos)
end

print("=== pack: packsize rejects variable formats ===")
do
  print(string.packsize("i8"))
  local ok, err = pcall(string.packsize, "z")
  print(ok, (err or ""):match("variable"))
  ok, err = pcall(string.packsize, "s")
  print(ok, (err or ""):match("variable"))
end

print("=== pack: unpack position and leftover ===")
do
  local s = string.pack("<I2I2", 1, 2)
  local a, pos = string.unpack("<I2", s)
  local b, pos2 = string.unpack("<I2", s, pos)
  print(a, b, pos, pos2)
end

print("=== pack: errors ===")
do
  local ok, err = pcall(string.pack, "i1", 999)
  print(ok, (err or ""):match("overflow") or (err or ""):match("does not fit"))
  ok, err = pcall(string.unpack, "<I4", "ab")
  print(ok, (err or ""):match("data string too short") or (err or ""):match("too short"))
  ok, err = pcall(string.pack, "x")
  print(ok, (err or ""):match("invalid format") or err ~= nil)
end

print("ok")
