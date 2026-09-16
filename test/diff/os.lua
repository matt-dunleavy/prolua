-- os library. Only the deterministic parts are compared: wall-clock values
-- differ between runs, so those are checked as properties instead.

print(type(os.time()), math.type(os.time()))
print(type(os.clock()))
print(os.time() > 1600000000)

-- a fixed broken-down time converts identically in both implementations
local t = os.time({ year = 2024, month = 1, day = 15, hour = 12, min = 30, sec = 45 })
print(type(t))
print(os.date("!%Y-%m-%d %H:%M:%S", 0))
print(os.date("!%Z %z", 0))
print(os.date("!%Y-%m-%d", 1705323045))
print(os.date("!%H:%M:%S", 1705323045))
print(os.date("!%j %w", 1705323045))
print(os.date("!%A %B", 1705323045))
print(os.date("!%a %b", 1705323045))
print(os.date("!%y %p", 1705323045))
print(os.date("!%%"))
print(os.date("!literal text", 0))

-- table form
local d = os.date("!*t", 1705323045)
print(d.year, d.month, d.day, d.hour, d.min, d.sec)
print(d.wday, d.yday, d.isdst)
print(type(os.date("*t")))

-- difftime
print(os.difftime(100, 50))
print(os.difftime(50, 100))
print(type(os.difftime(os.time(), os.time())))

-- round trip through os.time and os.date
local rt = os.time({ year = 2000, month = 6, day = 15, hour = 12, min = 0, sec = 0 })
local back = os.date("*t", rt)
print(back.year, back.month, back.day)

-- getenv
print(os.getenv("PROLUA_DEFINITELY_NOT_SET_12345"))
print(type(os.getenv("PATH")))

-- remove and rename report failure the file-result way
print(os.remove("/tmp/prolua_definitely_missing_98765"))
print(os.rename("/tmp/prolua_definitely_missing_98765", "/tmp/whatever"))

-- tmpname gives a string
print(type(os.tmpname()))

-- errors
print(pcall(os.date, "!%Q", 0))
print(pcall(os.time, { month = 1 }))
