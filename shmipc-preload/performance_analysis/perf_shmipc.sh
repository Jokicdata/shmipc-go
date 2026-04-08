#!/bin/bash

OUTPUT_DIR=./perf_results
mkdir -p $OUTPUT_DIR

echo "=== Performance Analysis for shmipc ==="
echo "This script uses perf to analyze performance bottlenecks"
echo ""

if ! command -v perf &> /dev/null; then
    echo "Error: perf is not installed."
    echo "Install with: sudo apt install linux-tools-common linux-tools-generic linux-tools-\$(uname -r)"
    exit 1
fi

cd ..

echo "=== 1. Recording Performance Events ==="
echo "Testing with small packets (512 bytes)..."
perf record -e cycles,instructions,cache-references,cache-misses,dTLB-load-misses,dTLB-store-misses \
    -g -o $OUTPUT_DIR/perf_small.data \
    -- LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 512 -t 10 2>/dev/null

echo ""
echo "Testing with large packets (512KB)..."
perf record -e cycles,instructions,cache-references,cache-misses,dTLB-load-misses,dTLB-store-misses \
    -g -o $OUTPUT_DIR/perf_large.data \
    -- LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 524288 -t 10 2>/dev/null

echo ""
echo "=== 2. Generating Reports ==="
perf report -i $OUTPUT_DIR/perf_small.data --stdio > $OUTPUT_DIR/perf_report_small.txt 2>/dev/null
perf report -i $OUTPUT_DIR/perf_large.data --stdio > $OUTPUT_DIR/perf_report_large.txt 2>/dev/null

echo ""
echo "=== 3. Top 20 Hot Functions (Small Packets) ==="
perf report -i $OUTPUT_DIR/perf_small.data --stdio --sort symbol -n --percent-limit 0.5 2>/dev/null | head -50

echo ""
echo "=== 4. Top 20 Hot Functions (Large Packets) ==="
perf report -i $OUTPUT_DIR/perf_large.data --stdio --sort symbol -n --percent-limit 0.5 2>/dev/null | head -50

echo ""
echo "=== 5. Memory Access Analysis ==="
if perf mem record -e ldlat_loads,ldlat_stores -o $OUTPUT_DIR/perf_mem.data \
    -- LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 65536 -t 5 2>/dev/null; then
    perf mem report -i $OUTPUT_DIR/perf_mem.data --stdio > $OUTPUT_DIR/perf_mem_report.txt 2>/dev/null
    echo "Memory report saved to: $OUTPUT_DIR/perf_mem_report.txt"
else
    echo "Memory profiling not supported on this system"
fi

echo ""
echo "=== 6. CGO Overhead Analysis ==="
echo "Testing small packets..."
perf stat -e task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions \
    -- LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 512 -t 10 2> $OUTPUT_DIR/perf_stat_small.txt

echo ""
echo "Testing large packets..."
perf stat -e task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions \
    -- LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 524288 -t 10 2> $OUTPUT_DIR/perf_stat_large.txt

echo ""
echo "=== 7. Cache Analysis ==="
perf stat -e L1-dcache-loads,L1-dcache-load-misses,L1-dcache-stores,LLC-loads,LLC-load-misses \
    -- LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 65536 -t 10 2> $OUTPUT_DIR/perf_cache.txt

echo ""
echo "=== Results Summary ==="
echo "All results saved to: $OUTPUT_DIR/"
ls -lh $OUTPUT_DIR/

echo ""
echo "=== Key Metrics ==="
echo "Small packet stats:"
cat $OUTPUT_DIR/perf_stat_small.txt | grep -E "(task-clock|context-switches|page-faults|cycles|instructions)"

echo ""
echo "Large packet stats:"
cat $OUTPUT_DIR/perf_stat_large.txt | grep -E "(task-clock|context-switches|page-faults|cycles|instructions)"
