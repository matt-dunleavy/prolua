-- strings, patterns and tables: a pure-Lua JSON encoder and decoder round trip
local encode
local escape_map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function encode_string(s) return '"' .. s:gsub('[%c"\\]', function(c) return escape_map[c] or string.format("\\u%04x", c:byte()) end) .. '"' end
local function encode_table(t, out)
  if #t > 0 or next(t) == nil then
    out[#out + 1] = "["
    for i = 1, #t do if i > 1 then out[#out + 1] = "," end encode(t[i], out) end
    out[#out + 1] = "]"
  else
    out[#out + 1] = "{"
    local first = true
    for k, v in pairs(t) do
      if not first then out[#out + 1] = "," end
      first = false
      out[#out + 1] = encode_string(tostring(k)); out[#out + 1] = ":"; encode(v, out)
    end
    out[#out + 1] = "}"
  end
end
encode = function(v, out)
  local tv = type(v)
  if tv == "table" then encode_table(v, out)
  elseif tv == "string" then out[#out + 1] = encode_string(v)
  elseif tv == "number" then out[#out + 1] = (math.type(v) == "integer") and tostring(v) or string.format("%.14g", v)
  elseif tv == "boolean" then out[#out + 1] = tostring(v)
  else out[#out + 1] = "null" end
end
local function json_encode(v) local out = {} encode(v, out) return table.concat(out) end

local decode
local function skip(s, i) return s:find("[^ \n\r\t]", i) or #s + 1 end
local unescape = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
local function decode_string(s, i)
  local j = i + 1
  local parts = {}
  while true do
    local k = s:find('["\\]', j)
    parts[#parts + 1] = s:sub(j, k - 1)
    local c = s:sub(k, k)
    if c == '"' then return table.concat(parts), k + 1 end
    local e = s:sub(k + 1, k + 1)
    if e == "u" then parts[#parts + 1] = string.char(tonumber(s:sub(k + 2, k + 5), 16)); j = k + 6
    else parts[#parts + 1] = unescape[e]; j = k + 2 end
  end
end
decode = function(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      local k; k, i = decode_string(s, skip(s, i))
      i = skip(s, i); assert(s:sub(i, i) == ":"); i = i + 1
      t[k], i = decode(s, i)
      i = skip(s, i); c = s:sub(i, i); i = i + 1
      if c == "}" then return t, i end
    end
  elseif c == "[" then
    local t, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      n = n + 1; t[n], i = decode(s, i)
      i = skip(s, i); c = s:sub(i, i); i = i + 1
      if c == "]" then return t, i end
    end
  elseif c == '"' then return decode_string(s, i)
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if num and #num > 0 then return tonumber(num), i + #num end
    if s:sub(i, i + 3) == "true" then return true, i + 4 end
    if s:sub(i, i + 4) == "false" then return false, i + 5 end
    if s:sub(i, i + 3) == "null" then return nil, i + 4 end
    error("bad json at " .. i)
  end
end
local function json_decode(s) return (decode(s, 1)) end

local t0 = os.clock()
local doc = { name = "prolua", version = 2, tags = { "lua", "zig", "vm" }, ok = true, ratio = 0.9375, nested = {} }
for i = 1, 200 do doc.nested[i] = { id = i, label = "item " .. i .. " \"quoted\"\n", values = { i * 1.5, i * 2, i * 3 }, flags = { a = i % 2 == 0, b = false } } end
local total = 0
local text
for round = 1, 100 do
  text = json_encode(doc)
  local back = json_decode(text)
  total = total + #back.nested + #text
  doc = back
end
io.write(string.format("len=%d total=%d  %.3fs\n", #text, total, os.clock() - t0))
