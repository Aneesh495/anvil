# Anvil: High-Performance Git-Compatible Version Control Engine
# Free Pascal Compiler (FPC) Build Automation

FPC ?= fpc
FPC_FLAGS = -O3 -Mobjfpc -Sh -Sc -Cg -FUbuild -FEbin \
            -Isrc/common -Isrc/crypto -Isrc/odb -Isrc/index -Isrc/diff \
            -Isrc/merge -Isrc/ref -Isrc/worktree -Isrc/dag -Isrc/protocol \
            -Isrc/cli -Isrc/lib \
            -Fusrc/common -Fusrc/crypto -Fusrc/odb -Fusrc/index -Fusrc/diff \
            -Fusrc/merge -Fusrc/ref -Fusrc/worktree -Fusrc/dag -Fusrc/protocol \
            -Fusrc/cli -Fusrc/lib

# Platform detection
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    DYLIB_EXT = dylib
    FPC_LIB_FLAGS = -CD -Cn
else
    DYLIB_EXT = so
    FPC_LIB_FLAGS = -CD -Cn -k"-fPIC"
endif

.PHONY: all clean dirs test bench lib format help

all: dirs bin/anvil lib/libanvil.$(DYLIB_EXT) bin/anvil_test bin/anvil_bench

dirs:
	@mkdir -p build bin lib

bin/anvil: src/cli/anvil_main.pas | dirs
	$(FPC) $(FPC_FLAGS) -obin/anvil src/cli/anvil_main.pas

lib/libanvil.$(DYLIB_EXT): src/lib/libanvil.pas | dirs
	$(FPC) $(FPC_FLAGS) $(FPC_LIB_FLAGS) -olib/libanvil.$(DYLIB_EXT) src/lib/libanvil.pas

bin/anvil_test: tests/test_runner.pas $(wildcard tests/unit/*.pas) $(wildcard tests/integration/*.pas) | dirs
	$(FPC) $(FPC_FLAGS) -Itests/unit -Itests/integration -Futests/unit -Futests/integration \
	      -obin/anvil_test tests/test_runner.pas

bin/anvil_bench: benchmarks/bench_main.pas | dirs
	$(FPC) $(FPC_FLAGS) -Ibenchmarks -Fubenchmarks \
	      -obin/anvil_bench benchmarks/bench_main.pas

test: bin/anvil_test
	./bin/anvil_test

bench: bin/anvil_bench
	./bin/anvil_bench

clean:
	@rm -rf build bin lib *.o *.ppu tests/*.o tests/*.ppu benchmarks/*.o benchmarks/*.ppu

help:
	@echo "Anvil Build System"
	@echo "Targets:"
	@echo "  all      - Build CLI binary, shared library, test runner, benchmark suite"
	@echo "  anvil    - Build main CLI executable (bin/anvil)"
	@echo "  lib      - Build dynamic shared library (lib/libanvil.$(DYLIB_EXT))"
	@echo "  test     - Build and execute complete test suite"
	@echo "  bench    - Build and execute performance benchmark suite"
	@echo "  clean    - Remove build artifacts and intermediate compiled units"
