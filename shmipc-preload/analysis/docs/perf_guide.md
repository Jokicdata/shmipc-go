# perf 性能分析工具使用指南

## 一、perf 简介

perf 是 Linux 内核提供的性能分析工具，可以分析 CPU、缓存、内存等各种硬件和软件事件。

## 二、常用命令

### 2.1 基本统计

```bash
# 查看进程的 CPU 使用情况
perf stat -p <pid>

# 查看进程的详细统计
perf stat -e cycles,instructions,cache-references,cache-misses -p <pid>

# 运行命令并统计
perf stat <command>
```

### 2.2 热点分析

```bash
# 记录 CPU 采样数据
perf record -g -p <pid> -- sleep 10

# 查看报告
perf report

# 查看调用链
perf report -g

# 输出到文件
perf report --stdio > report.txt
```

### 2.3 实时监控

```bash
# 实时显示热点函数
perf top -p <pid>

# 实时显示调用链
perf top -g -p <pid>
```

### 2.4 特定事件分析

```bash
# 分析缓存未命中
perf stat -e cache-misses,cache-references -p <pid>

# 分析分支预测失败
perf stat -e branch-misses,branches -p <pid>

# 分析上下文切换
perf stat -e context-switches,cpu-migrations -p <pid>
```

## 三、shmipc-preload 分析场景

### 3.1 分析 CPU 热点

```bash
# 启动测试程序
LD_PRELOAD=./libshmipc.so qperf &
QPERF_PID=$!

# 记录性能数据
sudo perf record -g -p $QPERF_PID -- sleep 10

# 分析热点
sudo perf report

# 查看具体函数的开销
sudo perf report --stdio | grep -A 5 "ShmipcWrite\|ShmipcRead\|memcpy"
```

### 3.2 分析内存访问

```bash
# 分析缓存行为
sudo perf stat -e cycles,instructions,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses -p <pid>

# 输出示例：
#   1,234,567,890  cycles
#     987,654,321  instructions              # 0.80 IPC
#      12,345,678  cache-references
#       1,234,567  cache-misses              # 10.0% of all cache refs
```

### 3.3 分析 CGO 调用开销

```bash
# 追踪 CGO 相关函数
sudo perf record -e 'syscalls:sys_enter_*' -p <pid> -- sleep 10

# 分析系统调用
sudo perf report --stdio | grep "sys_enter"
```

### 3.4 生成火焰图

```bash
# 记录数据
sudo perf record -g -p <pid> -- sleep 10

# 生成火焰图
sudo perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg

# 或者使用 perf report 的 TUI 界面
sudo perf report -g
```

## 四、perf 事件列表

### 4.1 硬件事件

| 事件 | 说明 |
|------|------|
| `cycles` | CPU 周期数 |
| `instructions` | 指令数 |
| `cache-references` | 缓存访问次数 |
| `cache-misses` | 缓存未命中次数 |
| `branch-instructions` | 分支指令数 |
| `branch-misses` | 分支预测失败次数 |
| `bus-cycles` | 总线周期数 |

### 4.2 软件事件

| 事件 | 说明 |
|------|------|
| `cpu-clock` | CPU 时钟 |
| `task-clock` | 任务时钟 |
| `context-switches` | 上下文切换次数 |
| `cpu-migrations` | CPU 迁移次数 |
| `page-faults` | 页错误次数 |
| `minor-faults` | 次要页错误 |
| `major-faults` | 主要页错误 |

### 4.3 缓存事件

| 事件 | 说明 |
|------|------|
| `L1-dcache-loads` | L1 数据缓存加载 |
| `L1-dcache-load-misses` | L1 数据缓存加载未命中 |
| `LLC-loads` | 最后一级缓存加载 |
| `LLC-load-misses` | 最后一级缓存加载未命中 |

## 五、分析脚本示例

### 5.1 自动分析脚本

