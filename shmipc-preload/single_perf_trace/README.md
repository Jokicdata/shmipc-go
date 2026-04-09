# shmipc Single Command Performance Analysis Guide

## 测试场景

```bash
# Terminal 1 - Server
LD_PRELOAD=./libshmipc.so qperf

# Terminal 2 - Client (512KB message, 120 seconds)
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -msg_size 524288 -t 120 tcp_bw tcp_lat
```

---

## 目录

1. [环境准备](#1-环境准备)
2. [perf + FlameGraph 分析](#2-perf--flamegraph-分析)
3. [ftrace 分析](#3-ftrace-分析)
4. [查看结果](#4-查看结果)
5. [常见问题](#5-常见问题)

---

## 1. 环境准备

### 1.1 检查工具是否安装

```bash
# 检查 perf
perf version 2>/dev/null || echo "perf not installed"

# 检查是否能访问 ftrace
ls /sys/kernel/debug/tracing/ 2>/dev/null || echo "ftrace not accessible"

# 检查是否有 root 权限
id | grep -q "uid=0" && echo "root OK" || echo "Need root!"
```

### 1.2 安装必要工具（需要 root）

```bash
# Ubuntu/Debian
sudo apt-get install linux-tools-common linux-tools-generic perf sysstat

# CentOS/RHEL
sudo yum install perf sysstat
```

### 1.3 创建输出目录

```bash
mkdir -p ~/shmipc_perf_analysis
cd ~/shmipc_perf_analysis
```

---

## 2. perf + FlameGraph 分析

### 2.1 编译 shmipc（带调试符号）

```bash
cd /path/to/shmipc-preload
make clean && make opt
```

### 2.2 启动 qperf server（后台运行）

```bash
cd /path/to/shmipc-preload
LD_PRELOAD=./libshmipc.so qperf &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"
sleep 2
```

### 2.3 使用 perf record 记录

```bash
cd ~/shmipc_perf_analysis

# 记录 60 秒（覆盖 qperf 120 秒测试的前半段）
sudo perf record -F 99 -a -g -- sleep 60 &

PERF_PID=$!
echo "Perf PID: $PERF_PID"
```

### 2.4 运行 qperf client

```bash
cd /path/to/shmipc-preload
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -msg_size 524288 -t 120 tcp_bw tcp_lat
```

### 2.5 停止 perf record

```bash
# 60 秒后 perf 会自动停止，或者手动停止
sudo pkill -SIGINT perf
sleep 5
```

### 2.6 生成火焰图

```bash
cd ~/shmipc_perf_analysis

# 如果没有 flamegraph 工具，先下载
if [ ! -f FlameGraph/stackcollapse-perf.pl ]; then
    git clone https://github.com/brendangregg/FlameGraph.git
    cd FlameGraph
else
    cd FlameGraph
fi

# 生成火焰图
./stackcollapse-perf.pl ../perf.data > ../perf_unfolded.txt
./flamegraph.pl --colors=java ../perf_unfolded.txt > ../shmipc_flamegraph.svg

echo "FlameGraph saved to: ../shmipc_flamegraph.svg"
```

### 2.7 查看火焰图

```bash
# 方式1: 直接打开
firefox ~/shmipc_perf_analysis/shmipc_flamegraph.svg

# 方式2: 复制到 Windows 共享目录（如果你在 WSL）
cp ~/shmipc_perf_analysis/shmipc_flamegraph.svg /mnt/c/Users/$USER/Desktop/

# 方式3: 启动本地 HTTP 服务
cd ~/shmipc_perf_analysis
python3 -m http.server 8080
# 然后浏览器访问 http://localhost:8080/shmipc_flamegraph.svg
```

---

## 3. ftrace 分析

### 3.1 ftrace 脚本

创建 `single_perf_trace/ftrace_analyze.sh`：

```bash
#!/bin/bash
# ftrace_analyze.sh - shmipc ftrace 性能分析脚本
# 使用方式: sudo ./ftrace_analyze.sh [server_pid] [client_pid]

set -e

OUTPUT_DIR="/tmp/shmipc_ftrace_$(date +%Y%m%d_%H%M%S)"
MOUNT_POINT="/sys/kernel/debug/tracing"
DURATION=${1:-60}

echo "=== shmipc ftrace Performance Analysis ==="
echo "Output directory: $OUTPUT_DIR"
echo "Duration: ${DURATION}s"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

cleanup() {
    echo "Cleaning up..."
    echo 0 > "$MOUNT_POINT/tracing_on" 2>/dev/null || true
    echo > "$MOUNT_POINT/trace" 2>/dev/null || true
    echo 0 > "$MOUNT_POINT/events/enable" 2>/dev/null || true
}

trap cleanup EXIT

echo "[1/6] Setting up ftrace..."
if [ ! -d "$MOUNT_POINT" ]; then
    echo "Error: ftrace not available. Try: sudo mount -t debugfs debugfs /sys/kernel/debug"
    exit 1
fi

cd "$MOUNT_POINT"
echo 0 > tracing_on
echo > trace
echo nop > current_tracer

echo "[2/6] Enabling function graph tracer..."
echo function_graph > current_tracer
echo "funcs" > set_ftrace_filter
echo "*shmipc*" > set_ftrace_filter
echo "*qperf*" >> set_ftrace_filter

echo "[3/6] Enabling syscall tracing..."
echo 1 > events/syscalls/enable

echo "[4/6] Starting trace..."
echo 1 > tracing_on

echo "[5/6] Recording for ${DURATION}s... (run qperf client now)"
sleep "$DURATION"

echo "[6/6] Stopping trace..."
echo 0 > tracing_on

echo "Saving trace..."
cp trace "$OUTPUT_DIR/full_trace.txt"
cp trace_pipe "$OUTPUT_DIR/trace_pipe.txt" 2>/dev/null || true

echo ""
echo "=== Analysis ==="

echo ""
echo "--- Top Functions by Call Count ---"
cat "$OUTPUT_DIR/full_trace.txt" | grep "funcgraph_entry" | awk '{print $8}' | sort | uniq -c | sort -rn | head -20

echo ""
echo "--- Function Latency (top 20) ---"
cat "$OUTPUT_DIR/full_trace.txt" | grep "funcgraph_exit" | awk -F'dur=' '{print $2}' | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+$' | sort -rn | head -20

echo ""
echo "--- Syscall Summary ---"
cat "$OUTPUT_DIR/full_trace.txt" | grep -E "syscall_entry" | awk '{print $4}' | sort | uniq -c | sort -rn | head -10

echo ""
echo "=== Results saved to: $OUTPUT_DIR ==="
echo ""
echo "Files:"
ls -la "$OUTPUT_DIR"
```

### 3.2 运行 ftrace 分析

```bash
cd /path/to/shmipc-preload/single_perf_trace

# 给脚本添加执行权限
chmod +x ftrace_analyze.sh

# 运行 ftrace（需要 root）
sudo ./ftrace_analyze.sh 60
```

### 3.3 同时运行 qperf 和 ftrace

```bash
# Terminal 1: 启动 qperf server
cd /path/to/shmipc-preload
LD_PRELOAD=./libshmipc.so qperf &

# Terminal 2: 运行 ftrace
sudo ./ftrace_analyze.sh 60

# Terminal 3: 运行 qperf client
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -msg_size 524288 -t 120 tcp_bw tcp_lat
```

---

## 4. 查看结果

### 4.1 火焰图解读

火焰图颜色约定：
- **红色 (red)**: C/C++ 函数
- **黄色 (yellow)**: Go 函数
- **橙色 (orange)**: 内核函数
- **蓝色 (blue)**: 空闲/等待

如何阅读：
- **从下往上看**：调用栈的每一层
- **宽度**：该函数占用的 CPU 时间比例
- **顶层越宽**：该函数是热点

### 4.2 ftrace 输出解读

```
--- Top Functions by Call Count ---
# 分析哪些函数被调用最多

--- Function Latency (top 20) ---
# 分析哪些函数执行时间最长

--- Syscall Summary ---
# 分析系统调用分布
```

### 4.3 perf report 快速查看

```bash
cd ~/shmipc_perf_analysis

# 查看 record 报告
sudo perf report --stdio -g none -i perf.data | head -100

# 查看 annotated 代码
sudo perf annotate --stdio -i perf.data | head -50
```

---

## 5. 常见问题

### Q1: perf: command not found

```bash
# Ubuntu
sudo apt-get install linux-tools-$(uname -r) linux-tools-generic

# 或者检查是否在 PATH 中
which perf || echo $PATH
ls /usr/bin/perf
```

### Q2: ftrace: Permission denied

```bash
# 检查是否有 root 权限
id

# 如果在 WSL，需要加载内核模块
sudo modprobe ftrace

# 或者使用 debugfs
sudo mount -t debugfs debugfs /sys/kernel/debug
```

### Q3: FlameGraph 工具下载

```bash
cd ~
git clone https://github.com/brendangregg/FlameGraph.git
cd FlameGraph
ls *.pl
```

### Q4: perf record 失败 " Permission error"

```bash
# 检查内核是否允许 perf
cat /proc/sys/kernel/perf_event_paranoid
# 如果大于 1，需要设置为 1 或 0
sudo sysctl kernel.perf_event_paranoid=1
```

### Q5: 生成火焰图失败

```bash
# 检查是否有 stackcollapse-perf.pl
ls FlameGraph/stackcollapse-perf.pl

# 检查 perf.data 是否生成
ls -la perf.data

# 重新生成
cd FlameGraph
./stackcollapse-perf.pl ../perf.data > ../perf_unfolded.txt 2>&1
./flamegraph.pl ../perf_unfolded.txt > ../shmipc_flamegraph.svg 2>&1
```

---

## 完整执行流程

```bash
# ===== Step 1: 环境准备 =====
mkdir -p ~/shmipc_perf_analysis
cd ~/shmipc_perf_analysis

# ===== Step 2: 下载 FlameGraph =====
git clone https://github.com/brendangregg/FlameGraph.git

# ===== Step 3: 编译 shmipc =====
cd /path/to/shmipc-preload
make clean && make opt

# ===== Step 4: 启动 qperf server（后台）=====
LD_PRELOAD=./libshmipc.so qperf &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# ===== Step 5: 运行 perf record（60秒）=====
cd ~/shmipc_perf_analysis
sudo perf record -F 99 -a -g -- sleep 60 &
PERF_PID=$!

# ===== Step 6: 运行 qperf client（120秒）=====
cd /path/to/shmipc-preload
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -msg_size 524288 -t 120 tcp_bw tcp_lat

# ===== Step 7: 等待 perf 完成 =====
wait $PERF_PID
sleep 5

# ===== Step 8: 生成火焰图 =====
cd ~/shmipc_perf_analysis
./FlameGraph/stackcollapse-perf.pl perf.data > perf_unfolded.txt
./FlameGraph/flamegraph.pl --colors=java perf_unfolded.txt > shmipc_flamegraph.svg

# ===== Step 9: 查看结果 =====
echo "FlameGraph: ~/shmipc_perf_analysis/shmipc_flamegraph.svg"
firefox ~/shmipc_perf_analysis/shmipc_flamegraph.svg

# ===== Step 10: 查看 perf report =====
sudo perf report --stdio -g none -i perf.data | head -100
```

---

## 预期结果

### 火焰图中应该能看到

1. **CGO 函数调用开销**：C → Go 边界的转换
2. **ShmipcWrite/ShmipcRead**：你的 preload 函数
3. **memcpy**：内存拷贝操作
4. **Go runtime**：Go 调度和 GC 相关

### ftrace 中应该能看到

1. **write/recv**：socket 系统调用
2. **ShmipcWrite/ShmipcRead**：你的 CGO 函数
3. **epoll_wait/epoll_ctl**：事件通知

---

## 脚本文件清单

```
single_perf_trace/
├── ftrace_analyze.sh      # ftrace 分析脚本
└── README.md              # 本文档
```

如需运行分析：

```bash
cd /path/to/shmipc-preload/single_perf_trace
chmod +x ftrace_analyze.sh
sudo ./ftrace_analyze.sh 60
```
