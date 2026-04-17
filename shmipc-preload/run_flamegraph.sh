#!/bin/bash
###############################################################################
# run_flamegraph.sh - 一键生成 shmipc preload 火焰图
#
# 功能：
#   自动完成以下步骤：
#   1. 编译 shmipc 优化版
#   2. 启动 qperf 服务端
#   3. 启动 perf record 采样
#   4. 启动 qperf 客户端
#   5. 生成火焰图 SVG
#   6. 生成文本报告
#
#   支持两种模式：
#     --normal  : 不使用 preload（正常 TCP 路径）
#     --preload : 使用 shmipc preload（默认）
#     --compare : 两种都跑，生成对比火焰图
#
# 使用方式：
#   sudo ./run_flamegraph.sh                    # 默认：preload 模式，512KB 消息
#   sudo ./run_flamegraph.sh --normal           # 正常 TCP 模式
#   sudo ./run_flamegraph.sh --compare          # 两种都跑
#   sudo ./run_flamegraph.sh --msg-size 1024    # 指定消息大小
#   sudo ./run_flamegraph.sh --duration 30      # 指定 perf 采样时长（秒）
#
# 输出文件（在 OUTPUT_DIR 目录下）：
#   normal.svg       - 正常 TCP 火焰图
#   preload.svg      - preload 劫持火焰图
#   diff.svg         - 对比火焰图（红色=preload 更慢，蓝色=更快）
#   normal_report.txt  - 正常路径 perf 文本报告
#   preload_report.txt - preload 路径 perf 文本报告
#
# 依赖：perf, qperf, FlameGraph, bc
###############################################################################

set -e

# ===== 配置参数 =====
MSG_SIZE=524288          # 消息大小（字节），默认 512KB
DURATION=15              # perf 采样时长（秒）
QPERF_TEST_TIME=10       # qperf 测试时长（秒）
MODE="preload"           # 默认模式
SHMIPC_DIR=""            # shmipc-preload 目录，自动检测
OUTPUT_DIR=""            # 输出目录，自动创建
FLAMEGRAPH_DIR=""        # FlameGraph 工具目录

# ===== 解析命令行参数 =====
while [[ $# -gt 0 ]]; do
    case $1 in
        --normal)   MODE="normal";   shift ;;
        --preload)  MODE="preload";  shift ;;
        --compare)  MODE="compare";  shift ;;
        --msg-size) MSG_SIZE="$2";   shift 2 ;;
        --duration) DURATION="$2";   shift 2 ;;
        --dir)      SHMIPC_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 [--normal|--preload|--compare] [--msg-size SIZE] [--duration SECS]"
            echo ""
            echo "Options:"
            echo "  --normal      Run without LD_PRELOAD (normal TCP)"
            echo "  --preload     Run with LD_PRELOAD (shmipc preload, default)"
            echo "  --compare     Run both modes and generate diff flamegraph"
            echo "  --msg-size    Message size in bytes (default: 524288)"
            echo "  --duration    perf record duration in seconds (default: 15)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ===== 自动检测 shmipc-preload 目录 =====
if [ -z "$SHMIPC_DIR" ]; then
    # 尝试从脚本所在目录查找
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/libshmipc_opt.so" ] || [ -f "$SCRIPT_DIR/Makefile" ]; then
        SHMIPC_DIR="$SCRIPT_DIR"
    else
        echo "ERROR: Cannot find shmipc-preload directory."
        echo "Please specify with --dir /path/to/shmipc-preload"
        exit 1
    fi
fi

# ===== 自动检测 FlameGraph 目录 =====
for candidate in ~/FlameGraph /opt/FlameGraph "$SHMIPC_DIR/FlameGraph"; do
    if [ -f "$candidate/stackcollapse-perf.pl" ]; then
        FLAMEGRAPH_DIR="$candidate"
        break
    fi
done

if [ -z "$FLAMEGRAPH_DIR" ]; then
    echo "FlameGraph not found, downloading..."
    git clone --depth 1 https://github.com/brendangregg/FlameGraph.git ~/FlameGraph
    FLAMEGRAPH_DIR=~/FlameGraph
