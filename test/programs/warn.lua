-- Lua 5.4: warn
-- Warnings start off. A single argument that begins with '@' is a control
-- message: "@on" and "@off" switch printing; any other control is ignored.
-- Several string arguments are concatenated into one "Lua warning: ..." line
-- on stderr. A failing __gc becomes a warning, not an error.

print("=== warn: off by default ===")
warn("SHOULD NOT APPEAR")
print("still here")

print("=== warn: @on, pieces concatenate, @off ===")
warn("@on")
warn("hello ", "world")
warn("one")
warn("@off")
warn("SHOULD NOT APPEAR AFTER OFF")
print("after off")

print("=== warn: only a lone @... argument is control ===")
warn("@on")
warn("@off", "XXX", "@off")
warn("@off")
warn("@on", "YYY", "@on")
warn("@off")
print("mixed controls done")

print("=== warn: unknown control is ignored ===")
warn("@on")
warn("@allow")
warn("after unknown")
warn("@off")

print("=== warn: empty first piece is not control ===")
warn("@on")
warn("", "@on")
warn("@off")

print("=== warn: argument errors ===")
do
  local ok, err = pcall(warn)
  print(ok, (err or ""):match("string expected"))
  ok, err = pcall(warn, 1)
  print(ok, (err or ""):match("string expected"))
  ok, err = pcall(warn, "ok", {})
  print(ok, (err or ""):match("string expected"))
end

print("=== warn: error in __gc is a warning ===")
do
  warn("@on")
  local u = setmetatable({}, {
    __gc = function()
      error("gc boom", 0)
    end,
  })
  u = nil
  collectgarbage()
  collectgarbage()
  warn("@off")
end

print("ok")
