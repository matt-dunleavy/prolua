-- Test string library

-- Basic operations
assert(string.len("hello") == 5)
assert(string.upper("hello") == "HELLO")
assert(string.lower("HELLO") == "hello")
assert(string.reverse("hello") == "olleh")
assert(string.rep("ab", 3) == "ababab")

-- Substrings
assert(string.sub("hello", 2, 4) == "ell")
assert(string.sub("hello", -3) == "llo")

-- Formatting
assert(string.format("%d %s %.2f", 42, "test", 3.14159) == "42 test 3.14")
assert(string.format("%x", 255) == "ff")
assert(string.format("%q", 'hello "world"') == '"hello \\"world\\""')

-- Byte operations
assert(string.byte("ABC") == 65)
assert(string.byte("ABC", 2) == 66)
local b1, b2, b3 = string.byte("ABC", 1, 3)
assert(b1 == 65 and b2 == 66 and b3 == 67)
assert(string.char(65, 66, 67) == "ABC")