fi

# ===== 创建输出目录 =====
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="$SHMIPC_DIR/flamegraph_output_$TIMESTAMP"
mkdir -p "$OUTPUT_DIR"

# ===== 检查 root 权限 =====
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script requires root (for perf record). Run with sudo."
    exit 1
fi

# ===== 检查工具 =====
for tool in perf qperf; do
    if ! command -v $tool &> /dev/null; then
        echo "ERROR: $tool not found. Install it first."
        exit 1
    fi
done

# ===== 设置 perf 权限 =====
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "2")
if [ "$PARANOID" -gt 1 ]; then
    echo "Setting perf_event_paranoid=1 ..."
    sysctl -w kernel.perf_event_paranoid=1
fi

# ===== 编译 shmipc =====
echo ""
echo "=========================================="
echo "  shmipc FlameGraph Analysis"
echo "=========================================="
echo ""
echo "Mode:       $MODE"
echo "Msg size:   $MSG_SIZE bytes ($(( MSG_SIZE / 1024 )) KB)"
echo "Duration:   $DURATION seconds"
echo "Output:     $OUTPUT_DIR"
echo ""

cd "$SHMIPC_DIR"

if [ "$MODE" != "normal" ]; then
    echo "[1/6] Building shmipc optimized version..."
    make opt > /dev/null 2>&1 || { echo "Build failed!"; exit 1; }
    echo "  Build OK: libshmipc_opt.so"
fi

# ===== 定义运行函数 =====
run_test() {
    local label="$1"       # "normal" or "preload"
    local data_file="$2"   # perf data 文件名
    local svg_file="$3"    # 火焰图 SVG 文件名
    local report_file="$4" # 文本报告文件名

    echo ""
    echo "--- Running: $label mode ---"

    # 清理旧的 qperf 进程
    pkill -9 qperf 2>/dev/null || true
    sleep 1

    # 启动 qperf 服务端
    if [ "$label" = "preload" ]; then
        LD_PRELOAD="$SHMIPC_DIR/libshmipc_opt.so" qperf &
    else
        qperf &
    fi
    local SERVER_PID=$!
    echo "  Server PID: $SERVER_PID"
    sleep 2

    # 启动 perf record
    echo "  Starting perf record (${DURATION}s)..."
    perf record -F 999 -a -g -o "$OUTPUT_DIR/$data_file" -- sleep "$DURATION" &
    local PERF_PID=$!
    sleep 1

    # 启动 qperf 客户端
    echo "  Starting qperf client (msg_size=$MSG_SIZE)..."
    if [ "$label" = "preload" ]; then
        LD_PRELOAD="$SHMIPC_DIR/libshmipc_opt.so" \
            qperf 127.0.0.1 -msg_size "$MSG_SIZE" -t "$QPERF_TEST_TIME" tcp_bw tcp_lat \
            > "$OUTPUT_DIR/${label}_qperf_result.txt" 2>&1 &
    else
        qperf 127.0.0.1 -msg_size "$MSG_SIZE" -t "$QPERF_TEST_TIME" tcp_bw tcp_lat \
            > "$OUTPUT_DIR/${label}_qperf_result.txt" 2>&1 &
    fi
    local CLIENT_PID=$!

    # 等待 perf 完成
    echo "  Waiting for perf to finish..."
    wait $PERF_PID 2>/dev/null || true

    # 清理
    kill $CLIENT_PID 2>/dev/null || true
    kill $SERVER_PID 2>/dev/null || true
    pkill -9 qperf 2>/dev/null || true
    sleep 1

    # 生成火焰图
    echo "  Generating flamegraph..."
    perf script -i "$OUTPUT_DIR/$data_file" > "$OUTPUT_DIR/${data_file}.script" 2>/dev/null || true
    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" "$OUTPUT_DIR/${data_file}.script" > "$OUTPUT_DIR/${data_file}.folded" 2>/dev/null || true
    "$FLAMEGRAPH_DIR/flamegraph.pl" --title "$label (msg_size=$MSG_SIZE)" --colors=java \
        "$OUTPUT_DIR/${data_file}.folded" > "$OUTPUT_DIR/$svg_file" 2>/dev/null || true

    # 生成文本报告
    echo "  Generating text report..."
    perf report --stdio -g none -i "$OUTPUT_DIR/$data_file" > "$OUTPUT_DIR/$report_file" 2>/dev/null || true

    echo "  Done: $OUTPUT_DIR/$svg_file"
}

