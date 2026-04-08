# shmipc-preload 性能优化方案

## 一、问题背景

### 1.1 现象描述

在使用 shmipc-preload 进行性能测试时，发现：

| 场景 | 测试结果 |
|------|----------|
| **小包传输** | 时延有提升 ✅ |
| **大包传输** | 时延有劣化 ❌ |
| **带宽** | 几乎无差别 |

### 1.2 问题分析

通过代码分析和性能测试，发现以下问题：

#### 问题 1：CGO 数据拷贝开销（核心问题）

原始实现中存在额外的数据拷贝：

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

**对比分析：**

| 场景 | 传统 Socket | shmipc + preload (原始) | 差异 |
|------|-------------|------------------------|------|
| 小包写入 | 用户→内核→Socket缓冲区 (2次拷贝) | 用户→Go→共享内存 (2次拷贝) | 相当 |
| 小包读取 | Socket缓冲区→内核→用户 (2次拷贝) | 共享内存→Go→用户 (1次拷贝) | **shmipc优** |
| 大包写入 | 同上 + 系统调用开销 | 同上 + CGO调用开销 | **Socket优** |
| 大包读取 | 同上 + 系统调用开销 | 同上 + CGO调用开销 | **Socket优** |

**结论：**
- **小包场景**：shmipc 避免了系统调用（~1μs），CGO 开销（~50-100ns）可忽略，所以**时延有提升**
- **大包场景**：数据拷贝时间（~ms级）远大于系统调用时间，额外的 CGO 拷贝反而成为瓶颈，所以**时延有劣化**

#### 问题 2：同步阻塞模式

当前实现每次写入都立即 `Flush()`，无法利用 shmipc 的批量 IO 优势：

```go
// shmipc_bridge.go (原始实现)
func ShmipcWrite(...) C.long {
    writer := stream.BufferWriter()
    n, err := writer.WriteBytes(buf)  // 写入
    err = stream.Flush(false)          // 立即刷新！无法批量
    return C.long(n)
}
```

#### 问题 3：共享内存缓冲区限制

默认配置只有 32MB，大文件传输可能触发 fallback 模式：

```go
// shmipc_bridge.go (原始实现)
config.ShareMemoryBufferCap = 32 * 1024 * 1024  // 32MB
```

---

## 二、优化方案

### 2.1 方案 1：消除 CGO 数据拷贝（最重要）

**核心思路**：使用 `Reserve()` API 直接在共享内存上预留空间，避免 Go 中间层拷贝。

**优化后的写入路径：**
```
┌─────────────┐    Reserve()    ┌─────────────┐
│  C 内存     │ ──────────────► │  共享内存   │
│  (用户数据) │   预留空间        │  (直接写入)  │
└─────────────┘                  └─────────────┘
        │                               ▲
        └──────── copy() ───────────────┘
                  一次拷贝
```

**代码对比：**

```go
// 原始实现：2次拷贝
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    buf := C.GoBytes(data, C.int(length))  // 拷贝 #1: C → Go
    writer := stream.BufferWriter()
    n, _ := writer.WriteBytes(buf)          // 拷贝 #2: Go → 共享内存
    stream.Flush(false)
    return C.long(n)
}

// 优化实现：1次拷贝
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    writer := stream.BufferWriter()
    buf, _ := writer.Reserve(int(length))   // 零拷贝预留空间
    copy(buf, (*[1 << 30]byte)(data)[:length])  // 拷贝 #1: C → 共享内存
    stream.Flush(false)
    return C.long(length)
}
```

**优化效果：**
- 写入：2次拷贝 → **1次拷贝**（减少 50%）
- 读取：1次拷贝 → **1次拷贝**（保持）

### 2.2 方案 2：批量 IO 优化

**核心思路**：新增批量读写接口，支持 `writev()`/`readv()` 系统调用。

**新增接口：**

```go
// 批量写入
//export ShmipcWriteBatch
func ShmipcWriteBatch(streamID C.int, iov unsafe.Pointer, iovcnt C.int) C.long {
    // 解析 iovec 数组
    goIOV := (*[1 << 20]iovec)(iov)[:iovcnt:iovcnt]
    writer := stream.BufferWriter()
    totalLen := 0
    
    // 批量写入所有 iovec
    for i := 0; i < int(iovcnt); i++ {
        buf, _ := writer.Reserve(int(goIOV[i].iov_len))
        copy(buf, (*[1 << 30]byte)(goIOV[i].iov_base)[:goIOV[i].iov_len])
        totalLen += int(goIOV[i].iov_len)
    }
    
    // 一次性刷新
    stream.Flush(false)
    return C.long(totalLen)
}
```

**C 层劫持 writev：**

