-- Test lexical scoping and closures

function make_counter()
    local count = 0
    return function()
      count = count + 1
      return count
    end
  end

  local c1 = make_counter()
  local c2 = make_counter()
  assert(c1() == 1)
  assert(c1() == 2)
  assert(c2() == 1)
  assert(c1() == 3)

  -- Upvalue modification
  function make_pair()
    local shared = 0
    local function get()
      return shared
    end
    local function set(v)
      shared = v
    end
    return get, set
  end

  local get, set = make_pair()
  assert(get() == 0)
  set(10)
  assert(get() == 10)