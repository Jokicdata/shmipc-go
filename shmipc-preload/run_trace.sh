#!/bin/bash
###############################################################################
# run_trace.sh - 一键全链路追踪脚本
#
# 功能：
#   同时使用多种追踪工具，完整记录 qperf 从启动到结束的全过程调用：
#   1. shmipc 内置追踪 - 代码内部打点，精确到 Reserve/memcpy/Flush 各阶段
#   2. strace          - 追踪系统调用（write/read/send/recv/epoll_wait 等）
#   3. ltrace          - 追踪动态库函数（write/send/ShmipcWrite 等）
#   4. perf stat       - 记录整体性能计数器（CPU 周期、缓存命中率等）
#
# 使用方式：
#   sudo ./run_trace.sh                          # 默认：preload 模式，512KB
#   sudo ./run_trace.sh --normal                 # 正常 TCP 模式
#   sudo ./run_trace.sh --msg-size 1024          # 小消息测试
#   sudo ./run_trace.sh --duration 30            # 追踪 30 秒
#   sudo ./run_trace.sh --tools strace,ltrace    # 只用指定工具
#
# 输出文件（在 OUTPUT_DIR 目录下）：
#   shmipc_trace.log     - shmipc 内置追踪日志
#   strace_client.log    - 客户端 strace 输出
#   strace_server.log    - 服务端 strace 输出
#   ltrace_client.log    - 客户端 ltrace 输出
#   perf_stat.log        - perf stat 性能计数器
#   trace_report.txt     - 汇总分析报告
#
# 依赖：strace, ltrace, perf, qperf, bc
###############################################################################

set -e

# ===== 配置参数 =====
MSG_SIZE=524288          # 消息大小（字节）
DURATION=15              # 追踪时长（秒）
QPERF_TEST_TIME=10       # qperf 测试时长（秒）
MODE="preload"           # 默认模式
SHMIPC_DIR=""            # shmipc-preload 目录
TOOLS="shmipc,strace,ltrace,perf"  # 使用的追踪工具

# ===== 解析命令行参数 =====
while [[ $# -gt 0 ]]; do
    case $1 in
        --normal)   MODE="normal";   shift ;;
        --preload)  MODE="preload";  shift ;;
        --msg-size) MSG_SIZE="$2";   shift 2 ;;
        --duration) DURATION="$2";   shift 2 ;;
        --tools)    TOOLS="$2";      shift 2 ;;
        --dir)      SHMIPC_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 [--normal|--preload] [--msg-size SIZE] [--duration SECS] [--tools LIST]"
            echo ""
            echo "Tools: shmipc,strace,ltrace,perf (comma-separated, default: all)"
            echo "  shmipc  - shmipc built-in trace (Reserve/memcpy/Flush timing)"
            echo "  strace  - System call trace (write/read/epoll_wait etc.)"
            echo "  ltrace  - Library call trace (write/send/ShmipcWrite etc.)"
            echo "  perf    - Performance counters (CPU cycles, cache misses etc.)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ===== 解析工具列表 =====
USE_SHMIPC=0; USE_STRACE=0; USE_LTRACE=0; USE_PERF=0
IFS=',' read -ra TOOL_LIST <<< "$TOOLS"
for t in "${TOOL_LIST[@]}"; do
    case $t in
        shmipc) USE_SHMIPC=1 ;;
        strace) USE_STRACE=1 ;;
        ltrace) USE_LTRACE=1 ;;
        perf)   USE_PERF=1   ;;
        *) echo "Unknown tool: $t (available: shmipc,strace,ltrace,perf)"; exit 1 ;;
    esac
done

# ===== 自动检测 shmipc-preload 目录 =====
if [ -z "$SHMIPC_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/Makefile" ]; then
        SHMIPC_DIR="$SCRIPT_DIR"
    else
        echo "ERROR: Cannot find shmipc-preload directory. Use --dir"
        exit 1
    fi
fi

# ===== 创建输出目录 =====
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="$SHMIPC_DIR/trace_output_$TIMESTAMP"
mkdir -p "$OUTPUT_DIR"

# ===== 检查 root =====
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script requires root. Run with sudo."
    exit 1
fi

