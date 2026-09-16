-- Test metatables and metamethods

-- Arithmetic metamethods
local mt = {
    __add = function(a, b)
      return {value = a.value + b.value}
    end,
    __sub = function(a, b)
      return {value = a.value - b.value}
    end,
    __mul = function(a, b)
      return {value = a.value * b.value}
    end,
    __tostring = function(t)
      return "Value: " .. t.value
    end
  }

  local a = setmetatable({value = 10}, mt)
  local b = setmetatable({value = 5}, mt)
  local c = a + b
  assert(c.value == 15)

  -- Index/newindex metamethods
  local proxy = {}
  local data = {}
  setmetatable(proxy, {
    __index = function(t, k)
      print("Getting", k)
      return data[k]
    end,
    __newindex = function(t, k, v)
      print("Setting", k, "to", v)
      data[k] = v
    end
  })

  proxy.x = 10
  local y = proxy.x