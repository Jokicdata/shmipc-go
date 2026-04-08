#!/bin/bash

echo "=== shmipc Copy Overhead Analysis ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "This script measures the copy overhead in shmipc vs socket"
echo ""

SIZES=(64 512 1024 4096 16384 65536 262144 1048576)
ITERATIONS=1000

echo "=== Method 1: Using strace to count system calls ==="
echo ""

echo "Testing socket (small packet)..."
strace -c -e trace=write,read,sendto,recvfrom \
    qperf 127.0.0.1 -m 512 -t 5 2>&1 | grep -E "(write|read|sendto|recvfrom|% time)"

echo ""
echo "Testing shmipc (small packet)..."
strace -c -e trace=write,read,sendto,recvfrom \
    LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 512 -t 5 2>&1 | grep -E "(write|read|sendto|recvfrom|% time)"

echo ""
echo "Testing socket (large packet)..."
strace -c -e trace=write,read,sendto,recvfrom \
    qperf 127.0.0.1 -m 524288 -t 5 2>&1 | grep -E "(write|read|sendto|recvfrom|% time)"

echo ""
echo "Testing shmipc (large packet)..."
strace -c -e trace=write,read,sendto,recvfrom \
    LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 524288 -t 5 2>&1 | grep -E "(write|read|sendto|recvfrom|% time)"

echo ""
echo "=== Method 2: Using ltrace to count library calls ==="
echo ""

echo "Testing socket (memcpy calls)..."
ltrace -c -e memcpy+memmove \
    qperf 127.0.0.1 -m 65536 -t 5 2>&1 | grep -E "(memcpy|memmove|% time)"

echo ""
echo "Testing shmipc original (memcpy calls)..."
ltrace -c -e memcpy+memmove \
    LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 65536 -t 5 2>&1 | grep -E "(memcpy|memmove|% time)"

echo ""
echo "Testing shmipc optimized (memcpy calls)..."
if [ -f ./libshmipc_optimized.so ]; then
    ltrace -c -e memcpy+memmove \
        LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 -m 65536 -t 5 2>&1 | grep -E "(memcpy|memmove|% time)"
fi

echo ""
echo "=== Method 3: Using perf to count cache references ==="
echo ""

echo "Testing socket..."
perf stat -e cache-references,cache-misses,L1-dcache-load-misses \
    qperf 127.0.0.1 -m 65536 -t 5 2>&1 | grep -E "(cache|instructions)"

echo ""
echo "Testing shmipc original..."
perf stat -e cache-references,cache-misses,L1-dcache-load-misses \
    LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 65536 -t 5 2>&1 | grep -E "(cache|instructions)"

echo ""
echo "Testing shmipc optimized..."
if [ -f ./libshmipc_optimized.so ]; then
    perf stat -e cache-references,cache-misses,L1-dcache-load-misses \
        LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 -m 65536 -t 5 2>&1 | grep -E "(cache|instructions)"
fi

echo ""
echo "=== Summary ==="
echo ""
echo "Key metrics to compare:"
echo "  1. System call count (strace) - lower is better for shmipc"
echo "  2. memcpy call count (ltrace) - optimized version should have fewer calls"
echo "  3. Cache miss rate (perf) - lower is better"
echo ""
echo "Expected results:"
echo "  - shmipc should have fewer system calls"
echo "  - Optimized version should have ~50% fewer memcpy calls"
echo "  - Cache miss rate should be similar or better"
