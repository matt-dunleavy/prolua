-- Sizes no allocation is attempted for: the check comes before the memory
-- (an empty string repeated a huge count is not here: the reference loops
-- over the count doing nothing, for minutes)
print(pcall(string.rep, "x", 1 << 40))
print(pcall(string.rep, "xy", 1 << 62))
print(pcall(string.rep, "x", math.maxinteger))
print(pcall(string.rep, "ab", 1 << 40, ","))
print(pcall(string.rep, "x", -5))