# ===== 检查工具 =====
check_tool() {
    if ! command -v "$1" &> /dev/null; then
        echo "WARNING: $1 not found. Skipping $1 tracing."
        eval "USE_$(echo $1 | tr '[:lower:]' '[:upper:]')=0"
    fi
}
[ $USE_STRACE -eq 1 ] && check_tool strace
[ $USE_LTRACE -eq 1 ] && check_tool ltrace
[ $USE_PERF -eq 1 ]   && check_tool perf

# ===== 打印配置 =====
echo ""
echo "=========================================="
echo "  shmipc Full Trace Analysis"
echo "=========================================="
echo ""
echo "Mode:       $MODE"
echo "Msg size:   $MSG_SIZE bytes ($(( MSG_SIZE / 1024 )) KB)"
echo "Duration:   $DURATION seconds"
echo "Tools:      $TOOLS"
echo "Output:     $OUTPUT_DIR"
echo ""

cd "$SHMIPC_DIR"

# ===== 编译 =====
echo "[1/5] Building shmipc..."
if [ $USE_SHMIPC -eq 1 ] && [ "$MODE" = "preload" ]; then
    make -f Makefile.trace > /dev/null 2>&1 || { echo "Trace build failed!"; exit 1; }
    echo "  Built: libshmipc_trace.so"
fi
if [ "$MODE" = "preload" ]; then
    make opt > /dev/null 2>&1 || { echo "Opt build failed!"; exit 1; }
    echo "  Built: libshmipc_opt.so"
fi

# ===== 清理旧进程 =====
pkill -9 qperf 2>/dev/null || true
rm -f /tmp/shmipc_trace.log
sleep 1

# ===== 启动服务端 =====
echo ""
echo "[2/5] Starting qperf server..."

if [ "$MODE" = "preload" ]; then
    if [ $USE_SHMIPC -eq 1 ]; then
        # 使用追踪版服务端（记录内部打点）
        SHMIPC_TRACE=1 LD_PRELOAD="$SHMIPC_DIR/libshmipc_trace.so" qperf &
    else
        LD_PRELOAD="$SHMIPC_DIR/libshmipc_opt.so" qperf &
    fi
else
    qperf &
fi
SERVER_PID=$!
echo "  Server PID: $SERVER_PID"
sleep 2

# ===== 启动 perf stat =====
if [ $USE_PERF -eq 1 ]; then
    echo "  Starting perf stat..."
    perf stat -a -o "$OUTPUT_DIR/perf_stat.log" -- sleep "$DURATION" &
    PERF_PID=$!
fi

# ===== 启动客户端（带追踪） =====
echo ""
echo "[3/5] Starting qperf client with tracing..."

# 构建 strace 命令
STRACE_CMD=""
if [ $USE_STRACE -eq 1 ]; then
    STRACE_CMD="strace -T -tt -o $OUTPUT_DIR/strace_client.log -e trace=write,read,send,recv,sendto,recvfrom,epoll_wait,epoll_ctl,socket,connect,close"
    echo "  strace: ON -> $OUTPUT_DIR/strace_client.log"
fi

# 构建 ltrace 命令
LTRACE_CMD=""
if [ $USE_LTRACE -eq 1 ]; then
    LTRACE_CMD="ltrace -T -tt -o $OUTPUT_DIR/ltrace_client.log -e write+read+send+recv+sendto+recvfrom+ShmipcWrite+ShmipcRead+ShmipcFlush"
    echo "  ltrace: ON -> $OUTPUT_DIR/ltrace_client.log"
fi

# 构建 LD_PRELOAD 命令
PRELOAD_CMD=""
if [ "$MODE" = "preload" ]; then
    if [ $USE_SHMIPC -eq 1 ]; then
        PRELOAD_CMD="SHMIPC_TRACE=1 LD_PRELOAD=$SHMIPC_DIR/libshmipc_trace.so"
    else
        PRELOAD_CMD="LD_PRELOAD=$SHMIPC_DIR/libshmipc_opt.so"
    fi
fi

# 启动客户端
eval $STRACE_CMD $LTRACE_CMD $PRELOAD_CMD \
    qperf 127.0.0.1 -msg_size "$MSG_SIZE" -t "$QPERF_TEST_TIME" tcp_bw tcp_lat \
    > "$OUTPUT_DIR/qperf_result.txt" 2>&1 &
