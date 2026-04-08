# shmipc-preload 性能优化方案详细文档

## 一、问题背景与现象

### 1.1 测试结果

在使用 shmipc-preload 进行性能测试时，发现以下现象：

| 场景 | 测试结果 | 说明 |
|------|----------|------|
| **小包传输** | 时延有提升 ✅ | 512B 消息延迟降低 10-20% |
| **大包传输** | 时延有劣化 ❌ | 512KB 消息延迟增加约 10% |
| **带宽** | 几乎无差别 | 与原始 Socket 持平 |

### 1.2 问题根因分析

通过代码分析和性能测试，发现以下三个主要问题：

---

## 二、核心问题分析

### 2.1 问题一：CGO 数据拷贝开销（核心问题）

#### 原始实现的数据流

**写入路径（原始实现）：**

```
┌─────────────┐   C.GoBytes()   ┌─────────────┐  WriteBytes()  ┌─────────────┐
│  C 内存     │ ──────────────► │  Go 内存    │ ──────────────► │  共享内存   │
│  (用户数据) │    拷贝 #1       │  (临时切片) │    拷贝 #2      │  (IPC传输)  │
└─────────────┘                  └─────────────┘                 └─────────────┘
```

**读取路径（原始实现）：**

```
┌─────────────┐   ReadBytes()   ┌─────────────┐     copy()      ┌─────────────┐
│  共享内存   │ ──────────────► │  Go 内存    │ ──────────────► │  C 内存     │
│  (IPC数据)  │    零拷贝        │  (切片引用) │    拷贝 #1      │  (用户缓冲) │
└─────────────┘                  └─────────────┘                 └─────────────┘
```

#### 原始代码分析

**shmipc_bridge.go 第 187-211 行（原始写入）：**

```go
//export ShmipcWrite
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    // ...
    
    // 问题：C.GoBytes() 会进行一次内存拷贝
    buf := C.GoBytes(data, C.int(length))  // 拷贝 #1: C 内存 → Go 内存
    
    writer := stream.BufferWriter()
    n, err := writer.WriteBytes(buf)  // 拷贝 #2: Go 内存 → 共享内存
    if err != nil {
        return C.long(-2)
    }
    
    err = stream.Flush(false)
    // ...
}
```

**shmipc_bridge.go 第 213-233 行（原始读取）：**

```go
//export ShmipcRead
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    // ...
    
    reader := stream.BufferReader()
    buf, err := reader.ReadBytes(int(length))  // 零拷贝：返回共享内存切片
    if err != nil {
        return C.long(-2)
    }
    
    // 问题：需要从共享内存拷贝到 C 内存
    copy((*[1 << 30]byte)(data)[:len(buf)], buf)  // 拷贝 #1: 共享内存 → C 内存
    stream.ReleaseReadAndReuse()
    
    return C.long(len(buf))
}
```

#### 对比分析

| 场景 | 传统 Socket | shmipc + preload (原始) | 差异 |
|------|-------------|------------------------|------|
| 小包写入 | 用户→内核→Socket缓冲区 (2次拷贝) | 用户→Go→共享内存 (2次拷贝) | 相当 |
| 小包读取 | Socket缓冲区→内核→用户 (2次拷贝) | 共享内存→Go→用户 (1次拷贝) | **shmipc优** |
| 大包写入 | 同上 + 系统调用开销 | 同上 + CGO调用开销 | **Socket优** |
| 大包读取 | 同上 + 系统调用开销 | 同上 + CGO调用开销 | **Socket优** |

#### 结论

- **小包场景**：shmipc 避免了系统调用（~1μs），CGO 开销（~50-100ns）可忽略，所以**时延有提升**
- **大包场景**：数据拷贝时间（~ms级）远大于系统调用时间，额外的 CGO 拷贝反而成为瓶颈，所以**时延有劣化**

---

### 2.2 问题二：同步阻塞模式

当前实现每次写入都立即 `Flush()`，无法利用 shmipc 的批量 IO 优势：