```c
ssize_t writev(int fd, const struct iovec *iov, int iovcnt) {
    fd_info_t *info = get_fd_info(fd);
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && iovcnt > 1) {
        // 使用批量接口
        long ret = ShmipcWriteBatch(info->stream_id, iov, iovcnt);
        return (ssize_t)ret;
    }
    
    return real_writev(fd, iov, iovcnt);
}
```

### 2.3 方案 3：增大共享内存缓冲区

**核心思路**：增大默认缓冲区，减少 fallback 触发。

```go
// 原始配置
config.ShareMemoryBufferCap = 32 * 1024 * 1024  // 32MB

// 优化配置
config.ShareMemoryBufferCap = 256 * 1024 * 1024  // 256MB
```

---

## 三、文件说明

### 3.1 优化版本源码

| 文件 | 说明 |
|------|------|
| `shmipc_bridge_optimized.go` | 优化后的 Go CGO 桥接层 |
| `shmipc_preload_optimized.c` | 优化后的 C 预加载库 |
| `Makefile.optimized` | 编译优化版本的 Makefile |

### 3.2 性能分析工具

位于 `performance_analysis/` 目录，详见 [performance_analysis/README.md](performance_analysis/README.md)。

---

## 四、编译和使用

### 4.1 编译

```bash
cd shmipc-preload

# 编译原始版本
make

# 编译优化版本
make -f Makefile.optimized all

# 或者同时编译两个版本
make all
make -f Makefile.optimized all
```

编译输出：
```
libshmipc.so            # 原始版本 C 预加载库
libshmipc_go.so         # 原始版本 Go 共享库
libshmipc_optimized.so  # 优化版本 C 预加载库
libshmipc_go_optimized.so  # 优化版本 Go 共享库
```

### 4.2 使用

```bash
# 使用原始版本
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw tcp_lat

# 使用优化版本
LD_PRELOAD=./libshmipc_optimized.so qperf 127.0.0.1 tcp_bw tcp_lat
```

### 4.3 环境变量配置

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

## 五、性能对比

### 5.1 预期提升

| 场景 | 原始实现 | 优化实现 | 提升 |
|------|----------|----------|------|
| 小包延迟 (512B) | 10-20% 提升 | 15-25% 提升 | +5% |
| 中包延迟 (64KB) | 持平 | 15-25% 提升 | +20% |
| **大包延迟 (512KB)** | **-10% 劣化** | **20-30% 提升** | **+40%** |
| 带宽 | 持平 | 10-20% 提升 | +15% |

### 5.2 验证优化效果

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

### 5.3 性能测试

```bash
cd performance_analysis

# 延迟对比测试
./latency_comparison.sh

# 综合基准测试
./comprehensive_bench.sh

# 性能分析
./perf_shmipc.sh
```

---

## 六、常见问题

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

查看退出时的统计信息，`Reserve Hits` 应该接近 100%，`CGO Copy Bytes` 应该接近 0。

### Q3: 如何选择合适的缓冲区大小？

建议设置为最大消息大小的 2-4 倍。例如，如果最大传输 100MB 数据：

```bash
export SHMIPC_BUFFER_SIZE=$((400 * 1024 * 1024))  # 400MB
```

### Q4: 批量 IO 什么时候生效？

当应用程序使用 `writev()`/`readv()` 系统调用，且 iovec 数量 > 1 时自动启用。

---

## 七、架构对比

### 原始实现

```
┌─────────────┐   C.GoBytes()   ┌─────────────┐  WriteBytes()  ┌─────────────┐
│  C 内存     │ ──────────────► │  Go 内存    │ ──────────────► │  共享内存   │
└─────────────┘    拷贝 #1       └─────────────┘    拷贝 #2      └─────────────┘
```

### 优化实现

```
┌─────────────┐    Reserve()    ┌─────────────┐
│  C 内存     │ ──────────────► │  共享内存   │
└─────────────┘   直接预留空间   └─────────────┘
        │                              ▲
        └──────── copy() ─────────────┘
              一次拷贝
```

---

## 八、下一步优化方向

1. **C 侧直接映射共享内存**：完全绕过 Go 层，消除所有 CGO 开销
2. **零拷贝 API**：提供类似 `splice()` 的零拷贝接口
3. **RDMA 支持**：对于跨节点通信，使用 RDMA 进一步降低延迟
4. **自适应批量**：根据负载自动调整批量大小

---

## 九、参考资料

- [shmipc-preload README.md](README.md) - 原始实现文档
- [performance_analysis/README.md](performance_analysis/README.md) - 性能分析工具使用指南
- [CGO 性能优化](https://github.com/golang/go/wiki/cgo)
- [共享内存 IPC 最佳实践](https://kernel.org/doc/html/latest/admin-guide/mm/shmem.html)
