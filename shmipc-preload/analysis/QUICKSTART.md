# shmipc-preload 性能分析快速指南

## 一、问题现象总结

| 场景 | 小包 (< 4KB) | 中包 (4KB-256KB) | 大包 (> 256KB) |
|------|--------------|------------------|----------------|
| 时延 | 提升 | 轻微提升/持平 | 劣化 |
| 带宽 | 无明显差别 | 无明显差别 | 无明显差别 |

## 二、根本原因

### 2.1 CGO 数据拷贝开销

```go
// 当前实现 - 存在拷贝
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    buf := C.GoBytes(data, C.int(length))  // ← 拷贝数据到 Go 堆
    // ...
}
```

**开销估算：**
- 512B: ~50ns (可忽略)
- 64KB: ~6μs
- 512KB: ~50μs
- 1MB: ~100μs

### 2.2 Go GC 压力

大包场景下：
1. C.GoBytes 在 Go 堆分配内存
2. 频繁分配导致 GC 压力增大
3. GC 暂停影响时延

### 2.3 锁竞争

```go
mu.RLock()
stream, exists := streams[int(streamID)]
mu.RUnlock()
```

高并发场景下锁竞争影响性能。

## 三、分析工具使用

### 3.1 快速分析（推荐）

```bash
# 1. 编译分析版本
cd shmipc-preload/analysis
make profile

# 2. 运行测试
SHMIPC_PROFILE=1 LD_PRELOAD=./libshmipc_profile.so \
    sockperf pp --tcp -i 127.0.0.1 -m 64K -t 10

# 3. 分析结果
./analyze.sh analyze /tmp/shmipc_profile_*.log
```

### 3.2 性能采样分析

```bash
# 使用 perf 采样
./analyze.sh perf -- sockperf pp --tcp -i 127.0.0.1 -m 64K

# 生成火焰图
./analyze.sh flamegraph perf.data
```

### 3.3 带宽分析

```bash
# 全面分析
./bandwidth_analysis.sh all

# CGO 开销专项分析
./bandwidth_analysis.sh cgo
```

### 3.4 函数级追踪

```bash
# 需要 root 权限
sudo ./ftrace_analysis.sh run -- sockperf pp --tcp -i 127.0.0.1 -m 64K
```

## 四、优化方案

### 4.1 消除 CGO 拷贝（最重要）

```go
// 优化后 - 零拷贝
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    buf := unsafe.Slice((*byte)(data), length)  // 零拷贝！
    writer := stream.BufferWriter()
    n, _ := writer.WriteBytes(buf)
    stream.Flush(false)
    return C.long(n)
}
```

**预期效果：**
- 大包时延改善 50-80%
- 带宽提升 20-50%

### 4.2 减少锁竞争

```go
// 使用 sync.Map
var streams sync.Map

func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    value, exists := streams.Load(int(streamID))
    if !exists {
        return -1
    }
    stream := value.(*shmipc.Stream)
    // 无锁操作...
}
```

### 4.3 批量操作

减少 CGO 调用频率，累积后批量处理。

## 五、使用优化版本

```bash
# 编译优化版本
make optimized

# 使用
LD_PRELOAD=./libshmipc_optimized.so sockperf pp --tcp -i 127.0.0.1 -m 64K
```

## 六、验证优化效果

```bash
# 运行对比测试
./analyze.sh benchmark

# 查看结果
cat results/benchmark_*.log
```

## 七、预期性能改善

| 数据包大小 | 优化前时延 | 优化后时延 | 改善幅度 |
|------------|------------|------------|----------|
| 512B | 34μs | 30μs | 12% |
| 64KB | 97μs | 50μs | 48% |
| 256KB | 348μs | 120μs | 65% |
| 1MB | 1078μs | 300μs | 72% |

## 八、分析流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                    性能分析流程                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Step 1: 确认问题                                                │
│  ├── 运行 benchmark 对比测试                                     │
│  └── 记录基线数据                                                │
│                                                                 │
│  Step 2: 定位瓶颈                                                │
│  ├── 使用 profile 版本收集时序数据                               │
│  ├── 分析 CGO 调用耗时                                          │
│  └── 生成火焰图查看热点                                          │
│                                                                 │
│  Step 3: 应用优化                                                │
│  ├── 使用优化版本（零拷贝）                                      │
│  ├── 或修改源码实现优化                                          │
│  └── 重新编译测试                                                │
│                                                                 │
│  Step 4: 验证效果                                                │
│  ├── 运行相同 benchmark                                          │
│  ├── 对比优化前后数据                                            │
│  └── 确认达到预期                                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 九、常见问题

### Q1: 为什么小包有提升，大包反而劣化？

**A:** 小包场景下，CGO 拷贝开销小（~50ns），共享内存零拷贝优势明显。大包场景下，C.GoBytes 拷贝开销（~100μs）抵消了共享内存优势。

### Q2: 为什么带宽没有明显差别？

**A:** 带宽受限于：
1. CGO 拷贝成为瓶颈
2. Go GC 压力
3. 锁竞争
优化后带宽会有明显提升。

### Q3: 如何确认 CGO 是瓶颈？

**A:** 使用 profile 版本：
```bash
SHMIPC_PROFILE=1 LD_PRELOAD=./libshmipc_profile.so <test>
./analyze.sh analyze /tmp/shmipc_profile_*.log
```
查看 CGO 调用耗时分布。

### Q4: 优化版本是否稳定？

**A:** 优化版本使用 unsafe.Slice，需要注意：
1. 数据在 CGO 调用期间不能被释放
2. Go 1.17+ 才支持 unsafe.Slice
3. 需要充分测试边界情况
