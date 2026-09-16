-- Simple Lua test file for lexer
local x = 42
local name = "Prolua"

function greet(person)
    print("Hello, " .. person .. "!")
end

if x > 40 then
    greet(name)
else
    print("x is too small")
end

-- Test various tokens
local nums = {1, 2.5, 0xFF, 3.14e-2}
local ops = x + 10 * 2 / 5 - 1
local cmp = x >= 40 and x <= 50
