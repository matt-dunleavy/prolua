-- io library. Uses a fixed temporary path so both interpreters do the same
-- work; addresses and handles are never printed, only observable behaviour.

local path = "/tmp/prolua_difftest_io.txt"

-- write a file, then read it back in every format
local f = assert(io.open(path, "w"))
print(io.type(f))
f:write("line one\n", "line two\n", 42, "\n", 3.5, "\n")
f:close()
print(io.type(f))

f = assert(io.open(path, "r"))
print(f:read("l"))
print(f:read("L"))
print(f:read("n"))
print(f:read("n"))
print(f:read("l"))
print(f:read("l"))
f:close()

-- read the whole file
f = assert(io.open(path, "r"))
local all = f:read("a")
print(#all)
print(f:read("a"))
print(f:read("l"))
f:close()

-- the "*" prefixed spellings still work
f = assert(io.open(path, "r"))
print(f:read("*l"))
print(f:read("*L"))
f:close()

-- numeric counts
f = assert(io.open(path, "r"))
print(f:read(4))
print(f:read(4))
print(f:read(0))
f:close()

-- several formats at once
f = assert(io.open(path, "r"))
print(f:read("l", "l"))
f:close()

-- seek
f = assert(io.open(path, "r"))
print(f:seek())
print(f:seek("set", 5))
print(f:read(3))
print(f:seek("cur", 0))
print(f:seek("end"))
f:close()

-- lines as an iterator
local n = 0
for line in io.lines(path) do n = n + 1 end
print("io.lines count:", n)

f = assert(io.open(path, "r"))
n = 0
for line in f:lines() do n = n + 1 end
print("f:lines count:", n)
f:close()

-- append mode
f = assert(io.open(path, "a"))
f:write("appended\n")
f:close()
f = assert(io.open(path, "r"))
print(#f:read("a"))
f:close()

-- opening a missing file returns the nil,message form rather than raising
local h, msg = io.open("/tmp/prolua_definitely_missing_98765", "r")
print(h == nil, type(msg))

-- io.write returns the file, so it chains
io.write("direct ")
io.write("write\n")
print(io.type(io.stdout), io.type(io.stderr), io.type(io.stdin))

-- using a closed file raises
f = assert(io.open(path, "r"))
f:close()
print(pcall(function() return f:read("l") end))
print(io.type(f))

-- io.type on a non-file
print(io.type(42), io.type({}))

os.remove(path)
print(io.open(path))