```go
func ShmipcWrite(...) C.long {
    writer := stream.BufferWriter()
    n, err := writer.WriteBytes(buf)  // 写入
    err = stream.Flush(false)          // 立即刷新！无法批量
    return C.long(n)
}
```

**影响**：每次写入都触发一次通知，无法合并多个小包一起发送。

---

### 2.3 问题三：共享内存缓冲区限制

默认配置只有 32MB，大文件传输可能触发 fallback 模式：

```go
// shmipc_bridge.go 第 39 行
config.ShareMemoryBufferCap = 32 * 1024 * 1024  // 32MB
```

**Fallback 模式**：当共享内存不足时，退化为通过 Socket 发送数据，性能反而更差。

---

## 三、优化方案

### 3.1 方案一：消除 CGO 数据拷贝（最重要）

#### 核心思路

使用 `Reserve()` API 直接在共享内存上预留空间，避免 Go 中间层拷贝。

#### 优化后的数据流

**写入路径（优化后）：**

```
┌─────────────┐    Reserve()    ┌─────────────┐
│  C 内存     │ ──────────────► │  共享内存   │
│  (用户数据) │   预留空间        │  (直接写入)  │
└─────────────┘                  └─────────────┘
        │                               ▲
        └──────── copy() ───────────────┘
                  一次拷贝
```

**读取路径（优化后）：**

```
┌─────────────┐     Peek()      ┌─────────────┐     copy()      ┌─────────────┐
│  共享内存   │ ──────────────► │  Go 切片    │ ──────────────► │  C 内存     │
│  (IPC数据)  │    零拷贝引用    │  (共享内存) │    一次拷贝     │  (用户缓冲) │
└─────────────┘                  └─────────────┘                 └─────────────┘
```

#### 优化代码实现

**shmipc_bridge_optimized.go 第 187-233 行：**

```go
//export ShmipcWrite
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()

    if !exists {
        return C.long(-1)
    }

    writer := stream.BufferWriter()
    
    // 关键优化：使用 Reserve 直接在共享内存上预留空间
    buf, err := writer.Reserve(int(length))
    if err != nil {
        // Fallback: 如果 Reserve 失败，使用传统方式
        atomic.AddUint64(&perfStats.reserveMisses, 1)
        buf := C.GoBytes(data, C.int(length))
        n, err := writer.WriteBytes(buf)
        if err != nil {
            return C.long(-2)
        }
        atomic.AddUint64(&perfStats.cgoCopyBytes, uint64(n))
        err = stream.Flush(false)
        if err != nil {
            return C.long(-3)
        }
        atomic.AddUint64(&perfStats.totalWrites, 1)
        atomic.AddUint64(&perfStats.totalWriteBytes, uint64(n))
        return C.long(n)
    }

    atomic.AddUint64(&perfStats.reserveHits, 1)
    
    // 直接从 C 内存拷贝到共享内存（一次拷贝）
    copy(buf, (*[1 << 30]byte)(data)[:length])

    err = stream.Flush(false)
    if err != nil {
        return C.long(-3)
    }

    atomic.AddUint64(&perfStats.totalWrites, 1)
    atomic.AddUint64(&perfStats.totalWriteBytes, uint64(length))

    return C.long(length)
}

//export ShmipcRead
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()

    if !exists {
        return C.long(-1)
    }

    reader := stream.BufferReader()
    
    // 关键优化：使用 Peek 获取共享内存指针（零拷贝）
    buf, err := reader.Peek(int(length))
    if err != nil {
        return C.long(-2)
    }
    
    // 从共享内存拷贝到 C 内存（一次拷贝）
    copy((*[1 << 30]byte)(data)[:len(buf)], buf)
    
    // 消费数据
    reader.Discard(len(buf))
    stream.ReleaseReadAndReuse()

    atomic.AddUint64(&perfStats.totalReads, 1)
    atomic.AddUint64(&perfStats.totalReadBytes, uint64(len(buf)))

    return C.long(len(buf))
}
```

