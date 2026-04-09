#!/bin/bash
# ftrace_simple.sh - ftrace 最简单用法
#
# 使用方式:
#   sudo ./ftrace_simple.sh [duration]
#
# 示例:
#   sudo ./ftrace_simple.sh 60    # 追踪 60 秒

DURATION=${1:-60}

echo "=========================================="
echo "ftrace Simple Usage"
echo "Duration: ${DURATION}s"
echo "=========================================="
echo ""

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Need root"
    exit 1
fi

# 检查 ftrace
TRACE_DIR="/sys/kernel/debug/tracing"
if [ ! -d "$TRACE_DIR" ]; then
    echo "Mounting debugfs..."
    mount -t debugfs debugfs /sys/kernel/debug
fi

# ===== 启用 ftrace =====
echo "[1] 启用 function_graph 追踪"

cd "$TRACE_DIR"

echo 0 > tracing_on        # 先停止
echo > trace              # 清空
echo function_graph > current_tracer    # 使用函数图追踪器
echo 1 > tracing_on        # 开始追踪

echo "    ftrace 已启用，${DURATION}秒后自动停止..."
echo "    运行 qperf client: LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -msg_size 524288 -t $DURATION"
echo ""

# ===== 等待 =====
sleep "$DURATION"

# ===== 停止并查看 =====
echo ""
echo "[2] 停止追踪"

echo 0 > tracing_on

echo ""
echo "[3] 查看结果 (trace)"
echo "=========================================="
cat trace | head -100

echo ""
echo "[4] 查看完整结果"
echo "    文件: $TRACE_DIR/trace"
echo "    查看更多: cat $TRACE_DIR/trace | less"
echo ""
echo "[5] 只看 shmipc 相关"
echo "    grep -i shmipc $TRACE_DIR/trace"
