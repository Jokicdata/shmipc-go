#!/bin/bash

echo "=== shmipc-preload Quick Test ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [ ! -f ./libshmipc.so ]; then
    echo "Error: libshmipc.so not found. Please run 'make' first."
    exit 1
fi

echo "1. Testing basic functionality..."
echo ""

echo "Starting server..."
LD_PRELOAD=./libshmipc.so qperf &
SRV_PID=$!
sleep 2

echo "Running client test..."
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 1024 -t 5 tcp_bw tcp_lat

echo ""
echo "Stopping server..."
kill $SRV_PID 2>/dev/null

echo ""
echo "2. Testing optimized version..."
if [ -f ./libshmipc_optimized.so ]; then
    echo "Starting optimized server..."
    LD_PRELOAD=./libshmipc_optimized.so qperf &
    SRV_PID=$!
    sleep 2
    
    echo "Running optimized client test..."
    LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 -m 1024 -t 5 tcp_bw tcp_lat
    
    echo ""
    echo "Stopping server..."
    kill $SRV_PID 2>/dev/null
else
    echo "Optimized version not built. Run 'make -f Makefile.optimized' first."
fi

echo ""
echo "=== Test Complete ==="
