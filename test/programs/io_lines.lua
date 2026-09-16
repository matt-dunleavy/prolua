-- Lua 5.4: io.lines is to-be-closed
-- io.lines(filename) opens the file and returns a 4th generic-for value that
-- is closed when the loop ends (including break). file:lines() does not close
-- the handle.

local path = os.tmpname()
do
  local f = assert(io.open(path, "w"))
  f:write("one\n", "two\n", "three\n")
  f:close()
end

print("=== io.lines: counts lines and can be used twice ===")
do
  local n = 0
  for line in io.lines(path) do n = n + 1 end
  print(n)
  local acc = {}
  for line in io.lines(path) do acc[#acc + 1] = line end
  print(table.concat(acc, ","))
end

print("=== io.lines: 4th result is a file, closed at EOF ===")
do
  local it, st, ctrl, closer = io.lines(path)
  print(io.type(closer), getmetatable(closer).__name)
  local n = 0
  while true do
    local line = it(st, ctrl)
    if line == nil then break end
    n = n + 1
  end
  print(n, io.type(closer))
end

print("=== io.lines: break still closes ===")
do
  local it, st, ctrl, closer = io.lines(path)
  for line in it, st, ctrl, closer do
    print(line)
    break
  end
  print(io.type(closer))
end

print("=== file:lines does not close the handle ===")
do
  local f = assert(io.open(path, "r"))
  local n = 0
  for _ in f:lines() do n = n + 1 end
  print(n, io.type(f))
  f:close()
  print(io.type(f))
end

os.remove(path)
print("ok")
