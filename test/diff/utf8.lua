-- utf8 library, compared against the reference interpreter's own output

print(utf8.charpattern)
print(utf8.char(72, 105))
print(utf8.char(233), utf8.char(0x20AC), utf8.char(0x1F600))
print(#utf8.char(233), #utf8.char(0x20AC), #utf8.char(0x1F600))

local s = "héllo"        -- 'é' is two bytes
local euro = "€100"      -- '€' is three bytes
local emoji = "a😀b"     -- the emoji is four bytes

print(#s, utf8.len(s))
print(#euro, utf8.len(euro))
print(#emoji, utf8.len(emoji))
print(utf8.len(""), utf8.len("abc"))

-- len over a byte range
print(utf8.len(s, 1, -1))
print(utf8.len(s, 2))
print(utf8.len("abc", 2, 2))

-- an invalid sequence reports a position instead of raising
print(utf8.len("\xFF"))
print(utf8.len("ab\xFFcd"))
print(utf8.len("\xC3"))

-- codepoint
print(utf8.codepoint(s))
print(utf8.codepoint(s, 1))
print(utf8.codepoint(s, 2))
print(utf8.codepoint(s, 1, -1))
print(utf8.codepoint(euro, 1, 3))
print(utf8.codepoint(emoji, 2))

-- offset
print(utf8.offset(s, 1), utf8.offset(s, 2), utf8.offset(s, 3))
print(utf8.offset(s, -1))
print(utf8.offset(emoji, 2), utf8.offset(emoji, 3))
print(utf8.offset(s, 1, 2))
print(utf8.offset(s, 0, 3))
print(utf8.offset("abc", 4))

-- codes iterates position/codepoint pairs
for p, c in utf8.codes(s) do io.write(p, "=", c, " ") end
print()
for p, c in utf8.codes(emoji) do io.write(p, "=", c, " ") end
print()
local count = 0
for _ in utf8.codes("") do count = count + 1 end
print("empty codes:", count)

-- errors
print(pcall(utf8.codepoint, "\xFF"))
print(pcall(utf8.char, -1))
print(pcall(function()
  for _ in utf8.codes("ab\xFFcd") do end
end))
print(pcall(utf8.offset, s, 1, 3))
