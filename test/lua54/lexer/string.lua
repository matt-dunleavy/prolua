-- Test string literals
local s1 = "hello world"
local s2 = 'hello world'
local s3 = ""
local s4 = ''
local s5 = "line1\nline2"
local s6 = "tab\there"
local s7 = "quote\" and \'"
local s8 = 'quote\' and \"'
local s9 = "backslash\\"
local s10 = "\a\b\f\n\r\t\v"
local s11 = "\x41\x42\x43"  -- "ABC"
local s12 = "\65\66\67"     -- "ABC"
local s13 = "\u{41}\u{1F600}"  -- "A😀"
local s14 = "line1\z
             line2"  -- z escape
local s15 = [[
  Long string literal
  with multiple lines
]]
local s16 = [=[
  Long string with [[nested]] brackets
]=]
local s17 = [==[
  Even more nesting [=[test]=]
]==]