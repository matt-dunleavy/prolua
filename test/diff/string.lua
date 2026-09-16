-- string library, checked against the reference interpreter's own output

local function show(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do
    local v = select(i, ...)
    parts[#parts + 1] = tostring(v)
  end
  print(table.concat and table.concat(parts, "\t") or parts[1])
end

-- basics
print(string.len("hello"), ("hello"):len())
print(string.sub("hello world", 1, 5))
print(string.sub("hello", -3), string.sub("hello", 2, -2), string.sub("hello", 10))
print(string.sub("hello", 0), string.sub("hello", -100, 100))
print(string.upper("aBc"), string.lower("aBc"), string.reverse("abc"))
print(string.rep("ab", 3), string.rep("a", 3, "-"), string.rep("a", 0))
print(string.byte("A"), string.byte("abc", 2), string.byte("abc", -1))
print(string.byte("abc", 1, 3))
print(string.char(72, 105))
print(("x"):upper(), ("%d"):format(7))

-- find
print(string.find("hello world", "world"))
print(string.find("hello", "ll"))
print(string.find("hello", "xyz"))
print(string.find("a.b", ".", 1, true))
print(string.find("hello", "l+"))
print(string.find("hello", "(l+)"))
print(string.find("hello", "o", -2))

-- match and captures
print(string.match("hello world", "(%w+) (%w+)"))
print(string.match("key=value", "(%w+)=(%w+)"))
print(string.match("2024-01-15", "(%d+)-(%d+)-(%d+)"))
print(string.match("hello", "()ll()"))
print(string.match("  trim  ", "^%s*(.-)%s*$"))
print(string.match("abc", "^a"), string.match("abc", "^b"))
print(string.match("abc", "c$"), string.match("abc", "a$"))

-- classes and sets
print(string.match("abc123", "%a+"), string.match("abc123", "%d+"))
print(string.match("a1!", "%p"), string.match("hello", "[el]+"))
print(string.match("hello", "[^he]+"), string.match("a-b", "[a%-b]+"))
print(string.match("x]y", "[]]"), string.match("abc", "[a-c]+"))
print(string.match("HeLLo", "%u+"), string.match("HeLLo", "%l+"))
print(string.match("a b", "%s"), string.match(" \t", "%s+") ~= nil)

-- balanced, frontier, backrefs
print(string.match("(nested (x)) rest", "%b()"))
print(string.match("THE (quick) fox", "%f[%a]%a+"))
print(string.match("abcabc", "(abc)%1"))
print(string.match("aa", "(a)%1"))

-- quantifiers
print("[" .. tostring(string.match("aaa", "a-")) .. "]")
print(string.match("aaa", "a*"), string.match("aaa", "a+"))
print(string.match("b", "a?b"), string.match("ab", "a?b"))

-- gsub
print(string.gsub("hello world", "o", "0"))
print(string.gsub("hello", "l", "L", 1))
print(string.gsub("hello world", "(%w+)", "<%1>"))
print(string.gsub("abc", "%w", "%0%0"))
print(string.gsub("hello", "l+", function(s) return "[" .. #s .. "]" end))
print(string.gsub("$name", "%$(%w+)", { name = "Lua" }))
print(string.gsub("abc", "x", "y"))
print(string.gsub("hello", "", "-"))
print(string.gsub("abc", "%w", function() return nil end))
print(string.gsub("abc", "b", "%%"))
print(string.gsub("hello world", "^hello", "HI"))

-- gmatch
local acc = {}
for w in string.gmatch("one two three", "%a+") do acc[#acc + 1] = w end
print(#acc, acc[1], acc[3])
for k, v in string.gmatch("a=1, b=2", "(%w+)=(%w+)") do print(k, v) end
local cnt = 0
for _ in string.gmatch("abc", "a*") do cnt = cnt + 1 if cnt > 20 then break end end
print("empty-match iterations:", cnt)

-- format
print(string.format("%d|%5d|%-5d|%05d", 42, 42, 42, 42))
print(string.format("%d|%+d|% d", -42, 42, 42))
print(string.format("%x|%X|%#x|%o", 255, 255, 255, 8))
print(string.format("%c%c", 72, 105))
print(string.format("[%s][%10s][%-10s][%.2s]", "hi", "hi", "hi", "hello"))
print(string.format("%f|%.2f|%.0f", 1.5, 3.14159, 2.5))
print(string.format("%e|%E", 1234.5, 1234.5))
print(string.format("%g|%g|%g|%g", 0.0001, 100000, 1e20, 0.5))
print(string.format("%%|%s=%d", "x", 1))
print(string.format("%q", 'he"llo\n\\x'))
print(string.format("%s|%d", 42, "42"))
print(string.format("%.3d", 5))
print(string.format("%10.3f|", 3.14159))

-- errors are catchable and carry the same shape
print(pcall(string.rep))
print(pcall(string.format, "%d", "notanumber"))
print(pcall(string.match, "x", "[unclosed"))
print(pcall(string.match, "x", "%"))
print(pcall(string.gsub, "x", "x", true))
print(pcall(string.match, "x", "(x"))
print(pcall(string.char, 999))
