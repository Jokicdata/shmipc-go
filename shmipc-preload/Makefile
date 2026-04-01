CC = gcc
GO = go
CFLAGS = -Wall -Wextra -fPIC -O2
LDFLAGS = -shared -ldl -lpthread

.PHONY: all clean install help

all: libshmipc.so

# Step 1: 下载依赖并生成 go.sum
go.sum: go.mod
	$(GO) mod tidy
	@echo "Generated: go.sum"

# Step 2: 编译 Go 共享库（包含 CGO 导出函数）
libshmipc_go.so: shmipc_bridge.go go.sum
	$(GO) build -buildmode=c-shared -o $@ $<
	@echo "Generated: libshmipc_go.so (Go shared library with CGO exports)"

# Step 3: 编译 C 共享库（链接到 Go 库）
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
	@echo ""

clean:
	rm -f libshmipc.so libshmipc_go.so shmipc_bridge.h go.sum

install: libshmipc.so
	install -m 755 libshmipc.so /usr/local/lib/
	install -m 755 libshmipc_go.so /usr/local/lib/
	ldconfig
	@echo "Installed to /usr/local/lib/"
	@echo "Usage: LD_PRELOAD=/usr/local/lib/libshmipc.so <your-program>"

help:
	@echo "shmipc-preload Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all      - Build libshmipc.so (default)"
	@echo "  clean    - Remove build artifacts"
	@echo "  install  - Install to /usr/local/lib"
	@echo "  help     - Show this help"
	@echo ""
	@echo "Architecture:"
	@echo "  libshmipc_go.so  <- Go CGO shared library (shmipc core)"
	@echo "  libshmipc.so     <- C preload library (socket interception)"
	@echo "                     links to libshmipc_go.so"
