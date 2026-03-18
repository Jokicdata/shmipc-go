CC = gcc
GO = go
CFLAGS = -Wall -Wextra -fPIC -O2
LDFLAGS = -shared -ldl -lpthread

PROJECT_DIR = $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
BUILD_DIR = $(PROJECT_DIR)/build
LIB_DIR = $(PROJECT_DIR)/lib
INCLUDE_DIR = $(PROJECT_DIR)/include
SRC_DIR = $(PROJECT_DIR)/src
EXAMPLES_DIR = $(PROJECT_DIR)/examples

.PHONY: all clean lib examples install test

all: lib examples

lib: $(LIB_DIR)/libshmipc_go.so $(LIB_DIR)/libshmipc_preload.so $(LIB_DIR)/shmipc-run.sh

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(LIB_DIR):
	mkdir -p $(LIB_DIR)

$(LIB_DIR)/libshmipc_go.so: $(SRC_DIR)/shmipc_bridge.go | $(LIB_DIR)
	cd $(SRC_DIR) && $(GO) build -buildmode=c-shared -o $@ shmipc_bridge.go

$(LIB_DIR)/libshmipc_preload.so: $(SRC_DIR)/shmipc_preload.c $(INCLUDE_DIR)/shmipc_transparent.h | $(LIB_DIR) $(LIB_DIR)/libshmipc_go.so
	$(CC) $(CFLAGS) $(LDFLAGS) -I$(INCLUDE_DIR) -L$(LIB_DIR) -lshmipc_go -o $@ $(SRC_DIR)/shmipc_preload.c

$(LIB_DIR)/shmipc-run.sh: | $(LIB_DIR)
	@echo '#!/bin/bash' > $@
	@echo 'SCRIPT_DIR="$$(cd "$$(dirname "$${BASH_SOURCE[0]}")" && pwd)"' >> $@
	@echo 'export LD_LIBRARY_PATH="$${SCRIPT_DIR}:$${LD_LIBRARY_PATH}"' >> $@
	@echo 'export LD_PRELOAD="$${SCRIPT_DIR}/libshmipc_preload.so:$${SCRIPT_DIR}/libshmipc_go.so"' >> $@
	@echo 'exec "$$@"' >> $@
	@chmod +x $@

examples: $(BUILD_DIR)/echo_server $(BUILD_DIR)/echo_client

$(BUILD_DIR)/echo_server: $(EXAMPLES_DIR)/echo_server.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $(EXAMPLES_DIR)/echo_server.c

$(BUILD_DIR)/echo_client: $(EXAMPLES_DIR)/echo_client.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $(EXAMPLES_DIR)/echo_client.c

install: lib
	@echo "Installing to /usr/local..."
	cp -r $(LIB_DIR)/*.so /usr/local/lib/
	cp $(INCLUDE_DIR)/shmipc_transparent.h /usr/local/include/
	ldconfig
	@echo "Installation complete"

clean:
	rm -rf $(BUILD_DIR) $(LIB_DIR)
	rm -f $(SRC_DIR)/shmipc_bridge.h

test: lib examples
	@echo "Running echo test..."
	@echo "Starting server..."
	@$(LIB_DIR)/shmipc-run.sh $(BUILD_DIR)/echo_server &
	@sleep 1
	@echo "Starting client..."
	@$(LIB_DIR)/shmipc-run.sh $(BUILD_DIR)/echo_client 5
	@echo "Test complete"
	@pkill -f echo_server || true

help:
	@echo "shmipc-transparent Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all       - Build libraries and examples (default)"
	@echo "  lib       - Build shared libraries only"
	@echo "  examples  - Build example programs only"
	@echo "  install   - Install to /usr/local"
	@echo "  clean     - Remove build artifacts"
	@echo "  test      - Run basic test"
	@echo "  help      - Show this help"
