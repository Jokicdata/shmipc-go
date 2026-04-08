# shmipc-preload 性能分析快速入门

## 一、快速开始

### 1.1 运行对比测试

```bash
cd shmipc-preload/analysis

# 运行完整对比测试
./perf_analysis.sh comparison
```

测试结果将保存在 `logs/` 目录下。

### 1.2 查看结果

```bash
# 查看对比结果
cat logs/comparison_*.csv

# 示例输出：
# msg_size,socket_latency_us,shmipc_latency_us,latency_improvement,...
# 1024,3.2,1.3,59.4,...
# 65536,50.2,80.1,-59.4,...
```

## 二、问题确认

### 2.1 预期结果

| 消息大小 | Socket 延迟 | shmipc 延迟 | 变化 |
|----------|-------------|-------------|------|
| 1KB | ~3μs | ~1.3μs | ✅ 提升 60% |
| 64KB | ~50μs | ~80μs | ❌ 劣化 60% |
| 1MB | ~300μs | ~400μs | ❌ 劣化 33% |

### 2.2 问题原因

**核心问题：CGO 内存拷贝**

在 `shmipc_bridge.go` 中存在两次额外的内存拷贝：

```go
// 写入时：C.GoBytes() 拷贝
buf := C.GoBytes(data, C.int(length))  // ❌ 拷贝！

// 读取时：copy() 拷贝
copy((*[1 << 30]byte)(data)[:len(buf)], buf)  // ❌ 拷贝！
```

## 三、深入分析

### 3.1 CPU 热点分析

```bash
# 启动测试程序
LD_PRELOAD=../libshmipc.so qperf &
QPERF_PID=$!

# 分析 CPU 热点
sudo perf record -g -p $QPERF_PID -- sleep 10
sudo perf report

# 预期看到：
# - runtime.memmove 占比高（内存拷贝）
# - main.ShmipcWrite 占比高（CGO 调用）
```

### 3.2 函数耗时追踪

```bash
# 使用 eBPF 追踪函数耗时
sudo bpftrace shmipc_trace.bt

# 预期输出：
# [ShmipcWrite 耗时分布]
# [512, 1K)  123 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
# [1K, 2K)    45 |@@@@@@@@@@@@@@@@@@                                  |
```

### 3.3 内存拷贝分析

```bash
# 追踪 memcpy 调用
sudo bpftrace -e '
uprobe:libc.so.6:memcpy {
    @start[tid] = nsecs;
    @size[tid] = arg2;
}
uretprobe:libc.so.6:memcpy /@start[tid]/ {
    $ns = nsecs - @start[tid];
    printf("memcpy size=%d, time=%d ns\n", @size[tid], $ns);
    delete(@start[tid]);
    delete(@size[tid]);
}
'

# 预期输出：
# memcpy size=65536, time=25000 ns
# memcpy size=1048576, time=400000 ns
```

## 四、优化方案

### 4.1 短期优化（推荐）

**修改 `shmipc_bridge.go`**：

```go
// 优化前
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    buf := C.GoBytes(data, C.int(length))  // ❌ 拷贝
    writer := stream.BufferWriter()
    n, _ := writer.WriteBytes(buf)
    ...
}

// 优化后
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    buf := unsafe.Slice((*byte)(data), length)  // ✅ 无拷贝
    writer := stream.BufferWriter()
    n, _ := writer.WriteBytes(buf)
    ...
}
```

### 4.2 预期效果

| 场景 | 当前延迟 | 优化后延迟 | 提升 |
|------|----------|------------|------|
| 1KB | 1.3μs | 0.8μs | 38% |
| 64KB | 80μs | 40μs | 50% |
| 1MB | 400μs | 150μs | 62% |

## 五、常用命令速查

```bash
# 1. 对比测试
./perf_analysis.sh comparison

# 2. 延迟测试
./perf_analysis.sh latency 65536

# 3. 带宽测试
./perf_analysis.sh bandwidth 1048576

# 4. CPU 热点分析
sudo perf record -g -p <pid> -- sleep 10
sudo perf report

# 5. 函数耗时追踪
sudo bpftrace shmipc_trace.bt

# 6. 内核函数追踪
sudo ./ftrace_analysis.sh socket "qperf 127.0.0.1 tcp_lat"
```

## 六、参考文档

- [性能分析方案](./README.md) - 完整分析方案
- [问题总结](./SUMMARY.md) - 问题原因和优化建议
- [perf 指南](./docs/perf_guide.md) - perf 详细使用方法
- [eBPF 指南](./docs/ebpf_guide.md) - eBPF 详细使用方法
- [日志打点](./docs/logging_guide.md) - 精确性能分析方案
