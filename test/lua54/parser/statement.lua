-- Test statement parsing

-- Empty statements
;
;;

-- Local declarations
local x
local x, y
local x = 1
local x, y = 1, 2
local x, y, z = 1, 2  -- z gets nil

-- Assignments
x = 1
x, y = 1, 2
x, y = y, x  -- swap
t.field = 1
t["key"] = 2
t[1] = 3