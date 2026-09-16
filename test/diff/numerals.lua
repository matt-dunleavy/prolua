-- hexadecimal numerals: rounding of long mantissas, exponents, limits and malformed forms
local cases = {}
for _, n in ipairs{1, 12, 13, 14, 15, 16, 17, 20, 30, 150, 300, 500} do cases[#cases + 1] = "0x" .. string.rep("f", n) .. ".0" end
for _, s in ipairs{"0x1.8p1", "0xA.8", "0x.8", "0x8.", "0x1p-1074", "0x1p-1075", "0x1.8p-1074", "0x1p1023", "0x1p1024", "0x1.fffffffffffff8p1023", "0x1.fffffffffffff7p1023", "0x123456789abcdef0123456789p-40", "0x0.0000000000000000000000001p0", "0x1.00000000000008p0", "0x1.00000000000018p0", "0x1.000000000000081p0", "0x1p+", "0xp1", "0x.p1", "0x1e", "0x1E+2", "0X1P3", "0x1.p0", "-0x1.8p1", "0x1p99999999999", "0x1p-99999999999", "0x00000000000000000000000000001.8", "0xfedcba9876543210fedcba9876543210p-100"} do cases[#cases + 1] = s end
for _, s in ipairs(cases) do
  local v = tonumber(s)
  print(#s > 40 and (s:sub(1, 20) .. "...") or s, v and string.format("%a", v) or v, math.type(v))
end
