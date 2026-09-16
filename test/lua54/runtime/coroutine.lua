-- Test coroutines

local co = coroutine.create(function(initial)
    local x = initial
    while true do
      x = coroutine.yield(x * 2)
    end
  end)

  local ok, result = coroutine.resume(co, 10)
  assert(ok and result == 20)
  ok, result = coroutine.resume(co, 5)
  assert(ok and result == 10)

  -- Producer-consumer pattern
  function producer()
    for i = 1, 5 do
      coroutine.yield(i * i)
    end
  end

  function consumer(prod)
    while true do
      local ok, value = coroutine.resume(prod)
      if not ok then break end
      if value then
        print("Consumed:", value)
      else
        break
      end
    end
  end

  consumer(coroutine.create(producer))