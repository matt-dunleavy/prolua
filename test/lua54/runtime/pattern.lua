-- Test string patterns

assert(string.find("hello world", "world") == 7)
assert(string.match("test123", "%d+") == "123")
assert(string.gsub("hello world", "l", "L", 1) == "heLlo world")

local date = "2024-12-30"
local year, month, day = string.match(date, "(%d+)-(%d+)-(%d+)")
assert(year == "2024" and month == "12" and day == "30")

-- Character classes
assert(string.match("abc123", "%a+") == "abc")
assert(string.match("abc123", "%d+") == "123")
assert(string.match("hello world", "%s") == " ")