```bash
#!/bin/bash
# perf_auto_analyze.sh

PID=$1
DURATION=${2:-10}
OUTPUT_DIR="perf_results_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUTPUT_DIR"

echo "开始分析进程 $PID，持续时间 $DURATION 秒..."

# 1. 基本统计
echo "[1/5] 收集基本统计..."
perf stat -p $PID -o "$OUTPUT_DIR/basic_stats.txt" -- sleep $DURATION

# 2. CPU 热点
echo "[2/5] 收集 CPU 热点..."
perf record -g -p $PID -o "$OUTPUT_DIR/perf.data" -- sleep $DURATION
perf report --stdio -i "$OUTPUT_DIR/perf.data" > "$OUTPUT_DIR/hotspots.txt"

# 3. 缓存分析
echo "[3/5] 收集缓存统计..."
perf stat -e cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses \
    -p $PID -o "$OUTPUT_DIR/cache_stats.txt" -- sleep $DURATION

# 4. 内存分析
echo "[4/5] 收集内存统计..."
perf stat -e cycles,instructions,stalled-cycles-frontend,stalled-cycles-backend \
    -p $PID -o "$OUTPUT_DIR/memory_stats.txt" -- sleep $DURATION

# 5. 系统调用分析
echo "[5/5] 收集系统调用统计..."
perf record -e 'syscalls:sys_enter_*' -p $PID -o "$OUTPUT_DIR/syscalls.data" -- sleep $DURATION
perf report --stdio -i "$OUTPUT_DIR/syscalls.data" > "$OUTPUT_DIR/syscalls.txt"

echo "分析完成，结果保存在 $OUTPUT_DIR/"
```

### 5.2 对比分析脚本

```bash
#!/bin/bash
# perf_compare.sh

MSG_SIZE=$1
DURATION=${2:-10}

echo "对比分析: 消息大小 $MSG_SIZE bytes"

# 测试原始 socket
echo "[1/2] 测试原始 socket..."
qperf &
SERVER_PID=$!
sleep 2

perf record -g -p $SERVER_PID -o "perf_socket_${MSG_SIZE}.data" -- sleep $DURATION &
PERF_PID=$!

qperf 127.0.0.1 -m $MSG_SIZE -t $DURATION tcp_lat > "result_socket_${MSG_SIZE}.txt"

wait $PERF_PID
kill $SERVER_PID

# 测试 shmipc
echo "[2/2] 测试 shmipc..."
LD_PRELOAD=./libshmipc.so qperf &
SERVER_PID=$!
sleep 2

perf record -g -p $SERVER_PID -o "perf_shmipc_${MSG_SIZE}.data" -- sleep $DURATION &
PERF_PID=$!

LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m $MSG_SIZE -t $DURATION tcp_lat > "result_shmipc_${MSG_SIZE}.txt"

wait $PERF_PID
kill $SERVER_PID

# 生成对比报告
echo "生成对比报告..."
perf report --stdio -i "perf_socket_${MSG_SIZE}.data" > "report_socket_${MSG_SIZE}.txt"
perf report --stdio -i "perf_shmipc_${MSG_SIZE}.data" > "report_shmipc_${MSG_SIZE}.txt"

echo "对比完成！"
echo "结果文件："
echo "  - result_socket_${MSG_SIZE}.txt"
echo "  - result_shmipc_${MSG_SIZE}.txt"
echo "  - report_socket_${MSG_SIZE}.txt"
echo "  - report_shmipc_${MSG_SIZE}.txt"
```

## 六、常见问题

### 6.1 权限问题

```bash
# 错误：Permission denied
# 解决：使用 sudo 或设置 perf_event_paranoid

sudo sysctl -w kernel.perf_event_paranoid=1

# 或永久设置
echo "kernel.perf_event_paranoid=1" | sudo tee -a /etc/sysctl.conf
```

### 6.2 符号信息缺失

```bash
# 错误：no symbols
# 解决：安装调试符号

# Ubuntu
sudo apt-get install libc6-dbg
sudo apt-get install linux-image-$(uname -r)-dbgsym

# CentOS
sudo debuginfo-install glibc
```

### 6.3 采样频率过低

```bash
# 默认采样频率可能过低，可以增加
perf record -F 99 -g -p <pid> -- sleep 10

# -F 99 表示每秒采样 99 次
```

## 七、参考资源

- [perf 官方文档](https://perf.wiki.kernel.org/index.php/Tutorial)
- [perf Examples](http://www.brendangregg.com/perf.html)
- [火焰图生成工具](https://github.com/brendangregg/FlameGraph)