CLIENT_PID=$!
echo "  Client PID: $CLIENT_PID"

# ===== 等待完成 =====
echo ""
echo "[4/5] Waiting for test to complete (up to ${DURATION}s)..."

# 等待客户端退出
wait $CLIENT_PID 2>/dev/null || true
echo "  Client finished."

# 等待 perf stat
if [ $USE_PERF -eq 1 ]; then
    wait $PERF_PID 2>/dev/null || true
    echo "  perf stat finished."
fi

# 复制 shmipc 追踪日志
if [ $USE_SHMIPC -eq 1 ] && [ -f /tmp/shmipc_trace.log ]; then
    cp /tmp/shmipc_trace.log "$OUTPUT_DIR/shmipc_trace.log"
    echo "  shmipc trace captured."
fi

# strace 服务端（可选，只抓最后几秒）
if [ $USE_STRACE -eq 1 ]; then
    strace -T -tt -p $SERVER_PID -o "$OUTPUT_DIR/strace_server.log" -e trace=write,read,send,recv,epoll_wait &
    STRACE_SERVER_PID=$!
    sleep 3
    kill $STRACE_SERVER_PID 2>/dev/null || true
    echo "  strace server captured."
fi

# 清理
kill $SERVER_PID 2>/dev/null || true
pkill -9 qperf 2>/dev/null || true
sleep 1

# ===== 生成分析报告 =====
echo ""
echo "[5/5] Generating analysis report..."

REPORT="$OUTPUT_DIR/trace_report.txt"

cat > "$REPORT" << EOF
==========================================
  shmipc Full Trace Analysis Report
==========================================

Test config:
  Mode:       $MODE
  Msg size:   $MSG_SIZE bytes ($(( MSG_SIZE / 1024 )) KB)
  Duration:   $DURATION seconds
  Timestamp:  $TIMESTAMP

==========================================
  1. qperf Result
==========================================

EOF

if [ -f "$OUTPUT_DIR/qperf_result.txt" ]; then
    cat "$OUTPUT_DIR/qperf_result.txt" >> "$REPORT"
else
    echo "(no qperf result)" >> "$REPORT"
fi

# ===== shmipc 内置追踪分析 =====
if [ $USE_SHMIPC -eq 1 ] && [ -f "$OUTPUT_DIR/shmipc_trace.log" ]; then
    cat >> "$REPORT" << EOF

==========================================
  2. shmipc Built-in Trace
==========================================

