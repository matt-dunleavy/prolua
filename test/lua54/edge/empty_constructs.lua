-- Test empty language constructs

-- Empty function
function empty() end

-- Empty block
do end

-- Empty if
if false then
elseif false then
else
end

-- Empty loops
while false do end
repeat until true
for i = 1, 0 do end

-- Empty table constructor
local t = {}