BINARY  := prolua
VERSION := $(shell cat VERSION)
ZIG     := zig
FLAGS   :=

.PHONY: all build release release-safe run run-args
all: build

build:                     ## Debug build into zig-out/bin
	$(ZIG) build $(FLAGS)

release:                   ## ReleaseFast: the build to measure or ship
	$(ZIG) build -Doptimize=ReleaseFast $(FLAGS)

release-safe:              ## ReleaseSafe: bounds and overflow checked
	$(ZIG) build -Doptimize=ReleaseSafe $(FLAGS)

run:                       ## Build and start the REPL
	$(ZIG) build run $(FLAGS)

run-args:                  ## Build and run with ARGS="run file.lua"
	$(ZIG) build run $(FLAGS) -- $(ARGS)

.PHONY: test test-runtime test-unit test-all test-diff test-cli test-puc test-corpus fuzz bench
test:                      ## Leaf-module unit tests
	$(ZIG) build test $(FLAGS)

test-runtime:              ## Runtime unit tests
	$(ZIG) build test-runtime $(FLAGS)

test-unit:                 ## Leaf, runtime and command-line unit tests
	$(ZIG) build test-unit $(FLAGS)

test-all:                  ## Unit tests, differential scripts on two builds, command-line cases
	$(ZIG) build test-all $(FLAGS)

test-diff:                 ## Differential scripts against the reference lua
	$(ZIG) build test-diff $(FLAGS)

test-cli:                  ## The command-line suite
	$(ZIG) build test-cli $(FLAGS)

test-puc:                  ## The official Lua 5.4.8 suite
	$(ZIG) build test-puc $(FLAGS)

test-corpus:               ## Real projects' test suites under both interpreters
	$(ZIG) build test-corpus $(FLAGS)

fuzz:                      ## Mutation fuzzing; FUZZ="target cases seed"
	$(ZIG) build fuzz $(FLAGS) -- $(FUZZ)

bench:                     ## test/bench under prolua and lua, ReleaseFast
	$(ZIG) build bench -Doptimize=ReleaseFast $(FLAGS)

# `make test-codegen`, `make test-iolib`, ...: one module's unit tests.
# The explicit targets above take precedence.
.PHONY: test-%
test-%:
	$(ZIG) build test-$* $(FLAGS)

.PHONY: install uninstall
install: release           ## ReleaseFast build into /usr/local/bin (DESTDIR honoured)
	scripts/install.sh

uninstall:                 ## Remove the installed binary
	scripts/uninstall.sh

.PHONY: fmt fmt-check docs clean distclean version help
fmt:                       ## Format the Zig sources
	$(ZIG) fmt src build.zig examples

fmt-check:                 ## Fail if any Zig source is not formatted
	$(ZIG) fmt --check src build.zig examples

docs:                      ## API documentation into zig-out/docs
	$(ZIG) build docs

clean:                     ## Remove the build cache
	rm -rf .zig-cache zig-cache

distclean: clean           ## Remove the build cache and the build output
	rm -rf zig-out

version:
	@echo "$(BINARY) $(VERSION), zig $(shell $(ZIG) version)"

help:                      ## This list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | sort | column -t -s "$$(printf '\t')"
