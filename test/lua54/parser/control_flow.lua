-- Test control structures

-- If statements
if true then
    print("then")
  end

  if x > 0 then
    print("positive")
  elseif x < 0 then
    print("negative")
  else
    print("zero")
  end

  -- While loops
  local i = 0
  while i < 10 do
    i = i + 1
  end

  -- Repeat loops
  repeat
    i = i - 1
  until i == 0

  -- For loops
  for i = 1, 10 do
    print(i)
  end

  for i = 1, 10, 2 do
    print(i)
  end

  for i = 10, 1, -1 do
    print(i)
  end

  -- Generic for
  for k, v in pairs(t) do
    print(k, v)
  end

  for i, v in ipairs(t) do
    print(i, v)
  end

  -- Do blocks
  do
    local scoped = 1
  end

  -- Break
  while true do
    if condition then break end
  end

  -- Goto and labels
  ::start::
  if not ready then
    goto start
  end
  goto finish
  print("skipped")
  ::finish::