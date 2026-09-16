-- The command line starts the collector in generational mode, as lua.c
-- does; switching modes reports the previous one
print(collectgarbage("incremental"))
print(collectgarbage("generational"))
print(collectgarbage("generational"))
print(collectgarbage("incremental"))
print(collectgarbage("count") > 0, collectgarbage("isrunning"))
-- After a bad major collection (a heap that keeps growing) the collector
-- runs a full cycle or two before returning to young collections, and is
-- generational throughout as far as a script can tell
local grow = {}
for i = 1, 300000 do grow[i] = { i } end
print(collectgarbage("generational"))
for i = 1, 300000 do grow[i] = nil end
collectgarbage()
print(collectgarbage("incremental"), collectgarbage("generational"))