#### 优化效果

| 操作 | 原始实现 | 优化实现 | 改善 |
|------|----------|----------|------|
| 写入 | 2次拷贝 | **1次拷贝** | 减少 50% |
| 读取 | 1次拷贝 | **1次拷贝** | 保持 |
| **总拷贝次数** | **3次** | **2次** | **减少 33%** |

---

### 3.2 方案二：批量 IO 优化

#### 核心思路

新增批量读写接口，支持 `writev()`/`readv()` 系统调用，减少系统调用次数。

#### 新增接口

**shmipc_bridge_optimized.go 第 235-285 行：**

```go
//export ShmipcWriteBatch
func ShmipcWriteBatch(streamID C.int, iov unsafe.Pointer, iovcnt C.int) C.long {
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()

    if !exists {
        return C.long(-1)
    }

    type iovec struct {
        iov_base unsafe.Pointer
        iov_len  C.size_t
    }

    goIOV := (*[1 << 20]iovec)(iov)[:iovcnt:iovcnt]
    writer := stream.BufferWriter()
    totalLen := 0

    // 批量写入所有 iovec
    for i := 0; i < int(iovcnt); i++ {
        dataLen := goIOV[i].iov_len
        if dataLen == 0 {
            continue
        }

        buf, err := writer.Reserve(int(dataLen))
        if err != nil {
            // Fallback
            cbuf := C.GoBytes(goIOV[i].iov_base, C.int(dataLen))
            writer.WriteBytes(cbuf)
            atomic.AddUint64(&perfStats.cgoCopyBytes, uint64(dataLen))
        } else {
            copy(buf, (*[1 << 30]byte)(goIOV[i].iov_base)[:dataLen])
            atomic.AddUint64(&perfStats.reserveHits, 1)
        }
        totalLen += int(dataLen)
    }

    // 一次性刷新
    err := stream.Flush(false)
    if err != nil {
        return C.long(-3)
    }

    atomic.AddUint64(&perfStats.totalWrites, 1)
    atomic.AddUint64(&perfStats.totalWriteBytes, uint64(totalLen))

    return C.long(totalLen)
}

//export ShmipcReadBatch
func ShmipcReadBatch(streamID C.int, iov unsafe.Pointer, iovcnt C.int) C.long {
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()

    if !exists {
        return C.long(-1)
    }

    type iovec struct {
        iov_base unsafe.Pointer
        iov_len  C.size_t
    }

    goIOV := (*[1 << 20]iovec)(iov)[:iovcnt:iovcnt]
    reader := stream.BufferReader()
    totalLen := 0

    for i := 0; i < int(iovcnt); i++ {
        dataLen := goIOV[i].iov_len
        if dataLen == 0 {
            continue
        }

        buf, err := reader.Peek(int(dataLen))
        if err != nil {
            break
        }

        copy((*[1 << 30]byte)(goIOV[i].iov_base)[:len(buf)], buf)
        reader.Discard(len(buf))
        totalLen += len(buf)
    }

    stream.ReleaseReadAndReuse()

    atomic.AddUint64(&perfStats.totalReads, 1)
    atomic.AddUint64(&perfStats.totalReadBytes, uint64(totalLen))

    return C.long(totalLen)
}
```

#### C 层劫持实现

**shmipc_preload_optimized.c 第 604-650 行：**

