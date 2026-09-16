-- In-process mutation fuzzer. Usage (from fuzz.sh):
--   prolua fuzz.lua <target> <seed> <count> <logfile> [print] seedfile...
-- Case i uses math.randomseed(seed + i), so a case reproduces under either
-- interpreter (both implement xoshiro256**). The current case number is
-- written to <logfile> before it runs, so a crash names its case. With
-- `print`, each case prints its outcome for a differential comparison.
local target, seed, count, logfile, printmode = arg[1], tonumber(arg[2]), tonumber(arg[3]), arg[4], arg[5] == "print"
local seedfiles = {}
for i = (printmode and 6 or 5), #arg do seedfiles[#seedfiles + 1] = arg[i] end

local sources = {}
for _, name in ipairs(seedfiles) do
  local f = io.open(name, "rb")
  if f then sources[#sources + 1] = f:read("a"); f:close() end
end
assert(#sources > 0, "no seed files")

local show = os.getenv("FUZZ_SHOW") -- print this case's input (print mode)
local shownow = false
local function note(input) -- record a case's input; printed at once when it is the shown case, so a crash cannot hide it
  if shownow then io.stderr:write("input: ", input, "\n"); io.stderr:flush() end
end
local R = math.random
local function pick(t) return t[R(#t)] end

local dictionary = {
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
  "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
  "<const>", "<close>", "...", "::", "//", ">>", "<<", "~=", "==", "<=", ">=", "..", "[[", "]]",
  "--[==[", "]==]", "\"", "'", "\\", "\\z", "\\u{", "\\x", "0x", "1e", ".5", "%", "#", "{", "}", "(", ")",
  "[", "]", ";", ",", "=", "\n", "\t", "\0", "\255", "math.maxinteger", "1<<63", "0x7fffffffffffffff",
  "9223372036854775808", "-9223372036854775808", "1e308", "0/0", "goto l", "::l::", "_ENV", "self",
}

local function mutate(s, rounds)
  for _ = 1, rounds do
    local kind = R(8)
    local n = #s
    if kind == 1 and n > 0 then -- flip a byte
      local i = R(n)
      s = s:sub(1, i - 1) .. string.char(R(0, 255)) .. s:sub(i + 1)
    elseif kind == 2 then -- insert a byte
      local i = R(n + 1)
      s = s:sub(1, i - 1) .. string.char(R(0, 255)) .. s:sub(i)
    elseif kind == 3 and n > 0 then -- delete a span
      local i = R(n)
      s = s:sub(1, i - 1) .. s:sub(i + R(1, 8))
    elseif kind == 4 then -- insert a dictionary token
      local i = R(n + 1)
      s = s:sub(1, i - 1) .. pick(dictionary) .. s:sub(i)
    elseif kind == 5 and n > 1 then -- duplicate a span
      local i, len = R(n), R(1, 32)
      s = s:sub(1, i) .. s:sub(i, i + len) .. s:sub(i + 1)
    elseif kind == 6 and n > 0 then -- truncate
      s = s:sub(1, R(n))
    elseif kind == 7 then -- splice from another seed
      local o = pick(sources)
      if #o > 0 then
        local i, j = R(n + 1), R(#o)
        s = s:sub(1, i - 1) .. o:sub(j, j + R(0, 64)) .. s:sub(i)
      end
    else -- overwrite a span with a repeated byte
      if n > 0 then
        local i = R(n)
        s = s:sub(1, i - 1) .. string.rep(string.char(R(0, 255)), R(1, 16)) .. s:sub(i + R(1, 16))
      end
    end
  end
  return s
end

-- A sandbox for running mutated chunks: no os/io, an instruction budget
local nop = function() end
local sandbox_string = {}
for k, v in pairs(string) do sandbox_string[k] = v end
sandbox_string.dump = nil
local sandbox_math = {}
for k, v in pairs(math) do sandbox_math[k] = v end
sandbox_math.random, sandbox_math.randomseed = nil, nil
local function newenv()
  local env = {
    print = nop, pairs = pairs, ipairs = ipairs, next = next, select = select, type = type,
    tostring = tostring, tonumber = tonumber, pcall = pcall, xpcall = xpcall, error = error, assert = assert,
    setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget, rawset = rawset,
    rawequal = rawequal, rawlen = rawlen, string = sandbox_string, table = table, math = sandbox_math,
    utf8 = utf8, coroutine = coroutine, load = function(s) return load(s, "=inner", "t") end,
  }
  env._G = env
  return env
end
local function runlimited(f)
  local co = coroutine.create(f)
  debug.sethook(co, function() error("instruction budget", 0) end, "", 200000)
  local ok, err = coroutine.resume(co)
  return ok, err
end

local function outcome(ok, err)
  if ok then return "ok" end
  return "err " .. tostring(err):gsub("0x%x+", "0xADDR"):gsub("\n.*", "")
end

local dumps
local function getdumps()
  if dumps then return dumps end
  dumps = {}
  for _, src in ipairs(sources) do
    local f = load(src, "=seed", "t")
    if f then dumps[#dumps + 1] = string.dump(f); dumps[#dumps + 1] = string.dump(f, true) end
  end
  dumps[#dumps + 1] = string.dump(function(a, b, ...) local t = {a, b, ...} for i = 1, #t do t[i] = t[i] * 2 end return t end)
  return dumps
end

local patterns = { "^(%a+)%s*=%s*(%d+)$", "[%w_]+", "%b()", "%f[%w]%w+", "(.-)%.(%a+)$", ".-", "(%d+)%.(%d+)", "[^%s]+",
  "%[(=*)%[", "(%a)%1", "%z", "[%]%-]", "%%", "(", ")", "[a-", "%", "%b", "%f", "%1", "(()", "x*y+z?w-", "[%a%d_]*$",
  "^\0*$", "(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)" }
local formats = { "%d", "%5.2f", "%-10s|", "%q", "%x", "%X", "%o", "%c", "%e", "%g", "%a", "%i", "%u", "%s", "%%", "%10.3s",
  "%+d", "% d", "%#x", "%.0f", "%.99f", "%099d", "%-+ #0123.456d", "%5%", "%.14g", "%q%q", "%s%d%f" }
local packfmts = { "<i4", ">I8", "=d", "!4 i3", "z", "s1", "s4", "c10", "Xi4", "x", "<!8 j n", "b B h H l L", "f", "T", "j", "i16",
  "I3", "!", "<i0", "i17", "s", "c", "c-1", "X", "!3", " ", "z z z", "<I1I2I3I4I5I6I7I8", "d d d" }
local numerals = { "0x", "1e", "0x1p", "1.", ".1", "0x.p1", "1e+", "9223372036854775807", "9223372036854775808", "0xffffffffffffffff",
  "-0x8000000000000000", "1e308", "1e309", "0x1p1024", "inf", "nan", "  12  ", "12a", "0X1.8P+1", "1_0", "١٢", "0b101" }

-- Module paths for the searcher: the fixture project fuzz.sh builds (main
-- module example.com/me/app; one, replaced, with an internal package and a
-- cached dependency four; two, vendored; three, cached) plus paths that
-- are shaped like module paths and lead nowhere
local module_paths = { "example.com/me/app", "example.com/me/app/util", "example.com/me/app/util/deep", "example.com/lib/one",
  "example.com/lib/one/internal", "example.com/lib/one/sub", "example.com/lib/two", "example.com/lib/two/nope",
  "example.com/lib/three", "example.com/lib/four", "example.com/lib/nine", "github.com/matt-dunleavy/http", "pl.utils", "mymod" }
local path_parts = { "internal", "..", ".", "src", "init", "vendor", "", "A", "-x", "x-", "v2", "v0.1.0", "example.com",
  "EXAMPLE.com", "example..com", ".com", "com", "localhost", "x.y.z", "\0", "%", "*", string.rep("x", 63), string.rep("x", 64) }

-- The 5.4 binary chunk format, read into a tree and written back, so a
-- mutation can be structural: a count, a tag, an operand, an upvalue
-- index, a jump, one level down in a nested function. The loader is the
-- one path where a crafted file is the input; byte mutations rarely reach
-- past its header. Only loading is exercised: bytecode is trusted once
-- loaded, in the reference as here, so running a broken chunk proves
-- nothing.
local dump = {}
do
  local function reader(s)
    local r = { s = s, i = 1 }
    function r:byte() local b = self.s:byte(self.i) self.i = self.i + 1 return b end
    function r:bytes(n) local v = self.s:sub(self.i, self.i + n - 1) self.i = self.i + n return v end
    function r:uint() -- 7-bit big-endian varint, last byte has the high bit set
      local x = 0
      repeat
        local b = self:byte()
        x = (x << 7) | (b & 0x7f)
      until b >= 0x80
      return x
    end
    function r:str()
      local n = self:uint()
      if n == 0 then return nil end
      return self:bytes(n - 1)
    end
    return r
  end
  local function writer()
    local w = { parts = {} }
    function w:byte(b) self.parts[#self.parts + 1] = string.char(b & 0xff) end
    function w:bytes(s) self.parts[#self.parts + 1] = s end
    function w:uint(x)
      local out = {}
      repeat
        out[#out + 1] = x & 0x7f
        x = x >> 7
      until x == 0
      for i = #out, 1, -1 do self:byte(out[i] | (i == 1 and 0x80 or 0)) end
    end
    function w:str(s)
      if s == nil then self:uint(0) else self:uint(#s + 1) self:bytes(s) end
    end
    function w:done() return table.concat(self.parts) end
    return w
  end
  local function readf(r)
    local f = {}
    f.source = r:str()
    f.linedefined, f.lastlinedefined = r:uint(), r:uint()
    f.numparams, f.is_vararg, f.maxstacksize = r:byte(), r:byte(), r:byte()
    f.code = {}
    for i = 1, r:uint() do f.code[i] = r:bytes(4) end
    f.k = {}
    for i = 1, r:uint() do
      local t = r:byte()
      local k = { t = t }
      if t == 0x13 or t == 0x03 then k.v = r:bytes(8) -- float / integer
      elseif t == 0x04 or t == 0x14 then k.v = r:str() end -- short / long string
      f.k[i] = k
    end
    f.upvalues = {}
    for i = 1, r:uint() do f.upvalues[i] = { r:byte(), r:byte(), r:byte() } end
    f.p = {}
    for i = 1, r:uint() do f.p[i] = readf(r) end
    f.lineinfo = r:bytes(r:uint())
    f.abslineinfo = {}
    for i = 1, r:uint() do f.abslineinfo[i] = { r:uint(), r:uint() } end
    f.locvars = {}
    for i = 1, r:uint() do f.locvars[i] = { r:str(), r:uint(), r:uint() } end
    f.upvnames = {}
    for i = 1, r:uint() do f.upvnames[i] = r:str() end
    return f
  end
  local function writef(w, f)
    w:str(f.source)
    w:uint(f.linedefined) w:uint(f.lastlinedefined)
    w:byte(f.numparams) w:byte(f.is_vararg) w:byte(f.maxstacksize)
    w:uint(f.ncode or #f.code) for i = 1, #f.code do w:bytes(f.code[i]) end
    w:uint(f.nk or #f.k)
    for i = 1, #f.k do
      local k = f.k[i]
      w:byte(k.t)
      if k.t == 0x13 or k.t == 0x03 then w:bytes(k.v)
      elseif k.t == 0x04 or k.t == 0x14 then w:str(k.v) end
    end
    w:uint(f.nupvalues or #f.upvalues) for i = 1, #f.upvalues do local u = f.upvalues[i] w:byte(u[1]) w:byte(u[2]) w:byte(u[3]) end
    w:uint(f.np or #f.p) for i = 1, #f.p do writef(w, f.p[i]) end
    w:uint(#f.lineinfo) w:bytes(f.lineinfo)
    w:uint(#f.abslineinfo) for i = 1, #f.abslineinfo do w:uint(f.abslineinfo[i][1]) w:uint(f.abslineinfo[i][2]) end
    w:uint(#f.locvars) for i = 1, #f.locvars do local v = f.locvars[i] w:str(v[1]) w:uint(v[2]) w:uint(v[3]) end
    w:uint(#f.upvnames) for i = 1, #f.upvnames do w:str(f.upvnames[i]) end
  end
  function dump.parse(s)
    local r = reader(s)
    local header = r:bytes(4 + 1 + 1 + 6 + 1 + 1 + 1 + 8 + 8) -- signature, version, format, data, sizes, int, float
    local nupvalues = r:byte()
    local f = readf(r)
    return { header = header, nupvalues = nupvalues, f = f }
  end
  function dump.write(t)
    local w = writer()
    w:bytes(t.header) w:byte(t.nupvalues) writef(w, t.f)
    return w:done()
  end
  -- every function in the tree, for a random pick
  function dump.functions(f, out)
    out = out or {}
    out[#out + 1] = f
    for i = 1, #f.p do dump.functions(f.p[i], out) end
    return out
  end
end

local function mutate_chunk(t)
  local fs = dump.functions(t.f)
  local f = pick(fs)
  local op = R(14)
  if op == 1 and #f.code > 0 then -- an operand or opcode
    local i = R(#f.code)
    local ins = f.code[i]
    local j = R(4)
    f.code[i] = ins:sub(1, j - 1) .. string.char(R(0, 255)) .. ins:sub(j + 1)
  elseif op == 2 then f.ncode = #f.code + R(-#f.code, 40) -- count lies
  elseif op == 3 then f.nk = #f.k + R(-#f.k, 40)
  elseif op == 4 then f.nupvalues = #f.upvalues + R(-#f.upvalues, 300)
  elseif op == 5 then f.np = #f.p + R(-#f.p, 40)
  elseif op == 6 and #f.k > 0 then f.k[R(#f.k)].t = R(0, 255) -- a constant tag
  elseif op == 7 and #f.upvalues > 0 then local u = f.upvalues[R(#f.upvalues)] u[R(3)] = R(0, 255)
  elseif op == 8 then f.numparams = R(0, 255)
  elseif op == 9 then f.maxstacksize = R(0, 255)
  elseif op == 10 then f.is_vararg = R(0, 255)
  elseif op == 11 and #f.code > 0 then table.remove(f.code, R(#f.code)) -- a shorter body under the same line info
  elseif op == 12 then f.lineinfo = f.lineinfo:sub(1, R(0, #f.lineinfo))
  elseif op == 13 and #f.locvars > 0 then local v = f.locvars[R(#f.locvars)] v[2], v[3] = R(0, 1 << 20), R(0, 1 << 20)
  else t.nupvalues = R(0, 255) end
end

local cases = {
  chunk = function()
    local s = pick(getdumps())
    local ok, t = pcall(dump.parse, s)
    if ok then
      for _ = 1, R(1, 3) do mutate_chunk(t) end
      local ok2, out = pcall(dump.write, t)
      s = ok2 and out or mutate(s, 2)
    else
      s = mutate(s, 2)
    end
    note(s)
    local f, err = load(s, "=fuzz", "b")
    return f and "loaded" or ("err " .. tostring(err):gsub("\n.*", ""))
  end,
  modules = function()
    local s = pick(module_paths)
    local kind = R(6)
    if kind == 1 then
      s = mutate(s, R(1, 3))
    elseif kind == 2 or kind == 3 then -- component surgery
      local parts = {}
      for c in s:gmatch("[^/]+") do parts[#parts + 1] = c end
      local op = R(5)
      if op == 1 then table.insert(parts, R(#parts + 1), pick(path_parts))
      elseif op == 2 and #parts > 0 then table.remove(parts, R(#parts))
      elseif op == 3 and #parts > 1 then local i, j = R(#parts), R(#parts) parts[i], parts[j] = parts[j], parts[i]
      elseif op == 4 then parts[#parts + 1] = parts[R(#parts)] or "x"
      else parts[1] = pick(path_parts) end
      s = table.concat(parts, "/")
      if R(4) == 1 then s = "/" .. s end
      if R(4) == 1 then s = s .. "/" end
    elseif kind == 4 then -- very long
      s = (s .. "/"):rep(R(1, 40)) .. "x"
    end
    -- a third of the time the require comes from a file inside the replaced
    -- module, where its internal package is allowed
    local inside = R(3) == 1
    note((inside and "inside " or "") .. s)
    local ok, r
    if inside then
      local f = assert(io.open("../one/src/probe.lua", "w"))
      f:write(string.format("return require(%q)", s))
      f:close()
      ok, r = pcall(dofile, "../one/src/probe.lua")
    else
      ok, r = pcall(require, s)
    end
    package.loaded[s] = nil
    return outcome(ok, r) .. " " .. type(r)
  end,
  source = function()
    local s = pick(sources)
    if R(3) == 1 then local i = R(#s) s = s:sub(i, i + R(1, 400)) end
    s = mutate(s, R(1, 6))
    note(s)
    local f, err = load(s, "=fuzz", "t")
    if not f then return "err " .. (err:gsub("\n.*", "")) end
    local ok, e = runlimited(function() return setmetatable and load(s, "=fuzz", "t", newenv())() end)
    return outcome(ok, e)
  end,
  binary = function()
    local s = mutate(pick(getdumps()), R(1, 4))
    note(s)
    local f, err = load(s, "=fuzz", "b")
    return f and "loaded" or ("err " .. tostring(err):gsub("\n.*", ""))
  end,
  pattern = function()
    local pat = mutate(pick(patterns), R(0, 3))
    local subj = mutate(pick(sources):sub(1, R(0, 200)), R(0, 3))
    local which = R(4)
    note(string.format("%q %q %d", subj, pat, which))
    local ok, a, b = pcall(which == 1 and string.find or which == 2 and string.match or which == 3 and string.gsub or string.gmatch,
      subj, pat, which == 3 and "%1%0" or nil)
    if ok and which == 4 then ok, a = pcall(function() local n = 0 for _ in a do n = n + 1 if n > 1000 then break end end return n end) end
    return outcome(ok, a) .. " " .. tostring(ok and (type(a) == "string" and #a or a) or "")
  end,
  format = function()
    local fmt = mutate(pick(formats), R(0, 3))
    local args = { R(-1e6, 1e6), R() * 1e10, pick(sources):sub(1, R(0, 30)), math.maxinteger, -0.0, 1 / 0, 0 / 0 }
    local ok, r = pcall(string.format, fmt, table.unpack(args, 1, R(0, #args)))
    return outcome(ok, r) .. " " .. (ok and #r or "")
  end,
  pack = function()
    local fmt = mutate(pick(packfmts), R(0, 3))
    if R(2) == 1 then
      note(string.format("pack %q", fmt))
      local ok, r = pcall(string.pack, fmt, R(-1e9, 1e9), R() * 1e5, "abc", R(-1e18, 1e18), 7, 8, 9, 10)
      return outcome(ok, r) .. " " .. (ok and #r or "")
    else
      local data = mutate(pick(sources):sub(1, R(0, 64)), R(0, 4))
      local init = R(1, 8)
      note(string.format("unpack %q %q %d", fmt, data, init))
      local ok, r = pcall(string.unpack, fmt, data, init)
      return outcome(ok, r) .. " " .. tostring(ok and r or "")
    end
  end,
  numeral = function()
    local s = mutate(pick(numerals), R(0, 3))
    local a = tonumber(s)
    local f = load("return " .. s, "=n", "t")
    local ok, b = false, nil
    if f then ok, b = pcall(f) end
    return string.format("%s %s %s %s", tostring(a), math.type(a) or "-", tostring(ok and b), tostring(ok and math.type(b) or "-"))
  end,
  utf8 = function()
    local s = mutate(pick(sources):sub(1, R(0, 40)), R(0, 4))
    local r = {}
    for _, f in ipairs { utf8.len, function(x) return utf8.codepoint(x, 1, -1) end, function(x) return utf8.offset(x, R(-3, 3)) end,
      function(x) local n = 0 for _ in utf8.codes(x) do n = n + 1 end return n end, function(x) return utf8.char(R(0, 0x7FFFFFFF)) end,
      function(x) return utf8.len(x, R(-5, 5), R(-5, 5), R(2) == 1) end } do
      local ok, v = pcall(f, s)
      r[#r + 1] = outcome(ok, v) .. (ok and (" " .. tostring(v)) or "")
    end
    return table.concat(r, " | ")
  end,
}
local case = assert(cases[target], "unknown target " .. tostring(target))

local log = assert(io.open(logfile, "w"))
for i = 1, count do
  log:seek("set", 0); log:write(tostring(i), "\n"); log:flush()
  math.randomseed(seed + i)
  shownow = show == tostring(i)
  local ok, r = pcall(case)
  if printmode then print(i, ok and r or ("HARNESS " .. tostring(r))) end
end
log:close()
print(target, "done", count, "cases")
