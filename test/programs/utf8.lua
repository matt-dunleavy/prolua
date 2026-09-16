-- Lua 5.4: utf8
-- len reports a position instead of raising on invalid UTF-8. offset returns
-- only the start index (5.5 added an end index). codes is strict by default;
-- a true second argument is lax.

print("=== utf8: char, len, charpattern ===")
do
  print(utf8.charpattern == "[\0-\x7F\xC2-\xFD][\x80-\xBF]*")
  print(utf8.char(72, 105))
  print(utf8.char(0xE9), #utf8.char(0x20AC), #utf8.char(0x1F600))
  print(utf8.len("abc"), utf8.len("héllo"), utf8.len(""))
end

print("=== utf8: invalid sequences report a position ===")
do
  print(utf8.len("\xFF"))
  print(utf8.len("ab\xFFcd"))
  print(utf8.len("\xC3"))
end

print("=== utf8: offset is 5.4 (one result) ===")
do
  local s = "héllo"
  print(utf8.offset(s, 1), utf8.offset(s, 2), utf8.offset(s, 3))
  print(select("#", utf8.offset(s, 2)))
  print(utf8.offset(s, -1))
  print(utf8.offset("abc", 4))
  local ok, err = pcall(utf8.offset, s, 1, 3)
  print(ok, (err or ""):match("continuation byte") or (err or ""):match("invalid"))
end

print("=== utf8: codes ===")
do
  local acc = {}
  for p, c in utf8.codes("aéb") do
    acc[#acc + 1] = p .. "=" .. c
  end
  print(table.concat(acc, ","))
  local ok, err = pcall(function()
    for _ in utf8.codes("ab\xFFcd") do
    end
  end)
  print(ok, (err or ""):match("invalid UTF%-8"))
end

print("=== utf8: lax codes accept an overlong / surrogate-range point ===")
do
  -- U+D800 encoded as ed a0 80 is invalid in strict mode, allowed when lax
  local s = "\xED\xA0\x80"
  local ok = pcall(function()
    for _ in utf8.codes(s) do
    end
  end)
  print(ok)
  local n, last = 0, nil
  for p, c in utf8.codes(s, true) do
    n = n + 1
    last = c
  end
  print(n, last)
end

print("ok")