```c
/* ========== writev() 劫持 - 批量 IO 优化 ========== */
ssize_t writev(int fd, const struct iovec *iov, int iovcnt) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(fd);
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0 && 
        g_batch_io_enabled && iovcnt > 1 && iovcnt <= BATCH_IOV_MAX) {
        long ret = ShmipcWriteBatch(info->stream_id, iov, iovcnt);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_sent, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
            __sync_fetch_and_add(&g_stats.batch_write_ops, 1);
            __sync_fetch_and_add(&info->write_bytes, ret);
            __sync_fetch_and_add(&info->write_ops, 1);
            return (ssize_t)ret;
        }
    }
    
    ssize_t ret = real_writev(fd, iov, iovcnt);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
    }
    return ret;
}

/* ========== readv() 劫持 - 批量 IO 优化 ========== */
ssize_t readv(int fd, const struct iovec *iov, int iovcnt) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(fd);
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0 && 
        g_batch_io_enabled && iovcnt > 1 && iovcnt <= BATCH_IOV_MAX) {
        long ret = ShmipcReadBatch(info->stream_id, iov, iovcnt);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_recv, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
            __sync_fetch_and_add(&g_stats.batch_read_ops, 1);
            __sync_fetch_and_add(&info->read_bytes, ret);
            __sync_fetch_and_add(&info->read_ops, 1);
            return (ssize_t)ret;
        }
    }
    
    ssize_t ret = real_readv(fd, iov, iovcnt);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
    }
    return ret;
}
```

---

### 3.3 方案三：增大共享内存缓冲区

#### 核心思路

增大默认缓冲区，减少 fallback 触发。

#### 配置修改

**shmipc_bridge_optimized.go 第 36-53 行：**

```go
func loadConfig() {
    config = shmipc.DefaultConfig()
    config.QueueCap = 8192
    config.ShareMemoryBufferCap = 256 * 1024 * 1024  // 从 32MB 增大到 256MB
    config.MemMapType = shmipc.MemMapTypeMemFd

    if cap := os.Getenv("SHMIPC_QUEUE_CAP"); cap != "" {
        if c, err := strconv.ParseUint(cap, 10, 32); err == nil {
            config.QueueCap = uint32(c)
        }
    }

    if size := os.Getenv("SHMIPC_BUFFER_SIZE"); size != "" {
        if s, err := strconv.ParseUint(size, 10, 32); err == nil {
            config.ShareMemoryBufferCap = uint32(s)
        }
    }
}
```

---

## 四、源码修改清单

### 4.1 新增文件

| 文件 | 说明 |
|------|------|
| `shmipc_bridge_optimized.go` | 优化后的 Go CGO 桥接层 |
| `shmipc_preload_optimized.c` | 优化后的 C 预加载库 |
| `Makefile.optimized` | 编译优化版本的 Makefile |

### 4.2 未修改文件

| 文件 | 说明 |
|------|------|
| `shmipc_bridge.go` | 原始 Go CGO 桥接层（保持不变） |
| `shmipc_preload.c` | 原始 C 预加载库（保持不变） |
| `README.md` | 原始文档（保持不变） |
| `shmipc-go/*` | shmipc 核心库（保持不变） |

### 4.3 关键代码对比

#### 写入函数对比

| 特性 | 原始实现 | 优化实现 |
|------|----------|----------|
| API | `C.GoBytes()` + `WriteBytes()` | `Reserve()` + `copy()` |
| 拷贝次数 | 2次 | **1次** |
| 性能统计 | 无 | 有（Reserve Hits/Misses） |

#### 读取函数对比

| 特性 | 原始实现 | 优化实现 |
|------|----------|----------|
| API | `ReadBytes()` + `copy()` | `Peek()` + `Discard()` + `copy()` |
| 拷贝次数 | 1次 | **1次** |
| 内存管理 | `ReleaseReadAndReuse()` | `Discard()` + `ReleaseReadAndReuse()` |

---

## 五、编译和使用

### 5.1 编译

```bash
cd shmipc-preload

# 编译原始版本
make

# 编译优化版本
make -f Makefile.optimized all

# 同时编译两个版本
make all && make -f Makefile.optimized all
```

### 5.2 编译输出

```
libshmipc.so              # 原始版本 C 预加载库
libshmipc_go.so           # 原始版本 Go 共享库
libshmipc_optimized.so    # 优化版本 C 预加载库
libshmipc_go_optimized.so # 优化版本 Go 共享库
```

### 5.3 使用方式

