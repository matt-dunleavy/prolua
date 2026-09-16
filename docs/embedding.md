# Embedding Prolua

Prolua is a Zig library first and a stand-alone interpreter second.
`src/prolua.zig` is the library root; the command line in `src/cli/` is
built on it like any other embedder. `examples/embed.zig` is the complete program this
page walks through; `zig build example` builds and runs it.

## Depending on the package

Prolua is a Zig package (`build.zig.zon`, name `prolua`). From a
consuming project:

```
zig fetch --save <url-or-path-to-prolua>
```

then in the consumer's `build.zig`:

```zig
const prolua = b.dependency("prolua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("prolua", prolua.module("prolua"));
exe.root_module.link_libc = true; // the interpreter links libc
```

and in the code:

```zig
const prolua = @import("prolua");
const api = prolua.api;
const LuaState = prolua.LuaState;
```

Inside this repository the same module is what `src/cli/` and
`examples/` import.

## The shape of the API

`prolua.api` follows the C API's `lua_*` / `luaL_*` shape: a value stack
per state, positive indices from the bottom of the current function's
frame, negative from the top, and the same function names in camel case
(`pushInteger`, `toString`, `getGlobal`, `setField`, `pcall`, ...). The
differences from C are the ones Zig makes natural:

- Functions that can fail return Zig errors (`!void`, `!i32`); a Lua error
  raised inside a call comes back as `error.LuaError` with the error
  object on the stack, exactly where `lua_pcall` leaves it.
- Native functions are `fn (*LuaState) anyerror!i32` (`prolua.state.CFunction`):
  read arguments with `api.checkInteger(L, 1)`, `api.checkString(L, 2)`,
  ..., push results, return their count. Raise an error by returning one;
  `api.argError` and the `check*` helpers produce the reference's messages
  ("bad argument #1 to 'add' (number expected, got string)").
- Strings cross the boundary as `[]const u8` slices that point into the
  interned string object; they stay valid while the value is on the stack
  or otherwise reachable.
- `LuaState.init(allocator, null)` creates a state on the given allocator;
  `L.deinit()` runs pending finalizers and frees everything the state
  allocated, through the same allocator.

## The example, step by step

```zig
const L = try LuaState.init(init.gpa, null);
defer L.deinit();
try prolua.lib.openLibs(L);           // all ten standard libraries
```

Register a native function as a global:

```zig
fn add(L: *LuaState) !i32 {
    const a = try api.checkInteger(L, 1);
    const b = try api.checkInteger(L, 2);
    try api.pushInteger(L, a + b);
    return 1;
}
...
try api.pushCFunction(L, add);
try api.setGlobal(L, "add");
```

Compile and run a chunk. `loadString` (or `loadBuffer` for binary chunks,
`loadFile` for files) leaves the compiled function on the stack, or an
error message and a status other than `.ok`; `pcall` runs it protected:

```zig
if (api.loadString(L, chunk, "=example") != .ok) {
    // api.toString(L, -1).? is the compile error message
}
if (api.pcall(L, 0, 1, 0) != .ok) {
    // api.toString(L, -1).? is the runtime error message
}
const total = api.toInteger(L, -1).?;
api.pop(L, 1);
```

Call a Lua function from Zig: push the function, push its arguments, call
with the argument and result counts, read the results:

```zig
_ = try api.getGlobal(L, "greet");
try api.pushString(L, "embedder");
try api.call(L, 1, 1);               // or pcall to catch errors
const s = api.toString(L, -1).?;
api.pop(L, 1);
```

Errors from a protected call are values on the stack, with the message
handler (if any) applied, as in C:

```zig
const status = api.pcall(L, 2, 1, 0);   // .ok, .errrun, .errmem, .errerr
```

## Standard I/O and the environment

`print`, `io.write` and the rest go through `prolua.stdio`, which owns one
`std.Io` instance for the process; an embedder that wants the same
buffered writers can use `prolua.stdio.stdoutWriter`. `os.execute` and
`io.popen` read the process environment and spawn through `/bin/sh` on
POSIX systems.

## Threads and coroutines

Lua coroutines are ordinary objects (`coroutine.create` from Lua,
`api.newThread` from Zig). A native function that calls back into Lua
with `api.call` makes the running coroutine non-yieldable across that
call, which produces the reference's "attempt to yield across a C-call
boundary"; `api.callk` / `api.pcallk` with a continuation are the
yieldable forms, as in C.

## What is not there

- No C ABI. The native function signature is Zig's; C code cannot call
  into Prolua without a Zig shim. `state.CFunction` and the API could be
  wrapped with `export fn` when that is needed.
- No `lua_newstate` with a custom `lua_Alloc`: the state takes a
  `std.mem.Allocator` and wraps it in the collector's accounting allocator.
- The API documentation is the doc comments in `src/api.zig`; `zig build
  docs` renders them into `zig-out/docs`.