# ===== 执行测试 =====
echo "[2/6] Running performance tests..."

case $MODE in
    normal)
        run_test "normal" "perf_normal.data" "normal.svg" "normal_report.txt"
        ;;
    preload)
        run_test "preload" "perf_preload.data" "preload.svg" "preload_report.txt"
        ;;
    compare)
        run_test "normal"  "perf_normal.data"  "normal.svg"  "normal_report.txt"
        run_test "preload" "perf_preload.data" "preload.svg" "preload_report.txt"

        echo ""
        echo "[3/6] Generating diff flamegraph..."
        "$FLAMEGRAPH_DIR/difffolded.pl" \
            "$OUTPUT_DIR/perf_normal.data.folded" \
            "$OUTPUT_DIR/perf_preload.data.folded" \
            > "$OUTPUT_DIR/diff.folded" 2>/dev/null || true
        "$FLAMEGRAPH_DIR/flamegraph.pl" --title "Normal vs Preload (msg_size=$MSG_SIZE)" \
            "$OUTPUT_DIR/diff.folded" > "$OUTPUT_DIR/diff.svg" 2>/dev/null || true
        echo "  Done: $OUTPUT_DIR/diff.svg"
        ;;
esac

# ===== 生成摘要报告 =====
echo ""
echo "[4/6] Generating summary report..."

cat > "$OUTPUT_DIR/summary.txt" << EOF
==========================================
  shmipc FlameGraph Analysis Summary
==========================================

Test config:
  Mode:       $MODE
  Msg size:   $MSG_SIZE bytes ($(( MSG_SIZE / 1024 )) KB)
  Duration:   $DURATION seconds
  Timestamp:  $TIMESTAMP

Output files:
EOF

ls -la "$OUTPUT_DIR"/*.svg "$OUTPUT_DIR"/*.txt 2>/dev/null | awk '{print "  " $NF}' >> "$OUTPUT_DIR/summary.txt"

# 提取关键函数占比
echo "" >> "$OUTPUT_DIR/summary.txt"
echo "Top functions (normal):" >> "$OUTPUT_DIR/summary.txt"
if [ -f "$OUTPUT_DIR/normal_report.txt" ]; then
    head -30 "$OUTPUT_DIR/normal_report.txt" >> "$OUTPUT_DIR/summary.txt"
fi

echo "" >> "$OUTPUT_DIR/summary.txt"
echo "Top functions (preload):" >> "$OUTPUT_DIR/summary.txt"
if [ -f "$OUTPUT_DIR/preload_report.txt" ]; then
    head -30 "$OUTPUT_DIR/preload_report.txt" >> "$OUTPUT_DIR/summary.txt"
fi

# ===== qperf 结果 =====
echo ""
echo "[5/6] qperf results:"
for f in "$OUTPUT_DIR"/*_qperf_result.txt; do
    if [ -f "$f" ]; then
        echo ""
        echo "--- $(basename $f) ---"
        cat "$f"
    fi
done

# ===== 完成 =====
echo ""
echo "[6/6] All done!"
echo ""
echo "=========================================="
echo "  Results"
echo "=========================================="
echo ""
echo "Output directory: $OUTPUT_DIR"
echo ""
echo "Files:"
ls -la "$OUTPUT_DIR" | tail -n +2 | awk '{printf "  %-40s %s\n", $NF, $5" bytes"}'
echo ""
echo "View flamegraphs:"
for svg in "$OUTPUT_DIR"/*.svg; do
    echo "  $svg"
done
echo ""
echo "Quick view:"
echo "  cat $OUTPUT_DIR/summary.txt"
echo "  cat $OUTPUT_DIR/preload_report.txt | head -30"
echo ""
