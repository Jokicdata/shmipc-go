#!/bin/bash
# Shmipc Adapter Build Script
# 
# This script provides an easy way to build and install the shmipc adapter

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BUILD_DIR="build"
LIB_DIR="lib"
GO_LIB="$LIB_DIR/libshmipc_go.so"
ADAPTER_LIB="$LIB_DIR/libshmipc_adapter.so"

# Functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    print_info "Checking dependencies..."
    
    # Check Go
    if ! command -v go &> /dev/null; then
        print_error "Go is not installed. Please install Go 1.20 or higher."
        exit 1
    fi
    
    # Check GCC
    if ! command -v gcc &> /dev/null; then
        print_error "GCC is not installed. Please install GCC."
        exit 1
    fi
    
    # Check make
    if ! command -v make &> /dev/null; then
        print_error "Make is not installed. Please install make."
        exit 1
    fi
    
    print_info "All dependencies are installed."
}

check_os() {
    print_info "Checking operating system..."
    
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        print_warn "This adapter is designed for Linux. It may not work on other systems."
    fi
}

clean_build() {
    print_info "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    rm -rf "$LIB_DIR"
    rm -f *.so *.o *.a
    print_info "Clean completed."
}

build_libraries() {
    print_info "Building shmipc adapter libraries..."
    
    # Create directories
    mkdir -p "$BUILD_DIR"
    mkdir -p "$LIB_DIR"
    
    # Build Go shared library
    print_info "Building Go shared library..."
    go build -buildmode=c-shared -ldflags="-s -w" -o "$GO_LIB" shmipc_bridge.go
    
    if [ $? -ne 0 ]; then
        print_error "Failed to build Go shared library."
        exit 1
    fi
    
    print_info "Go shared library built: $GO_LIB"
    
    # Build C adapter library
    print_info "Building C adapter library..."
    gcc -shared -fPIC -Wall -O2 -o "$ADAPTER_LIB" shmipc_adapter.c -I. -L"$LIB_DIR" -lshmipc_go -lpthread -ldl
    
    if [ $? -ne 0 ]; then
        print_error "Failed to build C adapter library."
        exit 1
    fi
    
    print_info "C adapter library built: $ADAPTER_LIB"
}

install_libraries() {
    print_info "Installing libraries to /usr/local/lib..."
    
    if [ ! -f "$GO_LIB" ] || [ ! -f "$ADAPTER_LIB" ]; then
        print_error "Libraries not found. Please build first."
        exit 1
    fi
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        print_warn "This command requires root privileges. Using sudo..."
        sudo cp "$GO_LIB" /usr/local/lib/
        sudo cp "$ADAPTER_LIB" /usr/local/lib/
        sudo ldconfig
    else
        cp "$GO_LIB" /usr/local/lib/
        cp "$ADAPTER_LIB" /usr/local/lib/
        ldconfig
    fi
    
    print_info "Libraries installed successfully!"
}

test_build() {
    print_info "Testing build..."
    
    if [ ! -f "$GO_LIB" ] || [ ! -f "$ADAPTER_LIB" ]; then
        print_error "Libraries not found. Please build first."
        exit 1
    fi
    
    # Compile test program
    print_info "Compiling test program..."
"
    gcc -o test_socket_basic test_socket_basic.c
    
    if [ $? -ne 0 ]; then
        print_error "Failed to compile test program."
        exit 1
    fi
    
    print_info "Test program compiled successfully."
    print_info "Run the following commands to test:"
    echo ""
    echo "  Terminal 1 (Server):"
    echo "    export SHMIPC_ENABLED=1"
    echo "    export LD_PRELOAD=$PWD/$ADAPTER_LIB:$PWD/$GO_LIB"
    echo "    ./test_socket_basic unix_server"
    echo ""
    echo "  Terminal 2 (Client):"
    echo "    export SHMIPC_ENABLED=1"
    echo "    export LD_PRELOAD=$PWD/$ADAPTER_LIB:$PWD/$GO_LIB"
    echo "    ./test_socket_basic unix_client"
    echo ""
}

show_usage() {
    echo "Shmipc Adapter Build Script"
    echo "============================="
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  build       - Build all libraries (default)"
    echo "  clean       - Clean build artifacts"
    echo "  install     - Install libraries to system"
    echo "  test        - Build and test"
    echo "  help        - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Build all libraries"
    echo "  $0 build        # Build all libraries"
    echo "  $0 install      # Install to system"
    echo "  $0 test         # Build and test"
    echo ""
    echo "Environment variables:"
    echo "  SHMIPC_ENABLED  - Enable shmipc adapter (1/true/yes)"
    echo "  SHMIPC_CONFIG   - Configuration for shmipc"
    echo ""
    echo "Usage examples:"
    echo "  export SHMIPC_ENABLED=1"
    echo "  export LD_PRELOAD=$PWD/$ADAPTER_LIB:$PWD/$GO_LIB"
    echo "  ./your_application"
    echo ""
}

# Main script
main() {
    case "${1:-build}" in
        build)
            check_dependencies
            check_os
            clean_build
            build_libraries
            echo ""
            print_info "Build completed successfully!"
            print_info "Libraries: $GO_LIB, $ADAPTER_LIB"
            ;;
        clean)
            clean_build
            ;;
        install)
            check_dependencies
            build_libraries
            install_libraries
            ;;
        test)
            check_dependencies
            check_os
            clean_build
            build_libraries
            test_build
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            print_error "Unknown command: $1"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"