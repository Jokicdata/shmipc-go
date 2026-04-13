#!/bin/bash
LOG=/tmp/shmipc_trace.log

if [ ! -f "$LOG" ]; then
    echo "Trace log not found: $LOG"
    echo "Run with: SHMIPC_TRACE=1 LD_PRELOAD=./libshmipc_trace.so qperf ..."
    exit 1
fi

echo "=========================================="
echo "  shmipc Trace Analysis Report"
echo "=========================================="
echo ""

echo "--- Connection Events ---"
grep -E "INIT|CLIENT_CONN|SERVER_CONN|OPEN_STREAM|ACCEPT_STREAM|CLOSE" "$LOG" | head -20
echo ""

echo "--- WRITE Statistics ---"
write_count=$(grep -c "WRITE" "$LOG")
echo "Total WRITE calls: $write_count"

if [ "$write_count" -gt 0 ]; then
    echo ""
    echo "  Per-stage average (ms):"
    grep "WRITE" "$LOG" | awk -F't_reduce=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Reserve (get shm buffer): %.4f\n", sum/count}'
    grep "WRITE" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Memcpy  (data -> shm):   %.4f\n", sum/count}'
    grep "WRITE" "$LOG" | awk -F't_flush=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Flush   (notify peer):   %.4f\n", sum/count}'
    grep "WRITE" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Total:                  %.4f\n", sum/count}'

    echo ""
    echo "  Per-stage percentage:"
    reserve_avg=$(grep "WRITE" "$LOG" | awk -F't_reduce=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    copy_avg=$(grep "WRITE" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    flush_avg=$(grep "WRITE" "$LOG" | awk -F't_flush=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    total_avg=$(grep "WRITE" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')

    if [ "$(echo "$total_avg > 0" | bc -l 2>/dev/null)" = "1" ] 2>/dev/null; then
        printf "    Reserve: %.1f%%\n" "$(echo "$reserve_avg / $total_avg * 100" | bc -l)"
        printf "    Memcpy:  %.1f%%\n" "$(echo "$copy_avg / $total_avg * 100" | bc -l)"
        printf "    Flush:   %.1f%%\n" "$(echo "$flush_avg / $total_avg * 100" | bc -l)"
    else
        echo "    (unable to calculate percentages)"
    fi

    echo ""
    echo "  Data size distribution:"
    grep "WRITE" "$LOG" | awk -F'size=' '{split($2,a," "); print a[1]}' | \
        sort -n | uniq -c | sort -rn | head -10
fi

echo ""
echo "--- READ Statistics ---"
read_count=$(grep -c "READ" "$LOG")
echo "Total READ calls: $read_count"

if [ "$read_count" -gt 0 ]; then
    echo ""
    echo "  Per-stage average (ms):"
    grep "READ" "$LOG" | awk -F't_read=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Read    (from shm):       %.4f\n", sum/count}'
    grep "READ" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Memcpy  (shm -> buf):     %.4f\n", sum/count}'
    grep "READ" "$LOG" | awk -F't_release=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Release (recycle buf):    %.4f\n", sum/count}'
    grep "READ" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | \
        awk '{sum+=$1; count++} END {printf "    Total:                    %.4f\n", sum/count}'

    echo ""
    echo "  Per-stage percentage:"
    read_avg=$(grep "READ" "$LOG" | awk -F't_read=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    rcopy_avg=$(grep "READ" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    release_avg=$(grep "READ" "$LOG" | awk -F't_release=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
    rtotal_avg=$(grep "READ" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')

    if [ "$(echo "$rtotal_avg > 0" | bc -l 2>/dev/null)" = "1" ] 2>/dev/null; then
        printf "    Read:    %.1f%%\n" "$(echo "$read_avg / $rtotal_avg * 100" | bc -l)"
        printf "    Memcpy:  %.1f%%\n" "$(echo "$rcopy_avg / $rtotal_avg * 100" | bc -l)"
        printf "    Release: %.1f%%\n" "$(echo "$release_avg / $rtotal_avg * 100" | bc -l)"
    else
        echo "    (unable to calculate percentages)"
    fi
fi

echo ""
echo "=========================================="
