-- Stress test the parser with complex valid syntax

local _ = ((((((((((1))))))))))
local _ = {{{{{{{{{{}}}}}}}}}}
local _ = function() return function() return function() return 1 end end end

-- Long expression
local result = 1 + 2 * 3 - 4 / 5 + 6 % 7 * 8 - 9 + 10 *
               11 - 12 / 13 + 14 % 15 * 16 - 17 + 18

-- Many parameters
function many_params(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z)
  return a+b+c+d+e+f+g+h+i+j+k+l+m+n+o+p+q+r+s+t+u+v+w+x+y+z
end

-- Complex table
local complex = {
  [function() end] = function() end,
  [{a = 1}] = {b = 2},
  [true] = false,
  [false] = true,
  ["key"] = "value",
  key = "value",
  ["end"] = "keyword as key",
  ["1"] = "string number",
  [1] = "actual number",
}