-- a small realistic program touching several libraries at once
local Account = {}
Account.__index = Account

function Account.new(owner, balance)
  return setmetatable({ owner = owner, balance = balance or 0, log = {} }, Account)
end

function Account:deposit(n)
  if type(n) ~= "number" or n <= 0 then error("bad deposit: " .. tostring(n)) end
  self.balance = self.balance + n
  table.insert(self.log, string.format("+%.2f", n))
  return self
end

function Account:withdraw(n)
  if n > self.balance then error(("insufficient funds: have %.2f, want %.2f"):format(self.balance, n)) end
  self.balance = self.balance - n
  table.insert(self.log, string.format("-%.2f", n))
  return self
end

function Account:__tostring()
  return string.format("%s: %.2f [%s]", self.owner, self.balance, table.concat(self.log, " "))
end

local a = Account.new("alice", 100)
a:deposit(50):withdraw(30):deposit(5.5)
print(tostring(a))

print(pcall(function() return a:withdraw(1e9) end))
print(pcall(function() return a:deposit(-1) end))

-- word frequency, exercising patterns, sorting and the string library
local text = "the quick brown fox jumps over the lazy dog the fox"
local freq = {}
for w in text:gmatch("%a+") do freq[w] = (freq[w] or 0) + 1 end
local words = {}
for w in pairs(freq) do words[#words + 1] = w end
table.sort(words, function(x, y)
  if freq[x] ~= freq[y] then return freq[x] > freq[y] end
  return x < y
end)
for i = 1, 3 do print(string.format("%-6s %d", words[i], freq[words[i]])) end

-- numeric work
local sum, sq = 0, 0
for i = 1, 100 do sum = sum + i; sq = sq + i * i end
print(sum, sq, math.floor(math.sqrt(sq)), math.max(sum, sq), math.type(sum))

-- closures and varargs
local function counter()
  local n = 0
  return function(...) n = n + select("#", ...) return n end
end
local c = counter()
print(c(1, 2), c(1, 2, 3), c())

-- utf8 + string round trip
local s = "héllo wörld"
print(#s, utf8.len(s), s:upper(), utf8.char(table.unpack({ 104, 105 })))
