**Why**

<!-- The problem this solves, or the issue it closes. -->

**What changed**

<!-- The behaviour before and after. For anything a script can observe, say what the reference Lua 5.4.8 interpreter does. -->

**How it was tested**

- [ ] `zig fmt --check src build.zig` is clean
- [ ] `zig build test-all` passes
- [ ] `zig build test-puc` passes (VM, tables, GC, codegen or a library changed)
- [ ] `zig build test-cli-valgrind` passes (`src/cli/` or `src/module/` changed)
- [ ] A test covers the change
- [ ] `CHANGELOG.md` has an entry under Unreleased (user-visible change)
