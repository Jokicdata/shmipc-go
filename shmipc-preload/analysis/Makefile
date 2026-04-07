CC = gcc
GO = go
CFLAGS = -Wall -Wextra -fPIC -O2 -g
LDFLAGS = -shared -ldl -lpthread

SCRIPT_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
RESULTS_DIR := $(SCRIPT_DIR)results

.PHONY: all clean profile optimized tools help

all: help

profile: libshmipc_profile.so libshmipc_go.so
	@echo ""
	@echo "=========================================="
	@echo "Profile Build Complete!"
	@echo "=========================================="
	@echo ""
	@echo "Usage:"
	@echo "  SHMIPC_PROFILE=1 LD_PRELOAD=./libshmipc_profile.so <your-program>"
	@echo ""
	@echo "Profile log will be saved to:"
	@echo "  /tmp/shmipc_profile_<pid>.log"
	@echo ""

optimized: libshmipc_optimized.so libshmipc_optimized_go.so
	@echo ""
	@echo "=========================================="
	@echo "Optimized Build Complete!"
	@echo "=========================================="
	@echo ""
	@echo "Usage:"
	@echo "  LD_PRELOAD=./libshmipc_optimized.so <your-program>"
	@echo ""
	@echo "Optimizations:"
	@echo "  - Zero-copy data transfer (unsafe.Slice)"
	@echo "  - Reduced lock contention (sync.Map)"
	@echo "  - Batch operation support"
	@echo ""

libshmipc_go.so:
	cd .. && $(GO) build -buildmode=c-shared -o analysis/libshmipc_go.so shmipc_bridge.go

libshmipc_profile.so: shmipc_preload_profile.c libshmipc_go.so
	$(CC) $(CFLAGS) -shared -o $@ $< $(LDFLAGS) -L. -lshmipc_go -Wl,-rpath,'$$ORIGIN'

libshmipc_optimized_go.so: shmipc_bridge_optimized.go
	$(GO) build -buildmode=c-shared -o $@ $<

libshmipc_optimized.so: shmipc_preload_profile.c libshmipc_optimized_go.so
	$(CC) $(CFLAGS) -DOPTIMIZED -shared -o $@ $< $(LDFLAGS) -L. -lshmipc_optimized_go -Wl,-rpath,'$$ORIGIN'

tools:
	@echo "Installing analysis tools..."
	@chmod +x analyze.sh
	@chmod +x bandwidth_analysis.sh
	@chmod +x ftrace_analysis.sh
	@mkdir -p $(RESULTS_DIR)
	@echo ""
	@echo "Tools ready:"
	@echo "  ./analyze.sh profile -- <command>"
	@echo "  ./analyze.sh perf -- <command>"
	@echo "  ./analyze.sh benchmark"
	@echo "  ./bandwidth_analysis.sh all"
	@echo "  sudo ./ftrace_analysis.sh run -- <command>"
	@echo ""

clean:
	rm -f libshmipc_profile.so libshmipc_optimized.so
	rm -f libshmipc_optimized_go.so shmipc_bridge_optimized.h
	rm -rf $(RESULTS_DIR)
	@echo "Cleaned analysis build artifacts"

results:
	mkdir -p $(RESULTS_DIR)

help:
	@echo "shmipc-preload Analysis Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  profile     - Build profiling version (with timestamps)"
	@echo "  optimized   - Build optimized version (zero-copy)"
	@echo "  tools       - Setup analysis tools"
	@echo "  clean       - Remove build artifacts"
	@echo "  help        - Show this help"
	@echo ""
	@echo "Analysis Tools:"
	@echo "  analyze.sh          - Main analysis script"
	@echo "    profile           - Run with profiling"
	@echo "    perf              - Run with Linux perf"
	@echo "    flamegraph        - Generate flamegraph"
	@echo "    benchmark         - Run comprehensive benchmark"
	@echo "    analyze           - Analyze profile data"
	@echo ""
	@echo "  bandwidth_analysis.sh - Bandwidth analysis"
	@echo "    all               - Comprehensive analysis"
	@echo "    bandwidth         - Bandwidth tests"
	@echo "    cgo               - CGO overhead analysis"
	@echo "    report            - Generate report"
	@echo ""
	@echo "  ftrace_analysis.sh  - Ftrace analysis (requires root)"
	@echo "    run               - Run with ftrace"
	@echo "    pid               - Trace specific PID"
	@echo "    analyze           - Analyze trace data"
	@echo ""
	@echo "Examples:"
	@echo "  make profile"
	@echo "  SHMIPC_PROFILE=1 LD_PRELOAD=./libshmipc_profile.so sockperf pp --tcp -i 127.0.0.1"
	@echo "  ./analyze.sh analyze /tmp/shmipc_profile_xxx.log"
	@echo ""
	@echo "  make optimized"
	@echo "  LD_PRELOAD=./libshmipc_optimized.so sockperf pp --tcp -i 127.0.0.1"
	@echo ""
