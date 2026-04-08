# shmipc-preload 性能分析工具

本目录包含用于分析和优化 shmipc-preload 性能的各种工具和脚本。

## 文件说明

### 性能追踪工具

| 文件 | 说明 | 使用方式 |
|------|------|----------|
| `trace_shmipc.sh` | 使用 ftrace 追踪系统调用和函数调用 | `sudo ./trace_shmipc.sh` |
| `perf_shmipc.sh` | 使用 perf 分析 CPU、缓存和内存性能 | `./perf_shmipc.sh` |

### 基准测试工具

| 文件 | 说明 | 使用方式 |
|------|------|----------|
| `comprehensive_bench.sh` | 综合性能对比测试（Socket vs shmipc） | `./comprehensive_bench.sh` |
| `latency_comparison.sh` | 延迟对比测试 | `./latency_comparison.sh` |
| `measure_memcpy.sh` | 内存拷贝性能测试 | `./measure_memcpy.sh` |

### 测试工具

| 文件 | 说明 | 使用方式 |
|------|------|----------|
| `quick_test.sh` | 快速功能测试 | `./quick_test.sh` |
| `test_fallback.sh` | Fallback 模式检测 | `./test_fallback.sh` |
| `stress_test.sh` | 压力测试 | `./stress_test.sh [duration] [clients] [msg_size]` |

### 监控工具

| 文件 | 说明 | 使用方式 |
|------|------|----------|
| `monitor_memory.sh` | 内存使用监控 | `./monitor_memory.sh <pid>` |

### 可视化工具

| 文件 | 说明 | 使用方式 |
|------|------|----------|
| `plot_latency.py` | 延迟结果可视化 | `python3 plot_latency.py <csv_file>` |

## 快速开始

### 1. 编译优化版本

```bash
cd ..
make -f Makefile.optimized all
```

### 2. 运行快速测试

```bash
./quick_test.sh
```

### 3. 运行性能分析

```bash
# 使用 perf 分析
./perf_shmipc.sh

# 使用 ftrace 追踪
sudo ./trace_shmipc.sh
```

### 4. 运行综合基准测试

```bash
./comprehensive_bench.sh
```

### 5. 可视化结果

```bash
./latency_comparison.sh
python3 plot_latency.py latency_results/latency_*.csv
```

## 性能优化建议

### 1. 调整共享内存大小

```bash
export SHMIPC_BUFFER_SIZE=$((256 * 1024 * 1024))  # 256MB
```

### 2. 启用批量 IO

```bash
export SHMIPC_BATCH_IO=1
```

### 3. 调整日志级别

```bash
export SHMIPC_LOG=3  # INFO level
export SHMIPC_LOG=4  # DEBUG level
```

### 4. 禁用 shmipc（用于对比测试）

```bash
export SHMIPC_ENABLE=0
```

## 性能问题排查

### 1. 检查是否触发 Fallback

```bash
export SHMIPC_LOG=3
LD_PRELOAD=../libshmipc.so <your-program> 2>&1 | grep -i fallback
```

如果看到 fallback 警告，增大缓冲区：

```bash
export SHMIPC_BUFFER_SIZE=$((512 * 1024 * 1024))  # 512MB
```

### 2. 分析热点函数

```bash
./perf_shmipc.sh
cat perf_results/perf_report_large.txt | head -50
```

### 3. 检查 CGO 开销

```bash
./measure_memcpy.sh
```

### 4. 监控内存使用

```bash
LD_PRELOAD=../libshmipc.so <your-program> &
./monitor_memory.sh $!
```

## 预期性能提升

| 场景 | 原始实现 | 优化实现 | 提升 |
|------|----------|----------|------|
| 小包延迟 | 10-20% 提升 | 15-25% 提升 | +5% |
| 大包延迟 | -10% 劣化 | 10-20% 提升 | +30% |
| 带宽 | 持平 | 5-15% 提升 | +10% |

## 常见问题

### Q: 为什么大包性能劣化？

A: 原始实现中存在额外的 CGO 数据拷贝。优化版本使用 `Reserve()` API 消除了这次拷贝。

### Q: 如何确认优化生效？

A: 查看性能统计：

```bash
export SHMIPC_LOG=3
LD_PRELOAD=../libshmipc_optimized.so <your-program>
```

程序退出时会打印统计信息，包括 `Reserve Hits` 和 `CGO Copy Bytes`。

### Q: 如何选择合适的缓冲区大小？

A: 建议设置为最大消息大小的 2-4 倍。例如，如果最大传输 100MB 数据，设置：

```bash
export SHMIPC_BUFFER_SIZE=$((400 * 1024 * 1024))  # 400MB
```

## 依赖工具

- `perf`: Linux 性能分析工具
- `ftrace`: 内核追踪工具（需要 root）
- `qperf`: 网络性能测试工具
- `sockperf`: Socket 性能测试工具
- `python3` + `matplotlib`: 结果可视化

安装依赖：

```bash
# Ubuntu/Debian
sudo apt install linux-tools-common linux-tools-generic linux-tools-$(uname -r)
sudo apt install qperf sockperf python3-matplotlib

# CentOS/RHEL
sudo yum install perf qperf sockperf python3-matplotlib
```