```bash
# 使用原始版本
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw tcp_lat

# 使用优化版本
LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 tcp_bw tcp_lat
```

### 5.4 环境变量配置

```bash
# 共享内存大小（默认 256MB）
export SHMIPC_BUFFER_SIZE=$((512 * 1024 * 1024))

# 队列容量（默认 8192）
export SHMIPC_QUEUE_CAP=16384

# 启用批量 IO（默认启用）
export SHMIPC_BATCH_IO=1

# 日志级别（0-4）
export SHMIPC_LOG=3
```

---

## 六、性能对比

### 6.1 预期提升

| 场景 | 原始实现 | 优化实现 | 提升 |
|------|----------|----------|------|
| 小包延迟 (512B) | 10-20% 提升 | 15-25% 提升 | +5% |
| 中包延迟 (64KB) | 持平 | 15-25% 提升 | +20% |
| **大包延迟 (512KB)** | **-10% 劣化** | **20-30% 提升** | **+40%** |
| 带宽 | 持平 | 10-20% 提升 | +15% |

### 6.2 验证优化效果

```bash
# 开启日志查看统计信息
export SHMIPC_LOG=3
LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 -m 524288 -t 10

# 程序退出时会打印：
# === shmipc-bridge Performance Stats ===
# Total Writes:      1000
# Reserve Hits:      1000 (100.00%)   <-- 应该接近 100%
# CGO Copy Bytes:    0 (0.00 MB)      <-- 应该接近 0
# ======================================
```

---

## 七、性能分析工具

### 7.1 工具列表

位于 `performance_analysis/` 目录：

| 工具 | 说明 |
|------|------|
| `perf_shmipc.sh` | perf 性能分析 |
| `trace_shmipc.sh` | ftrace 追踪 |
| `comprehensive_bench.sh` | 综合基准测试 |
| `latency_comparison.sh` | 延迟对比测试 |
| `analyze_copy_overhead.sh` | 拷贝开销分析 |
| `quick_test.sh` | 快速功能测试 |
| `test_fallback.sh` | Fallback 检测 |
| `stress_test.sh` | 压力测试 |
| `monitor_memory.sh` | 内存监控 |
| `measure_memcpy.sh` | 内存拷贝测试 |
| `plot_latency.py` | 结果可视化 |

### 7.2 使用示例

```bash
cd performance_analysis

# 快速测试
./quick_test.sh

# 性能分析
./perf_shmipc.sh

# 延迟对比
./latency_comparison.sh
python3 plot_latency.py latency_results/latency_*.csv

# 拷贝开销分析
./analyze_copy_overhead.sh
```

---

## 八、常见问题

### Q1: 为什么大包性能仍然劣化？

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
- `Reserve Hits` 应该接近 100%
- `CGO Copy Bytes` 应该接近 0

### Q3: 如何选择合适的缓冲区大小？

建议设置为最大消息大小的 2-4 倍：

```bash
# 如果最大传输 100MB 数据
export SHMIPC_BUFFER_SIZE=$((400 * 1024 * 1024))  # 400MB
```

### Q4: 批量 IO 什么时候生效？

当应用程序使用 `writev()`/`readv()` 系统调用，且 iovec 数量 > 1 时自动启用。

---

## 九、下一步优化方向

1. **C 侧直接映射共享内存**：完全绕过 Go 层，消除所有 CGO 开销
2. **零拷贝 API**：提供类似 `splice()` 的零拷贝接口
3. **RDMA 支持**：对于跨节点通信，使用 RDMA 进一步降低延迟
4. **自适应批量**：根据负载自动调整批量大小

---

## 十、参考资料

- [shmipc-preload README.md](README.md) - 原始实现文档
- [performance_analysis/README.md](performance_analysis/README.md) - 性能分析工具使用指南
- [CGO 性能优化](https://github.com/golang/go/wiki/cgo)
- [共享内存 IPC 最佳实践](https://kernel.org/doc/html/latest/admin-guide/mm/shmem.html)
