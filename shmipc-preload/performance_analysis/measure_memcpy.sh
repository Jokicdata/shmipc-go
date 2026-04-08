#!/bin/bash

echo "=== Memory Copy Performance Test ==="
echo "This script measures memcpy performance for different sizes"
echo ""

cd ..

SIZES=(64 256 512 1024 4096 8192 16384 32768 65536 131072 262144 524288 1048576 4194304 16777216)
ITERATIONS=10000

echo "Size(Bytes), Iterations, Total Time(ms), Avg Time(ns), Bandwidth(GB/s)"
echo "---------------------------------------------------------------------"

for SIZE in "${SIZES[@]}"; do
    SRC_FILE=/tmp/memcpy_src_$$_$SIZE
    DST_FILE=/tmp/memcpy_dst_$$_$SIZE
    
    dd if=/dev/urandom of=$SRC_FILE bs=$SIZE count=1 2>/dev/null
    dd if=/dev/zero of=$DST_FILE bs=$SIZE count=1 2>/dev/null
    
    START=$(date +%s%N)
    
    for i in $(seq 1 $ITERATIONS); do
        cp $SRC_FILE $DST_FILE
    done
    
    END=$(date +%s%N)
    
    TOTAL_NS=$((END - START))
    AVG_NS=$((TOTAL_NS / ITERATIONS))
    TOTAL_MS=$((TOTAL_NS / 1000000))
    
    BYTES=$((SIZE * ITERATIONS))
    BYTES_GB=$(echo "scale=6; $BYTES / 1073741824" | bc)
    TIME_SEC=$(echo "scale=6; $TOTAL_NS / 1000000000" | bc)
    BANDWIDTH=$(echo "scale=2; $BYTES_GB / $TIME_SEC" | bc)
    
    echo "$SIZE, $ITERATIONS, $TOTAL_MS, $AVG_NS, $BANDWIDTH"
    
    rm -f $SRC_FILE $DST_FILE
done

echo ""
echo "=== CGO Call Overhead Estimation ==="
echo "Testing function call overhead..."

START=$(date +%s%N)
for i in $(seq 1 100000); do
    true
done
END=$(date +%s%N)
BASELINE_NS=$(( (END - START) / 100000 ))
echo "Baseline (empty loop): ${BASELINE_NS} ns per iteration"

START=$(date +%s%N)
for i in $(seq 1 100000); do
    echo -n "" > /dev/null
done
END=$(date +%s%N)
SYSCALL_NS=$(( (END - START) / 100000 ))
echo "System call overhead: ${SYSCALL_NS} ns per call"

CGO_OVERHEAD=$((SYSCALL_NS - BASELINE_NS))
echo "Estimated CGO overhead: ~${CGO_OVERHEAD} ns"

echo ""
echo "=== Memory Bandwidth Test (using mbw) ==="
if command -v mbw &> /dev/null; then
    mbw -n 10 256M
else
    echo "mbw not installed. Install with: sudo apt install mbw"
    echo "Alternative: use 'stream' benchmark"
fi

echo ""
echo "=== Cache Performance Test ==="
if command -v likwid-pin &> /dev/null; then
    echo "LIKWID available. Run: likwid-perfctr -C 0 -g L2CACHE <command>"
else
    echo "For detailed cache analysis, install LIKWID:"
    echo "  git clone https://github.com/RRZE-HPC/likwid.git"
    echo "  cd likwid && make && sudo make install"
fi