EOF

    LOG="$OUTPUT_DIR/shmipc_trace.log"

    # 连接事件
    echo "--- Connection Events ---" >> "$REPORT"
    grep -E "INIT|CLIENT_CONN|SERVER_CONN|OPEN_STREAM|ACCEPT_STREAM|CLOSE" "$LOG" | head -20 >> "$REPORT"
    echo "" >> "$REPORT"

    # WRITE 统计
    write_count=$(grep -c "WRITE" "$LOG" 2>/dev/null || echo "0")
    echo "--- WRITE Statistics (total: $write_count calls) ---" >> "$REPORT"

    if [ "$write_count" -gt 0 ]; then
        echo "" >> "$REPORT"
        echo "  Per-stage average (ms):" >> "$REPORT"
        grep "WRITE" "$LOG" | awk -F't_reduce=' '{split($2,a," "); print a[1]}' | \
            awk '{sum+=$1; count++} END {printf "    Reserve (get shm buffer): %.4f\n", sum/count}' >> "$REPORT"
        grep "WRITE" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | \
            awk '{sum+=$1; count++} END {printf "    Memcpy  (data -> shm):   %.4f\n", sum/count}' >> "$REPORT"
        grep "WRITE" "$LOG" | awk -F't_flush=' '{split($2,a," "); print a[1]}' | \
            awk '{sum+=$1; count++} END {printf "    Flush   (notify peer):   %.4f\n", sum/count}' >> "$REPORT"
        grep "WRITE" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | \
            awk '{sum+=$1; count++} END {printf "    Total:                  %.4f\n", sum/count}' >> "$REPORT"

        # 百分比
        reserve_avg=$(grep "WRITE" "$LOG" | awk -F't_reduce=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
        copy_avg=$(grep "WRITE" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
        flush_avg=$(grep "WRITE" "$LOG" | awk -F't_flush=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
        total_avg=$(grep "WRITE" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')

        echo "" >> "$REPORT"
        echo "  Per-stage percentage:" >> "$REPORT"
        if [ "$(echo "$total_avg > 0" | bc -l 2>/dev/null)" = "1" ] 2>/dev/null; then
            printf "    Reserve: %.1f%%\n" "$(echo "$reserve_avg / $total_avg * 100" | bc -l)" >> "$REPORT"
            printf "    Memcpy:  %.1f%%\n" "$(echo "$copy_avg / $total_avg * 100" | bc -l)" >> "$REPORT"
            printf "    Flush:   %.1f%%\n" "$(echo "$flush_avg / $total_avg * 100" | bc -l)" >> "$REPORT"
        fi

        # 数据大小分布
        echo "" >> "$REPORT"
        echo "  Data size distribution:" >> "$REPORT"
        grep "WRITE" "$LOG" | awk -F'size=' '{split($2,a," "); print a[1]}' | \
            sort -n | uniq -c | sort -rn | head -10 >> "$REPORT"
    fi

    # READ 统计
    read_count=$(grep -c "READ" "$LOG" 2>/dev/null || echo "0")
    echo "" >> "$REPORT"
    echo "--- READ Statistics (total: $read_count calls) ---" >> "$REPORT"

    if [ "$read_count" -gt 0 ]; then
        echo "" >> "$REPORT"
        echo "  Per-stage average (ms):" >> "$REPORT"
        grep "READ" "$LOG" | awk -F't_read=' '{split($2,a," "); print a[1]}' | \
            awk '{sum+=$1; count++} END {printf "    Read    (from shm):       %.4f\n", sum/count}' >> "$REPORT"
        grep "READ" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | \
            awk '{sum+=$1; count++} END {printf "    Memcpy  (shm -> buf):     %.4f\n", sum/count}' >> "$REPORT"
        grep "READ" "$LOG" | awk -F't_release=' '{split($2,a," "); print a[1]}' | \
            awk '{sum+=$1; count++} END {printf "    Release (recycle buf):    %.4f\n", sum/count}' >> "$REPORT"
        grep "READ" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | \
            awk '{sum+=$1; count++} END {printf "    Total:                    %.4f\n", sum/count}' >> "$REPORT"

        echo "" >> "$REPORT"
        echo "  Per-stage percentage:" >> "$REPORT"
        read_avg=$(grep "READ" "$LOG" | awk -F't_read=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
        rcopy_avg=$(grep "READ" "$LOG" | awk -F't_copy=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
        release_avg=$(grep "READ" "$LOG" | awk -F't_release=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')
        rtotal_avg=$(grep "READ" "$LOG" | awk -F't_total=' '{split($2,a," "); print a[1]}' | awk '{sum+=$1; count++} END {print sum/count}')

        if [ "$(echo "$rtotal_avg > 0" | bc -l 2>/dev/null)" = "1" ] 2>/dev/null; then
            printf "    Read:    %.1f%%\n" "$(echo "$read_avg / $rtotal_avg * 100" | bc -l)" >> "$REPORT"
            printf "    Memcpy:  %.1f%%\n" "$(echo "$rcopy_avg / $rtotal_avg * 100" | bc -l)" >> "$REPORT"
            printf "    Release: %.1f%%\n" "$(echo "$release_avg / $rtotal_avg * 100" | bc -l)" >> "$REPORT"
        fi
    fi
fi

# ===== strace 分析 =====
if [ $USE_STRACE -eq 1 ] && [ -f "$OUTPUT_DIR/strace_client.log" ]; then
    cat >> "$REPORT" << EOF

==========================================
  3. strace Analysis (System Calls)
==========================================

EOF

    echo "--- Top System Calls by Count ---" >> "$REPORT"
    # 提取系统调用名，统计调用次数
    grep -oP '^\d+:\d+:\d+\.\d+\s+\K[a-zA-Z_]+(?=\()' "$OUTPUT_DIR/strace_client.log" 2>/dev/null | \
        sort | uniq -c | sort -rn | head -20 >> "$REPORT" || \
        echo "(unable to parse strace output)" >> "$REPORT"

    echo "" >> "$REPORT"
    echo "--- Top System Calls by Total Time ---" >> "$REPORT"
    # 提取系统调用耗时，按总时间排序
    grep -oP '[a-zA-Z_]+\(.*<\K[0-9.]+' "$OUTPUT_DIR/strace_client.log" 2>/dev/null | \
        paste - <(grep -oP '^\d+:\d+:\d+\.\d+\.\d+\s+\K[a-zA-Z_]+(?=\()' "$OUTPUT_DIR/strace_client.log" 2>/dev/null) | \
        awk '{time[$2]+=$1; count[$2]++} END {for(k in time) printf "%12.6f %6d %s\n", time[k], count[k], k}' | \
        sort -rn | head -20 >> "$REPORT" || \
        echo "(unable to parse strace timing)" >> "$REPORT"

    echo "" >> "$REPORT"
    echo "--- write() Call Samples (first 10) ---" >> "$REPORT"
    grep 'write(' "$OUTPUT_DIR/strace_client.log" | head -10 >> "$REPORT"

    echo "" >> "$REPORT"
    echo "--- read() Call Samples (first 10) ---" >> "$REPORT"
    grep 'read(' "$OUTPUT_DIR/strace_client.log" | head -10 >> "$REPORT"

    echo "" >> "$REPORT"
    echo "--- epoll_wait Call Samples (first 5) ---" >> "$REPORT"
    grep 'epoll_wait' "$OUTPUT_DIR/strace_client.log" | head -5 >> "$REPORT"
fi

# ===== ltrace 分析 =====
if [ $USE_LTRACE -eq 1 ] && [ -f "$OUTPUT_DIR/ltrace_client.log" ]; then
    cat >> "$REPORT" << EOF

==========================================
  4. ltrace Analysis (Library Calls)
==========================================

EOF

    echo "--- Top Library Calls by Count ---" >> "$REPORT"
    grep -oP '^\d+:\d+:\d+\.\d+\s+\K[a-zA-Z_]+' "$OUTPUT_DIR/ltrace_client.log" 2>/dev/null | \
        sort | uniq -c | sort -rn | head -20 >> "$REPORT" || \
        echo "(unable to parse ltrace output)" >> "$REPORT"

    echo "" >> "$REPORT"
    echo "--- ShmipcWrite Call Samples (first 10) ---" >> "$REPORT"
    grep 'ShmipcWrite' "$OUTPUT_DIR/ltrace_client.log" | head -10 >> "$REPORT"

    echo "" >> "$REPORT"
    echo "--- ShmipcRead Call Samples (first 10) ---" >> "$REPORT"
    grep 'ShmipcRead' "$OUTPUT_DIR/ltrace_client.log" | head -10 >> "$REPORT"

    echo "" >> "$REPORT"
    echo "--- write() Call Samples (first 10) ---" >> "$REPORT"
    grep -E '^\d+:\d+:\d+\.\d+\s+write\(' "$OUTPUT_DIR/ltrace_client.log" | head -10 >> "$REPORT"
fi

# ===== perf stat 分析 =====
if [ $USE_PERF -eq 1 ] && [ -f "$OUTPUT_DIR/perf_stat.log" ]; then
    cat >> "$REPORT" << EOF

==========================================
  5. perf stat (Performance Counters)
==========================================

EOF
    cat "$OUTPUT_DIR/perf_stat.log" >> "$REPORT"
fi

# ===== 汇总 =====
cat >> "$REPORT" << EOF

==========================================
  Summary
==========================================

EOF

echo "  Output directory: $OUTPUT_DIR" >> "$REPORT"
echo "" >> "$REPORT"
echo "  Files:" >> "$REPORT"
ls -la "$OUTPUT_DIR" | tail -n +2 | awk '{printf "    %-40s %s\n", $NF, $5" bytes"}' >> "$REPORT"

# ===== 打印结果 =====
echo ""
echo "=========================================="
echo "  Results"
echo "=========================================="
echo ""
cat "$REPORT"
echo ""
echo "Report saved to: $REPORT"
echo ""
echo "Quick commands:"
echo "  cat $OUTPUT_DIR/trace_report.txt"
echo "  cat $OUTPUT_DIR/shmipc_trace.log | head -50"
echo "  cat $OUTPUT_DIR/strace_client.log | head -50"
echo "  cat $OUTPUT_DIR/ltrace_client.log | head -50"
echo ""
