#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

BUILD_DIR="${PROJECT_DIR}/build"
LIB_DIR="${PROJECT_DIR}/lib"

echo "=== Building shmipc-transparent ==="

mkdir -p "${BUILD_DIR}"
mkdir -p "${LIB_DIR}"

cd "${PROJECT_DIR}"

echo "Step 1: Building Go shared library..."
cd src
go build -buildmode=c-shared -o "${LIB_DIR}/libshmipc_go.so" shmipc_bridge.go
echo "  -> Generated ${LIB_DIR}/libshmipc_go.so"

echo "Step 2: Building C preload library..."
gcc -shared -fPIC -o "${LIB_DIR}/libshmipc_preload.so" \
    -I"${PROJECT_DIR}/include" \
    -L"${LIB_DIR}" \
    -lshmipc_go \
    -ldl \
    -lpthread \
    shmipc_preload.c
echo "  -> Generated ${LIB_DIR}/libshmipc_preload.so"

echo "Step 3: Creating wrapper script..."
cat > "${LIB_DIR}/shmipc-run.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="${SCRIPT_DIR}:${LD_LIBRARY_PATH}"
export LD_PRELOAD="${SCRIPT_DIR}/libshmipc_preload.so:${SCRIPT_DIR}/libshmipc_go.so"
exec "$@"
EOF
chmod +x "${LIB_DIR}/shmipc-run.sh"
echo "  -> Generated ${LIB_DIR}/shmipc-run.sh"

echo ""
echo "=== Build Complete ==="
echo ""
echo "Usage:"
echo "  1. Run with preload:"
echo "     ${LIB_DIR}/shmipc-run.sh <your-program>"
echo ""
echo "  2. Or set environment variables manually:"
echo "     export LD_LIBRARY_PATH=${LIB_DIR}:\$LD_LIBRARY_PATH"
echo "     export LD_PRELOAD=${LIB_DIR}/libshmipc_preload.so:${LIB_DIR}/libshmipc_go.so"
echo "     <your-program>"
echo ""
echo "Environment variables:"
echo "  SHMIPC_MODE         - auto|force_shmipc|force_socket (default: auto)"
echo "  SHMIPC_LOG_LEVEL    - 0-4 (default: 1)"
echo "  SHMIPC_BUFFER_SIZE  - Shared memory buffer size (default: 33554432)"
echo "  SHMIPC_PATH_PREFIX  - Shared memory path prefix (default: /dev/shm/shmipc_transparent)"
