-- Test Unicode handling

local unicode_strings = {
    "Hello, 世界",
    "Привет мир",
    "مرحبا بالعالم",
    "🚀🌍🌎🌏",
    "𝕳𝖊𝖑𝖑𝖔",  -- Mathematical alphanumeric symbols
  }

  for _, s in ipairs(unicode_strings) do
    print(s, #s, string.len(s))  -- byte length
    print(utf8.len(s))  -- character count
  end