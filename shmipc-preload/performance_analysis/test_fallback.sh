#!/bin/bash

echo "=== shmipc Fallback Detection Test ==="
echo "This test checks if shmipc is falling back to socket mode"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

export SHMIPC_LOG=3

echo "1. Testing with small buffer (should trigger fallback)..."
export SHMIPC_BUFFER_SIZE=$((1 * 1024 * 1024))

echo "Starting server with 1MB buffer..."
LD_PRELOAD=./libshmipc.so qperf &
SRV_PID=$!
sleep 2

echo "Sending large data (should see fallback warnings)..."
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 1048576 -t 5 tcp_bw 2>&1 | tee /tmp/fallback_test.log

kill $SRV_PID 2>/dev/null
sleep 1

echo ""
echo "2. Testing with large buffer (should not fallback)..."
export SHMIPC_BUFFER_SIZE=$((256 * 1024 * 1024))

echo "Starting server with 256MB buffer..."
LD_PRELOAD=./libshmipc.so qperf &
SRV_PID=$!
sleep 2

echo "Sending large data (should NOT see fallback warnings)..."
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 1048576 -t 5 tcp_bw 2>&1 | tee /tmp/no_fallback_test.log

kill $SRV_PID 2>/dev/null

echo ""
echo "=== Analysis ==="
echo "Fallback occurrences in small buffer test:"
grep -c "fallback" /tmp/fallback_test.log 2>/dev/null || echo "0"

echo ""
echo "Fallback occurrences in large buffer test:"
grep -c "fallback" /tmp/no_fallback_test.log 2>/dev/null || echo "0"

echo ""
echo "If you see fallback warnings, consider increasing SHMIPC_BUFFER_SIZE"
