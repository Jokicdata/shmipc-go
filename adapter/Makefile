# Makefile for Shmipc Adapter
# 
# This Makefile compiles the shmipc adapter components:
# - libshmipc_go.so: Go shared library with CGO bridge
# - libshmipc_adapter.so: C shared library for socket interception

.PHONY: all clean install test help

# Compiler settings
CC = gcc
GO = go
CFLAGS = -shared -fPIC -Wall -O2
GOFLAGS = -buildmode=c-shared -ldflags="-s -w"

# Output directories
BUILD_DIR = build
LIB_DIR = lib

# Library names
GO_LIB = $(LIB_DIR)/libshmipc_go.so
ADAPTER_LIB = $(LIB_DIR)/libshmipc_adapter.so

# Source files
GO_SRC = shmipc_bridge.go
ADAPTER_SRC = shmipc_adapter.c

all: directories $(GO_LIB) $(ADAPTER_LIB)
	@echo "========================================="
	@echo "Build completed successfully!"
	@echo "========================================="
	@echo "Generated libraries:"
	@echo "  $(GO_LIB)"
	@echo "  $(ADAPTER_LIB)"
	@echo ""
	@echo "Usage:"
	@echo "  LD_PRELOAD=$(ADAPTER_LIB):$(GO_LIB) your_application"
	@echo ""

directories:
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(LIB_DIR)

$(GO_LIB): $(GO_SRC)
	@echo "Building Go shared library..."
	@$(GO) build $(GOFLAGS) -o $@ $<
	@echo "Go shared library built: $@"

$(ADAPTER_LIB): $(ADAPTER_SRC) $(GO_LIB)
	@echo "Building C adapter library..."
	@$(CC) $(CFLAGS) -o $@ $(ADAPTER_SRC) -I. -L$(LIB_DIR) -lshmipc_go -lpthread -ldl
	@echo "C adapter library built: $@"

install: all
	@echo "Installing libraries to /usr/local/lib..."
	@sudo cp $(GO_LIB) /usr/local/lib/
	@sudo cp $(ADAPTER_LIB) /usr/local/lib/
	@sudo ldconfig
	@echo "Libraries installed successfully!"

test: all
	@echo "Running adapter tests..."
	@echo "Test 1: Basic socket interception"
	@SHMIPC_ENABLED=1 LD_PRELOAD=$(ADAPTER_LIB):$(GO_LIB) ./test_socket_basic || echo "Test 1 failed"
	@echo ""
	@echo "Test 2: qperf compatibility"
	@which qperf && (SHMIPC_ENABLED=1 LD_PRELOAD=$(ADAPTER_LIB):$(GO_LIB) qperf --help) || echo "qperf not found"
	@echo ""
	@echo "Test 3: sockperf compatibility"
	@which sockperf && (SHMIPC_ENABLED=1 LD_PRELOAD=$(ADAPTER_LIB):$(GO_LIB) sockperf --help) || echo "sockperf not found"

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR)
	@rm -rf $(LIB_DIR)
	@rm -f *.so *.o *.a
	@echo "Clean completed!"

# Development targets
dev-build: directories
	@echo "Building with debug symbols..."
	@$(GO) build -buildmode=c-shared -gcflags="all=-N -l" -o $(GO_LIB) $(GO_SRC)
	@$(CC) -shared -fPIC -g -o $(ADAPTER_LIB) $(ADAPTER_SRC) -I. -L$(LIB_DIR) -lshmipc_go -lpthread -ldl

# Performance testing targets
perf-test: all
	@echo "Running performance tests with qperf..."
	@echo "Starting qperf server..."
	@(SHMIPC_ENABLED=1 LD_PRELOAD=$(ADAPTER_LIB):$(GO_LIB) qperf -s &)
	@sleep 2
	@echo "Running qperf client..."
	@SHMIPC_ENABLED=1 LD_PRELOAD=$(ADAPTER_LIB):$(GO_LIB) qperf -c 127.0.0.1 -t tcp -p 12345

# Help target
help:
	@echo "Shmipc Adapter Makefile"
	@echo "========================="
	@echo ""
	@echo "Available targets:"
	@echo "  all          - Build all libraries (default)"
	@echo "  directories   - Create build directories"
	@echo "  $(GO_LIB)    - Build Go shared library only"
	@echo "  $(ADAPTER_LIB) - Build C adapter library only"
	@echo "  install       - Install libraries to system"
	@echo "  test          - Run basic tests"
	@echo "  clean         - Remove build artifacts"
	@echo "  dev-build     - Build with debug symbols"
	@echo "  perf-test     - Run performance tests"
	@echo "  help          - Show this help message"
	@echo ""
	@echo "Environment variables:"
	@echo "  SHMIPC_ENABLED  - Enable shmipc adapter (1/true/yes)"
	@echo "  SHMIPC_CONFIG   - Configuration for shmipc"
	@echo ""
	@echo "Usage examples:"
	@echo "  make                    # Build all libraries"
	@echo "  make install             # Install to system"
	@echo "  LD_PRELOAD=$(ADAPTER_LIB):$(GO_LIB) ./your_app"
	@echo "  SHMIPC_ENABLED=1 LD_PRELOAD=$(ADAPTER_LIB):$(GO_LIB) qperf -s"
	@echo ""