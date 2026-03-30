CC = gcc
GO = go
CFLAGS = -Wall -Wextra -fPIC -O2
LDFLAGS = -shared -ldl -lpthread

.PHONY: all clean install help

all: libshmipc.so

libshmipc_go.so: shmipc_bridge.go
	cd $(dir $@) && $(GO) build -buildmode=c-shared -o $(notdir $@) shmipc_bridge.go

shmipc_preload.o: shmipc_preload.c
	$(CC) $(CFLAGS) -c -o $@ $<

libshmipc.so: shmipc_preload.o libshmipc_go.so
	$(CC) -shared -o $@ $^ $(LDFLAGS) -L. -lshmipc_go
	@echo ""
	@echo "=========================================="
	@echo "  Build Complete!"
	@echo "=========================================="
	@echo ""
	@echo "Generated: libshmipc.so"
	@echo ""
	@echo "Usage:"
	@echo "  LD_PRELOAD=./libshmipc.so <your-program>"
	@echo ""
	@echo "Examples:"
	@echo ""
	@echo "  # qperf 测试"
	@echo "  LD_PRELOAD=./libshmipc.so qperf                                    # 服务端"
	@echo "  LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw tcp_lat            # 客户端"
	@echo ""
	@echo "  # sockperf 测试"
	@echo "  LD_PRELOAD=./libshmipc.so sockperf sr --tcp -i 127.0.0.1 -p 11111   # 服务端"
	@echo "  LD_PRELOAD=./libshmipc.so sockperf pp --tcp -i 127.0.0.1 -p 11111   # 客户端"
	@echo ""
	@echo "  # Redis 测试"
	@echo "  LD_PRELOAD=./libshmipc.so redis-server --unixsocket /tmp/redis.sock"
	@echo "  LD_PRELOAD=./libshmipc.so redis-benchmark -s /tmp/redis.sock -t set,get"
	@echo ""
	@echo "Environment Variables:"
	@echo "  SHMIPC_LOG=0-4      Log level (default: 1)"
	@echo "  SHMIPC_ENABLE=0|1   Enable/disable shmipc (default: 1)"
	@echo ""

clean:
	rm -f *.o *.so shmipc_bridge.h

install: libshmipc.so
	install -m 755 libshmipc.so /usr/local/lib/
	@echo "Installed to /usr/local/lib/libshmipc.so"
	@echo ""
	@echo "Usage: LD_PRELOAD=/usr/local/lib/libshmipc.so <your-program>"

help:
	@echo "shmipc-preload Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all      - Build libshmipc.so (default)"
	@echo "  clean    - Remove build artifacts"
	@echo "  install  - Install to /usr/local/lib"
	@echo "  help     - Show this help"
