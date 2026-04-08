# shmipc-preload 优化实现说明

## 概述

本目录包含 shmipc-preload 的优化版本实现，主要解决大包传输时延劣化的问题。

## 性能问题根因

### 1. CGO 数据拷贝开销（核心问题）

原始实现中存在额外的数据拷贝：

**写入路径（原始）：**
```
C 内存 → C.GoBytes() → Go 临时切片 → 共享内存
         拷贝 #1        拷贝 #2
```

**写入路径（优化后）：**
```
C 内存 → Reserve() 直接预留共享内存 → 共享内存
         一次拷贝
```

### 2. 同步阻塞模式

每次写入都立即 `Flush()`，无法利用批量 IO 优势。

### 3. 共享内存缓冲区限制

默认 32MB 缓冲区可能触发 fallback 模式。

## 优化方案

### 方案 1：消除 CGO 数据拷贝

使用 `Reserve()` API 直接在共享内存上预留空间：

```go
// 优化前
buf := C.GoBytes(data, C.int(length))  // 拷贝
writer.WriteBytes(buf)                  // 再次拷贝

// 优化后
buf, _ := writer.Reserve(int(length))   // 零拷贝预留
copy(buf, (*[1 << 30]byte)(data)[:length])  // 一次拷贝
```

### 方案 2：批量 IO 优化

新增批量读写接口：

```c
// 批量写入多个 iovec
long ShmipcWriteBatch(int stream_id, const struct iovec *iov, int iovcnt);

// 批量读取多个 iovec
long ShmipcReadBatch(int stream_id, const struct iovec *iov, int iovcnt);
```

### 方案 3：增大共享内存缓冲区

默认缓冲区从 32MB 增大到 256MB，减少 fallback 触发。

## 文件说明

### 核心实现

| 文件 | 说明 |
|------|------|
| `shmipc_bridge_optimized.go` | 优化后的 Go CGO 桥接层 |
| `shmipc_preload_optimized.c` | 优化后的 C 预加载库 |
| `Makefile.optimized` | 编译优化版本的 Makefile |

### 性能分析工具

位于 `perf_tools/` 目录：

| 文件 | 说明 |
|------|------|
| `trace_shmipc.sh` | ftrace 追踪 |
| `perf_shmipc.sh` | perf 性能分析 |
| `comprehensive_bench.sh` | 综合基准测试 |
| `latency_comparison.sh` | 延迟对比测试 |
| `analyze_copy_overhead.sh` | 拷贝开销分析 |

## 编译和使用

### 编译

```bash
# 编译原始版本
make original

# 编译优化版本
make optimized

# 编译所有版本
make all
```

### 使用

```bash
# 使用原始版本
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw

# 使用优化版本
LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 tcp_bw

# 配置参数
export SHMIPC_BUFFER_SIZE=$((512 * 1024 * 1024))  # 512MB
export SHMIPC_BATCH_IO=1                          # 启用批量 IO
export SHMIPC_LOG=3                               # INFO 日志级别
```

## 性能对比

### 预期提升

| 场景 | 原始实现 | 优化实现 | 提升 |
|------|----------|----------|------|
| 小包延迟 (512B) | 10-20% 提升 | 15-25% 提升 | +5% |
| 中包延迟 (64KB) | 持平 | 15-25% 提升 | +20% |
| 大包延迟 (512KB) | -10% 劣化 | 20-30% 提升 | +40% |
| 带宽 | 持平 | 10-20% 提升 | +15% |

### 实测方法

```bash
# 运行综合基准测试
cd perf_tools
./comprehensive_bench.sh

# 分析结果
grep -E "(tcp_bw|tcp_lat)" benchmark_results/comprehensive_bench_*.log
```

## 性能分析流程

### 1. 确认问题

```bash
# 运行延迟对比测试
./latency_comparison.sh

# 查看结果
cat latency_results/latency_*.csv
```

### 2. 分析热点

```bash
# 使用 perf 分析
./perf_shmipc.sh

# 查看热点函数
cat perf_results/perf_report_large.txt | head -50
```

### 3. 检查拷贝开销

```bash
# 分析拷贝次数
./analyze_copy_overhead.sh
```

### 4. 检查 fallback

```bash
# 检测 fallback 模式
./test_fallback.sh
```

### 5. 监控内存

```bash
# 监控内存使用
LD_PRELOAD=./libshmipc.so <program> &
./monitor_memory.sh $!
```

## 调优建议

### 1. 缓冲区大小

根据最大消息大小调整：

```bash
# 最大消息 100MB，建议设置 400MB
export SHMIPC_BUFFER_SIZE=$((400 * 1024 * 1024))
```

### 2. 批量 IO

对于大量小消息场景：

```bash
export SHMIPC_BATCH_IO=1
```

### 3. 队列容量

高并发场景增大队列：

```bash
export SHMIPC_QUEUE_CAP=16384
```

### 4. 日志级别

调试时开启详细日志：

```bash
export SHMIPC_LOG=4  # DEBUG
```

## 常见问题

### Q1: 大包性能仍然劣化？

检查：
1. 是否使用了优化版本 (`libshmipc_optimized.so`)
2. 缓冲区是否足够大
3. 是否触发了 fallback

```bash
export SHMIPC_LOG=3
LD_PRELOAD=./libshmipc_optimized.so <program> 2>&1 | grep -i fallback
```

### Q2: 如何确认优化生效？

查看退出时的统计信息：

```
=== shmipc-bridge Performance Stats ===
Total Writes:      1000
Total Reads:       1000
Total Write Bytes: 65536000 (62.50 MB)
Total Read Bytes:  65536000 (62.50 MB)
CGO Copy Bytes:    0 (0.00 MB)          <-- 应该接近 0
Reserve Hits:      1000 (100.00%)       <-- 应该接近 100%
Reserve Misses:    0
======================================
```

### Q3: 如何对比两个版本？

```bash
# 测试原始版本
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 -m 524288 -t 10

# 测试优化版本
LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 -m 524288 -t 10
```

## 架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      Application (C/C++)                    │
└────────────────────┬────────────────────────────────────────┘
                     │ socket API
                     ▼
┌─────────────────────────────────────────────────────────────┐
│              libshmipc.so (LD_PRELOAD)                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  socket/bind/listen/accept/connect/send/recv 劫持    │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────────┘
                     │ CGO
                     ▼
┌─────────────────────────────────────────────────────────────┐
│              libshmipc_go.so (Go Shared Library)            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  ShmipcWrite/Read (优化: Reserve + Peek)             │  │
│  │  ShmipcWriteBatch/ReadBatch (批量 IO)                │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                  shmipc-go Core Library                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  共享内存管理 | 无锁队列 | Buffer Manager             │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                    Shared Memory (256MB)                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Data Buffers | Queue Metadata | Control Structures  │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## 下一步优化方向

1. **C 侧直接映射共享内存**：完全绕过 Go 层，消除所有 CGO 开销
2. **零拷贝 API**：提供类似 `splice()` 的零拷贝接口
3. **RDMA 支持**：对于跨节点通信，使用 RDMA 进一步降低延迟
4. **自适应批量**：根据负载自动调整批量大小

## 参考资料

- [shmipc-go 设计文档](../README.md)
- [CGO 性能优化](https://github.com/golang/go/wiki/cgo)
- [共享内存 IPC 最佳实践](https://kernel.org/doc/html/latest/admin-guide/mm/shmem.html)
