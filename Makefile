# rippled-zig — XRPL Protocol Toolkit
# Convenience targets wrapping zig build

.PHONY: all build test run bench clean fmt check gates help

# Default: build + test
all: build test

build:
	zig build

test:
	zig build test

run:
	zig build run -- help

bench:
	zig build run -- benchmark

fmt:
	zig fmt src/ examples/ tools/

check:
	zig fmt --check src/ examples/ tools/

clean:
	rm -rf .zig-cache zig-out artifacts/

# Quality gates
gates: gate-a gate-b gate-c gate-e

gate-a:
	@mkdir -p artifacts/gate-a
	bash scripts/gates/gate_a.sh artifacts/gate-a

gate-b:
	@mkdir -p artifacts/gate-b
	bash scripts/gates/gate_b.sh artifacts/gate-b

gate-c:
	@mkdir -p artifacts/gate-c
	bash scripts/gates/gate_c.sh artifacts/gate-c

gate-e:
	@mkdir -p artifacts/gate-e
	bash scripts/gates/gate_e.sh artifacts/gate-e

# WASM targets
wasm:
	zig build wasm

# Release builds (all platforms)
release:
	zig build release 2>/dev/null || echo "Release step not yet configured — use: zig build -Doptimize=ReleaseSafe"

# Count lines of code
loc:
	@echo "Source files:" && ls src/*.zig | wc -l
	@echo "Lines of code:" && wc -l src/*.zig | tail -1
	@echo "Test count:" && grep -r 'test "' src/*.zig | wc -l

help:
	@echo "rippled-zig Makefile targets:"
	@echo "  all       Build + test (default)"
	@echo "  build     Compile the project"
	@echo "  test      Run all tests"
	@echo "  run       Show CLI help"
	@echo "  bench     Run benchmarks"
	@echo "  fmt       Format all source files"
	@echo "  check     Check formatting (CI)"
	@echo "  clean     Remove build artifacts"
	@echo "  gates     Run all quality gates"
	@echo "  wasm      Build WASM targets"
	@echo "  loc       Count lines of code"
