CC = gcc
CFLAGS = -Wall -Wextra -fPIC -O2 -shared
LDFLAGS = -ldl -lpthread

.PHONY: all clean install

all: libshmipc.so

libshmipc.so: shmipc_preload.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo ""
	@echo "=== Build Complete ==="
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
	rm -f libshmipc.so

install: libshmipc.so
	install -m 755 libshmipc.so /usr/local/lib/
	@echo "Installed to /usr/local/lib/libshmipc.so"
	@echo "Usage: LD_PRELOAD=/usr/local/lib/libshmipc.so <your-program>"
