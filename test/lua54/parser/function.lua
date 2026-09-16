-- Test function definitions and calls

-- Simple function
function add(a, b)
    return a + b
  end

  -- Local function
  local function multiply(a, b)
    return a * b
  end

  -- Anonymous function
  local divide = function(a, b)
    return a / b
  end

  -- Vararg function
  function printf(fmt, ...)
    print(string.format(fmt, ...))
  end

  -- Multiple returns
  function divmod(a, b)
    return a // b, a % b
  end

  -- No parameters
  function hello()
    print("Hello!")
  end

  -- Nested functions
  function outer(x)
    local function inner(y)
      return x + y
    end
    return inner
  end

  -- Method syntax
  local obj = {}
  function obj:method(x)
    return self.value + x
  end

  -- Tail calls
  function factorial(n, acc)
    acc = acc or 1
    if n <= 1 then
      return acc
    end
    return factorial(n - 1, n * acc)
  end