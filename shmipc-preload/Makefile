CC = gcc
GO = go
CFLAGS = -Wall -Wextra -fPIC -O2
LDFLAGS = -shared -ldl -lpthread

.PHONY: all clean install help opt opt-clean

all: libshmipc.so

# ============================================================================
# 原始版本编译
# ============================================================================

# Step 1: 编译 Go 共享库（包含 CGO 导出函数）
libshmipc_go.so: shmipc_bridge.go
	$(GO) build -buildmode=c-shared -o $@ $<
	@echo "Generated: libshmipc_go.so (Go shared library with CGO exports)"

# Step 2: 编译 C 共享库（链接到 Go 库）
libshmipc.so: shmipc_preload.c libshmipc_go.so
	$(CC) $(CFLAGS) -shared -o $@ $< $(LDFLAGS) -L. -lshmipc_go -Wl,-rpath,'$$ORIGIN'
	@echo ""
	@echo "=========================================="
	@echo "Build Complete!"
	@echo "=========================================="
	@echo ""
	@echo "Generated files:"
	@echo "  - libshmipc_go.so  (Go shared library)"
	@echo "  - libshmipc.so     (C preload library, links to Go library)"
	@echo ""
	@echo "Usage:"
	@echo "  LD_PRELOAD=./libshmipc.so <your-program>"
	@echo ""
	@echo "Examples:"
	@echo "  # qperf"
	@echo "  LD_PRELOAD=./libshmipc.so qperf                                    # server"
	@echo "  LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw tcp_lat            # client"
	@echo ""
	@echo "  # sockperf"
	@echo "  LD_PRELOAD=./libshmipc.so sockperf sr --tcp -i 127.0.0.1 -p 11111   # server"
	@echo "  LD_PRELOAD=./libshmipc.so sockperf pp --tcp -i 127.0.0.1 -p 11111   # client"

# ============================================================================
# 优化版本编译
# ============================================================================

# Step 1: 编译优化版 Go 共享库
libshmipc_go_opt.so: shmipc_bridge_opt.go
	$(GO) build -buildmode=c-shared -o $@ $<
	@echo "Generated: libshmipc_go_opt.so (Optimized Go shared library)"

# Step 2: 编译优化版 C 共享库（链接到优化版 Go 库）
libshmipc_opt.so: shmipc_preload_opt.c libshmipc_go_opt.so
	$(CC) $(CFLAGS) -shared -o $@ $< $(LDFLAGS) -L. -lshmipc_go_opt -Wl,-rpath,'$$ORIGIN'
	@echo ""
	@echo "=========================================="
	@echo "Optimized Build Complete!"
	@echo "=========================================="
	@echo ""
	@echo "Generated files:"
	@echo "  - libshmipc_go_opt.so  (Optimized Go shared library)"
	@echo "  - libshmipc_opt.so     (Optimized C preload library)"
	@echo ""
	@echo "Usage:"
	@echo "  LD_PRELOAD=./libshmipc_opt.so <your-program>"
	@echo ""
	@echo "Examples:"
	@echo "  # qperf"
	@echo "  LD_PRELOAD=./libshmipc_opt.so qperf                                    # server"
	@echo "  LD_PRELOAD=./libshmipc_opt.so qperf 127.0.0.1 tcp_bw tcp_lat            # client"
	@echo ""
	@echo "  # sockperf"
	@echo "  LD_PRELOAD=./libshmipc_opt.so sockperf sr --tcp -i 127.0.0.1 -p 11111   # server"
	@echo "  LD_PRELOAD=./libshmipc_opt.so sockperf pp --tcp -i 127.0.0.1 -p 11111   # client"
	@echo ""
	@echo "Optimization features:"
	@echo "  - Reserve API zero-copy optimization"
	@echo "  - writev/readv batch operations"
	@echo "  - Per-FD lock separation"

# ============================================================================
# 便捷目标
# ============================================================================

# 编译优化版本（推荐）
opt: libshmipc_opt.so

# 编译所有版本
all-opt: libshmipc.so libshmipc_opt.so

# ============================================================================
# 清理
# ============================================================================

clean:
	rm -f libshmipc.so libshmipc_go.so
	rm -f libshmipc_opt.so libshmipc_go_opt.so
	rm -f shmipc_bridge.h

opt-clean:
	rm -f libshmipc_opt.so libshmipc_go_opt.so

# ============================================================================
# 安装
# ============================================================================

install: libshmipc.so
	install -m 755 libshmipc.so /usr/local/lib/
	install -m 755 libshmipc_go.so /usr/local/lib/
	ldconfig
	@echo "Installed to /usr/local/lib/"
	@echo "Usage: LD_PRELOAD=/usr/local/lib/libshmipc.so <your-program>"

opt-install: libshmipc_opt.so
	install -m 755 libshmipc_opt.so /usr/local/lib/
	install -m 755 libshmipc_go_opt.so /usr/local/lib/
	ldconfig
	@echo "Optimized version installed to /usr/local/lib/"
	@echo "Usage: LD_PRELOAD=/usr/local/lib/libshmipc_opt.so <your-program>"

# ============================================================================
# 帮助
# ============================================================================

help:
	@echo "shmipc-preload Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all       - Build original libshmipc.so (default)"
	@echo "  opt       - Build optimized libshmipc_opt.so (RECOMMENDED)"
	@echo "  all-opt   - Build both original and optimized versions"
	@echo "  clean     - Remove all build artifacts"
	@echo "  opt-clean - Remove optimized version artifacts"
	@echo "  install   - Install original version"
	@echo "  opt-install - Install optimized version"
	@echo "  help      - Show this help"
	@echo ""
	@echo "Architecture:"
	@echo "  libshmipc_go.so     <- Go CGO shared library (original)"
	@echo "  libshmipc.so        <- C preload library (original)"
	@echo "                          links to libshmipc_go.so"
	@echo ""
	@echo "  libshmipc_go_opt.so <- Go CGO shared library (optimized)"
	@echo "  libshmipc_opt.so    <- C preload library (optimized)"
	@echo "                          links to libshmipc_go_opt.so"
	@echo ""
	@echo "Optimization features:"
	@echo "  1. Reserve API zero-copy (avoids one memory copy)"
	@echo "  2. writev/readv batch operations"
	@echo "  3. Per-FD lock separation"
	@echo ""
	@echo "Quick start:"
	@echo "  make opt              # Build optimized version"
	@echo "  LD_PRELOAD=./libshmipc_opt.so qperf  # Test with qperf"