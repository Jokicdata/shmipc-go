# shmipc Preload 拦截机制与数据拷贝分析

## 1. 整体架构

shmipc-preload 由两个核心文件组成，通过 LD_PRELOAD 劫持应用的 socket API，将本地进程间通信透明地转换为共享内存通信。

```
┌─────────────────────────────────────────────────────────────────┐
│                        应用层 (qperf)                            │
│  调用 write(fd, buf, 524288) / read(fd, buf, 524288)           │
└───────────────────────────┬─────────────────────────────────────┘
                            │ LD_PRELOAD 劫持
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│              C 劫持层 (shmipc_preload.c)                         │
│  拦截 write/read/send/recv 等函数                                │
│  判断 fd 是否属于 shmipc 连接 → 是则调用 Go 导出函数             │
│  否则透传到原始 libc 函数 (real_write/real_read)                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │ CGO 调用 (C → Go)
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│              Go 桥接层 (shmipc_bridge.go)                        │
│  ShmipcWrite: C.GoBytes + WriteBytes + Flush                    │
│  ShmipcRead:  ReadBytes + copy + ReleaseReadAndReuse            │
│  管理 sessions 和 streams 映射表                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│              shmipc-go 核心库                                    │
│  共享内存 mmap、无锁队列、epoll 通知                             │
│  零拷贝设计：Reserve 直接返回共享内存地址                        │
└─────────────────────────────────────────────────────────────────┘
```

### 1.1 文件职责

| 文件 | 语言 | 职责 |
|------|------|------|
| `shmipc_preload.c` | C | 劫持 socket API，管理 fd → shmipc 映射，决定走 shmipc 还是原始 socket |
| `shmipc_bridge.go` | Go | CGO 桥接，调用 shmipc-go 核心库，管理 Session/Stream 生命周期 |

### 1.2 关键数据结构

**C 侧 fd_info_t**（每个 fd 一条记录）：

```c
typedef struct {
    int fd;              // 文件描述符
    int domain;          // AF_INET / AF_UNIX
    int type;            // SOCK_STREAM 等
    int protocol;
    int conn_type;       // CONN_TYPE_SOCKET(0) 或 CONN_TYPE_SHMIPC(1)
    int is_connected;    // 是否已连接
    int is_listening;    // 是否在监听
    int is_server;       // 是否为服务端
    int stream_id;       // shmipc stream ID（-1 表示未分配）
    char path[256];      // Unix socket 路径
    pthread_mutex_t lock;
} fd_info_t;

static fd_info_t g_fds[4096];  // 全局 fd 表，下标即 fd 号
```

**Go 侧映射表**：

```go
var (
    sessions = make(map[int]*shmipc.Session)  // fd → Session
    streams  = make(map[int]*shmipc.Stream)   // streamID → Stream
)
```

---

## 2. 连接建立流程

以 qperf 为例，客户端连接服务端的完整流程：

### 2.1 服务端

```
qperf server 启动
    │
    ├─→ socket(AF_INET, SOCK_STREAM, 0)
    │     │
    │     │  [preload 劫持]
    │     ├─→ real_socket() 获取 fd=3
    │     ├─→ init_fd_info(3, AF_INET, SOCK_STREAM, 0)
    │     └─→ should_use_shmipc(AF_INET, SOCK_STREAM) → 1
    │           └─→ info->conn_type = CONN_TYPE_SHMIPC  ← 标记为 shmipc 候选
    │
    ├─→ bind(3, 0.0.0.0:19765)
    │     └─→ real_bind()  ← 透传，不做 shmipc 处理
    │
    ├─→ listen(3, 128)
    │     │
    │     │  [preload 劫持]
    │     └─→ info->conn_type == SHMIPC && info->is_server?
    │           └─→ 否（is_server=0，因为没有 bind Unix socket）
    │               └─→ real_listen()  ← 透传
    │
    └─→ accept(3, ...)
          │
          │  [preload 劫持]
          ├─→ real_accept() 获取 client_fd=4
          ├─→ server_info->conn_type == SHMIPC?
          │     └─→ 是
          │         ├─→ init_fd_info(4, ...)
          │         ├─→ client_info->conn_type = CONN_TYPE_SHMIPC
          │         ├─→ ShmipcAcceptStream(3)  ← CGO 调用
          │         │     └─→ session.AcceptStream()
          │         │           └─→ 等待客户端 OpenStream
          │         └─→ client_info->stream_id = stream_id
          └─→ return client_fd=4
```

### 2.2 客户端

```
qperf client 启动
    │
    ├─→ socket(AF_INET, SOCK_STREAM, 0)
    │     └─→ fd=5, conn_type=SHMIPC  ← 同服务端
    │
    └─→ connect(5, 127.0.0.1:19765)
          │
          │  [preload 劫持]
          ├─→ is_loopback_addr(127.0.0.1) → 1  ← 是本地回环
          ├─→ use_shmipc = 1
          ├─→ real_connect(5, 127.0.0.1:19765)  ← 先完成真实 TCP 连接
          │
          ├─→ ShmipcCreateClientSession(5, path)  ← CGO 调用
          │     │
          │     │  [Go 侧 shmipc_bridge.go:79]
          │     ├─→ os.NewFile(uintptr(fd), "unix")  ← 用 fd 创建 Go file
          │     ├─→ net.FileConn(file)                ← 获取 net.Conn
          │     ├─→ shmipc.Client(conn, config)       ← 创建 shmipc 客户端 Session
          │     │     ├─→ memfd_create() 创建共享内存 fd
          │     │     ├─→ ftruncate() 设置大小 (32MB)
          │     │     ├─→ mmap() 映射到进程地址空间
          │     │     └─→ 通过 Unix socket 将 memfd 传给对端
          │     └─→ sessions[5] = session
          │
          ├─→ ShmipcOpenStream(5)  ← CGO 调用
          │     │
          │     │  [Go 侧 shmipc_bridge.go:145]
          │     ├─→ session.OpenStream()
          │     └─→ streams[streamID] = stream
          │
          └─→ info->stream_id = streamID  ← 标记该 fd 已绑定 shmipc stream
```

**关键点**：connect 阶段先完成真实 TCP 连接（`real_connect`），然后在此基础上建立 shmipc Session。shmipc 利用已有的 TCP/Unix socket 连接进行 memfd 传递和同步通知。

---

## 3. 数据传输流程与拷贝分析

### 3.1 写方向（qperf 发送数据）

以 qperf 调用 `write(fd, buf, 524288)` 为例，逐行代码分析：

#### 第1步：qperf 应用层

```c
// qperf 源码 (src/qperf.c)
char *buf = qmalloc(524288);  // malloc 分配堆内存，物理页 PG#100
memset(buf, 'A', 524288);     // 填充测试数据
write(fd, buf, 524288);       // 调用 write 发送
```

此时数据在 qperf 的堆内存中，地址比如 `0x7f0000100000`。

#### 第2步：C 劫持层 write()

```c
// shmipc_preload.c:502-522
ssize_t write(int fd, const void *buf, size_t count) {
    init_real_funcs();

    fd_info_t *info = get_fd_info(fd);
    //                    ↑ 从全局 fd 表查找 fd 信息

    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        //  ↑ 检查：该 fd 是否标记为 shmipc 连接，且 stream 已建立

        long ret = ShmipcWrite(info->stream_id, buf, (long)count);
        //          ↑ CGO 调用，传入 stream_id、buf 指针、长度
        //            buf 仍然是 qperf 的堆内存地址，此时还没发生任何拷贝

        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_sent, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
            return (ssize_t)ret;
            // ↑ ShmipcWrite 成功，直接返回，数据已通过共享内存发送
        }
        // 如果 ret <= 0，ShmipcWrite 失败，回退到 real_write
    }

    // 非 shmipc 连接，或 ShmipcWrite 失败，走原始 socket
    ssize_t ret = real_write(fd, buf, count);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
    }
    return ret;
}
```

**此时**：buf 指针直接传给了 `ShmipcWrite`，还没发生任何拷贝。

#### 第3步：CGO 边界（C → Go）

`ShmipcWrite` 是 Go 编译出的 C 共享库导出函数，调用时发生 CGO 边界穿越：
- C 调用栈切换到 Go goroutine 栈
- 参数 `stream_id`、`data`（指针）、`length` 传递到 Go 侧

#### 第4步：Go 桥接层 ShmipcWrite()

```go
// shmipc_bridge.go:187-211
//export ShmipcWrite
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()
    // ↑ 从 streams 映射表查找 stream 对象

    if !exists {
        return C.long(-1)
    }

    // ★★★ 第1次拷贝：C 内存 → Go 堆 ★★★
    buf := C.GoBytes(data, C.int(length))
    //  C.GoBytes 的实现：
    //    1. 在 Go 堆上分配 length 字节的 []byte
    //    2. 调用 runtime.memmove 将 C 内存拷贝到 Go 堆
    //    等价于：buf = make([]byte, length); copy(buf, (*[1<<30]byte)(data)[:length])
    //
    //  源地址：data = 0x7f0000100000（qperf 堆内存，物理页 PG#100）
    //  目标地址：Go 堆分配的新 []byte（物理页 PG#150）
    //  拷贝量：524288 bytes
    //  底层实现：runtime.memmove()

    // ★★★ 第2次拷贝：Go 堆 → 共享内存 ★★★
    writer := stream.BufferWriter()
    //  ↑ 获取 stream 的发送缓冲区（linkedBuffer）
    //    其内部数据指向 mmap 映射的共享内存区域

    n, err := writer.WriteBytes(buf)
    //  WriteBytes 的实现（buffer.go:148）：
    //    遍历 linkedBuffer 的 bufferSlice 链表
    //    对每个 slice 调用 slice.append(data...)
    //      └─→ copy(slice.buf[slice.offset:], data)
    //           ↑ 将 Go 堆的 buf 拷贝到共享内存的 slice.buf
    //
    //  源地址：buf（Go 堆，物理页 PG#150）
    //  目标地址：slice.buf（mmap 共享内存，虚拟地址 0x7f0000a00000，物理页 PG#300）
    //  拷贝量：524288 bytes
    //  底层实现：runtime.memmove()

    if err != nil {
        return C.long(-2)
    }

    err = stream.Flush(false)
    //  Flush 的实现（stream.go:199）：
    //    1. sendBuf.done() — 标记写入完成
    //    2. sendQueue().put(queueElement{offsetInShmBuf, ...}) — 将数据偏移量放入共享内存中的无锁队列
    //    3. session.wakeUpPeer() — 通过 Unix socket 发送通知唤醒对端
    //  注意：Flush 不拷贝数据，只是通知对端"共享内存偏移 X 处有新数据"

    if err != nil {
        return C.long(-3)
    }

    return C.long(n)
}
```

#### 写方向拷贝总结

```
qperf buf (malloc 堆)          Go 堆               共享内存 (mmap)
  PG#100          ──memcpy──→  PG#150  ──memcpy──→  PG#300
  0x7f0000100000              Go 分配              0x7f0000a00000
       │                        │                     │
       │   C.GoBytes(data, n)   │   WriteBytes(buf)   │
       │   ★ 第1次拷贝 ★       │   ★ 第2次拷贝 ★    │
       └────────────────────────┴─────────────────────┘
```

**基础版共 2 次拷贝**：
1. `C.GoBytes(data, length)` — C 内存 → Go 堆（524288 bytes）
2. `writer.WriteBytes(buf)` — Go 堆 → 共享内存（524288 bytes）

---

### 3.2 读方向（qperf 接收数据）

以 qperf 调用 `read(fd, buf, 524288)` 为例：

#### 第1步：C 劫持层 read()

```c
// shmipc_preload.c:524-544
ssize_t read(int fd, void *buf, size_t count) {
    init_real_funcs();

    fd_info_t *info = get_fd_info(fd);

    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        long ret = ShmipcRead(info->stream_id, buf, (long)count);
        //          ↑ CGO 调用，传入 stream_id、buf 指针、长度
        //            buf 是 qperf 的堆内存地址，等待接收数据

        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_recv, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
            return (ssize_t)ret;
        }
    }

    ssize_t ret = real_read(fd, buf, count);
    // ...
    return ret;
}
```

#### 第2步：Go 桥接层 ShmipcRead()

```go
// shmipc_bridge.go:213-233
//export ShmipcRead
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()

    if !exists {
        return C.long(-1)
    }

    reader := stream.BufferReader()
    // ↑ 获取 stream 的接收缓冲区（linkedBuffer）
    //   其内部数据指向 mmap 映射的共享内存区域

    // ★★★ 第1次拷贝（内部）：共享内存 → Go slice ★★★
    buf, err := reader.ReadBytes(int(length))
    //  ReadBytes 的实现（buffer.go:317）：
    //    快速路径：slice.front().read(size)
    //      └─→ return s.data[start:start+size], nil
    //           ↑ 直接返回共享内存的子切片（零拷贝！）
    //    慢速路径：跨切片时 append 拷贝
    //
    //  注意：快速路径下 buf 直接指向共享内存，没有额外拷贝
    //  buf 的底层地址 = mmap 共享内存区域（物理页 PG#300）

    if err != nil {
        return C.long(-2)
    }

    // ★★★ 第2次拷贝：共享内存 → C 内存（qperf buf）★★★
    copy((*[1 << 30]byte)(data)[:len(buf)], buf)
    //  源地址：buf（共享内存，物理页 PG#300）
    //  目标地址：data（qperf 堆内存，物理页 PG#500）
    //  拷贝量：len(buf) bytes
    //  底层实现：runtime.memmove()

    stream.ReleaseReadAndReuse()
    //  释放已读的共享内存 buffer，并复用为发送缓冲区

    return C.long(len(buf))
}
```

#### 读方向拷贝总结

```
共享内存 (mmap)              Go slice (buf)         qperf buf (malloc 堆)
  PG#300          ──零拷贝──→  PG#300  ──memcpy──→  PG#500
  0x7f0000a00000             (同一物理页)           0x7f8800200000
       │                        │                     │
       │   ReadBytes(n)         │   copy(data, buf)   │
       │   快速路径零拷贝       │   ★ 唯一1次拷贝 ★  │
       └────────────────────────┴─────────────────────┘
```

**读方向共 1 次实际拷贝**：
- `copy((*[1<<30]byte)(data)[:], buf)` — 共享内存 → qperf 堆内存

（ReadBytes 快速路径下 buf 直接指向共享内存，不算额外拷贝）

---

## 4. 拷贝全景图

### 4.1 完整数据路径

```
发送端 (qperf client)                              接收端 (qperf server)
                                                   
qperf buf (malloc)                                 qperf buf (malloc)
  PG#100                                             PG#500
    │                                                  ↑
    │ write(fd, buf, 524288)                           │
    ▼                                                  │
[preload write() 劫持]                                │
    │                                                  │
    │ ShmipcWrite(stream_id, buf, 524288)              │
    ▼                                                  │
[CGO: C → Go]                                         │
    │                                                  │
    │ buf := C.GoBytes(data, 524288)                   │
    │ ★ 拷贝1: PG#100 → PG#150 (C内存→Go堆)          │
    ▼                                                  │
Go 堆                                                 │
  PG#150                                              │
    │                                                  │
    │ writer.WriteBytes(buf)                           │
    │ ★ 拷贝2: PG#150 → PG#300 (Go堆→共享内存)       │
    ▼                                                  │
共享内存 (mmap)  ◄──── 同一物理内存 ────►  共享内存 (mmap)
  PG#300                                  PG#300
    │                                          │
    │ Flush → wakeUpPeer()                     │
    │ (通过 UDS 通知对端)                       │
    │                                          ▼
    │                                     [CGO: Go → C]
    │                                          │
    │                                     buf := reader.ReadBytes(n)
    │                                     (快速路径：buf 直接指向 PG#300)
    │                                          │
    │                                     copy(data[:], buf)
    │                                     ★ 拷贝3: PG#300 → PG#500 (共享内存→C内存)
    │                                          │
    │                                          ▼
    │                                     qperf buf (malloc)
    │                                       PG#500
```

### 4.2 拷贝统计

| 方向 | 拷贝次数 | 具体操作 | 源 → 目标 | 代码位置 |
|------|---------|---------|-----------|---------|
| 写 | 2次 | `C.GoBytes` | C 堆 → Go 堆 | shmipc_bridge.go:197 |
| 写 | | `WriteBytes` | Go 堆 → 共享内存 | shmipc_bridge.go:200 |
| 读 | 1次 | `ReadBytes` | 共享内存 → Go slice | shmipc_bridge.go:224（快速路径零拷贝） |
| 读 | | `copy` | 共享内存 → C 堆 | shmipc_bridge.go:229 |
| **总计** | **3次** | | | |

### 4.3 与正常 TCP 路径对比

| 路径 | 写拷贝 | 读拷贝 | 总计 |
|------|--------|--------|------|
| 正常 TCP | 1次 (`copy_from_user`) | 1次 (`copy_to_user`) | **2次** |
| preload 基础版 | 2次 (`C.GoBytes` + `WriteBytes`) | 1次 (`copy`) | **3次** |
| preload 优化版 | 1次 (`Reserve` + `copy`) | 1次 (`copy`) | **2次** |

**基础版比正常 TCP 多 1 次拷贝**，原因就是 `C.GoBytes`。

---

## 5. C.GoBytes 详解：为什么多了一次拷贝

### 5.1 C.GoBytes 做了什么

```go
buf := C.GoBytes(data, C.int(length))
```

这行代码的内部实现：

1. Go 运行时在 Go 堆上分配 `length` 字节的内存
2. 调用 `runtime.memmove` 将 C 内存拷贝到 Go 堆
3. 返回一个指向 Go 堆内存的 `[]byte`

等价于：

```go
buf := make([]byte, length)
copy(buf, (*[1 << 30]byte)(data)[:length])
```

### 5.2 为什么必须拷贝

Go 的垃圾回收器（GC）只能管理 Go 堆上的内存。C 侧的 `data` 指针指向 qperf 的 malloc 堆，Go GC 无法追踪这块内存的生命周期。

如果直接把 C 指针转成 Go slice 而不拷贝：

```go
// 危险！不拷贝直接转换
buf := (*[1 << 30]byte)(data)[:length]
```

问题：
1. Go GC 不知道这块内存的存在，可能在 C 侧释放后继续访问（use-after-free）
2. Go 的写屏障（write barrier）不会处理 C 内存，可能导致 GC 数据不一致
3. C 内存不受 Go 栈伸缩机制管理，可能被 C 侧 realloc 或 free

因此 `C.GoBytes` 必须拷贝，这是 CGO 的安全机制。

### 5.3 优化版如何消除这次拷贝

优化版 `shmipc_bridge_opt.go` 使用 `Reserve` API 直接获取共享内存地址，然后用 `copy` 直接从 C 内存拷贝到共享内存：

```go
// 优化版：1次拷贝
reserved, err := writer.Reserve(n)           // 直接获取共享内存 buffer
copy(reserved, (*[1 << 30]byte)(data)[:n])   // C 内存 → 共享内存（1次拷贝）
```

```go
// 基础版：2次拷贝
buf := C.GoBytes(data, C.int(length))        // C 内存 → Go 堆（第1次拷贝）
writer.WriteBytes(buf)                        // Go 堆 → 共享内存（第2次拷贝）
```

优化版跳过了 Go 堆这个中间环节，直接从 C 内存拷贝到共享内存。

---

## 6. CGO 调用开销

除了数据拷贝，CGO 边界穿越本身也有开销：

### 6.1 CGO 调用过程

```
C 函数调用 ShmipcWrite()
    │
    ├─→ 保存当前 goroutine 状态
    ├─→ 切换到 g0 栈（系统栈）
    ├─→ 检查是否需要触发 GC（entersyscall）
    ├─→ 调用 Go 函数 ShmipcWrite
    │     ├─→ 获取 P（逻辑处理器）
    │     ├─→ 执行 Go 代码
    │     └─→ 释放 P
    ├─→ 恢复 goroutine 状态（exitsyscall）
    └─→ 返回 C
```

### 6.2 CGO 开销估算

| 项目 | 开销 | 说明 |
|------|------|------|
| 栈切换 | ~50-100ns | g0 栈切换 |
| GC 检查 | ~20-50ns | entersyscall/exitsyscall |
| 调度器交互 | ~50-200ns | 获取/释放 P |
| **总计** | **~100-350ns** | 每次 CGO 调用 |

对于小消息（1KB），CGO 开销约 100-350ns，而数据拷贝只需 ~100ns，CGO 开销占比可能超过 50%。

对于大消息（512KB），CGO 开销仍为 100-350ns，但数据拷贝需要 ~80us，CGO 开销占比不到 0.5%。

---

## 7. 拦截函数清单

### 7.1 被劫持并可能走 shmipc 的函数

| 函数 | 劫持行为 | shmipc 条件 |
|------|---------|-------------|
| `socket()` | 标记 fd 为 SHMIPC 候选 | domain=AF_UNIX 或 (AF_INET/INET6 + SOCK_STREAM) |
| `bind()` | 记录 Unix socket 路径 | addr->sa_family == AF_UNIX |
| `listen()` | 创建 shmipc 服务端 Session | conn_type==SHMIPC && is_server |
| `accept()` | 为 client_fd 创建 shmipc stream | server fd 是 SHMIPC |
| `accept4()` | 同 accept | 同上 |
| `connect()` | 创建 shmipc 客户端 Session + Stream | 目标是本地回环地址 |
| `write()` | 走 ShmipcWrite | conn_type==SHMIPC && stream_id>=0 |
| `read()` | 走 ShmipcRead | 同上 |
| `send()` | 走 ShmipcWrite | 同上 |
| `recv()` | 走 ShmipcRead | 同上 |
| `close()` | 关闭 shmipc stream + session | conn_type==SHMIPC |

### 7.2 直接透传的函数（不劫持）

| 函数 | 说明 |
|------|------|
| `writev()` | 基础版不劫持，直接走 real_writev |
| `readv()` | 基础版不劫持，直接走 real_readv |
| `sendto()` | 不劫持，直接走 real_sendto |
| `recvfrom()` | 不劫持，直接走 real_recvfrom |
| `shutdown()` | 透传 |
| `getsockopt()` | 透传 |
| `setsockopt()` | 透传 |
| `fcntl()` | 透传 |
| `dup()` | 透传 |
| `dup2()` | 透传 |

**注意**：基础版不劫持 `writev`/`readv`，如果应用使用这两个函数发送数据，数据会走原始 socket 而不是 shmipc，即使 fd 已标记为 SHMIPC。

---

## 8. 回退机制分析

### 8.1 现有回退逻辑

| 场景 | 回退行为 | 问题 |
|------|---------|------|
| `ShmipcInit()` 失败 | `g_shmipc_enabled=0`，全局禁用 | ✅ 正确 |
| `ShmipcCreateServerSession` 失败 | 只打日志，不回退 | ❌ fd 仍标记为 SHMIPC |
| `ShmipcCreateClientSession` 失败 | 只打日志，不回退 | ❌ 同上 |
| `ShmipcOpenStream` 失败 | stream_id 保持 -1 | ⚠️ 后续 write/read 因 stream_id<0 走 socket，但统计不准 |
| `ShmipcAcceptStream` 失败 | stream_id 保持 -1 | ⚠️ 同上 |
| `ShmipcWrite` 返回 <=0 | 走 `real_write` | ⚠️ 单次回退，下次仍先尝试 ShmipcWrite |
| `ShmipcRead` 返回 <=0 | 走 `real_read` | ⚠️ 同上 |

### 8.2 潜在问题

1. **Session 创建失败但不回退**：connect 阶段如果 `ShmipcCreateClientSession` 返回 -4，fd 仍标记为 `CONN_TYPE_SHMIPC`，但 stream_id=-1。后续每次 write/read 都会先检查 `conn_type==SHMIPC && stream_id>=0`，因为 stream_id=-1 条件不满足，所以走 real_write/real_read。**数据路径正确，但每次都有一次无用的条件判断**。

2. **ShmipcWrite 失败后不持久回退**：如果 ShmipcWrite 返回 -2（Reserve 失败），当前这次调用走 real_write，但下次 write 时仍会先尝试 ShmipcWrite。如果共享内存持续不足，每次都会先失败再回退，造成性能损失。

3. **writev/readv 不劫持**：如果应用使用 writev 发送数据，即使 fd 标记为 SHMIPC，数据仍走原始 socket。这可能导致部分数据走 shmipc、部分走 socket 的混乱情况。

---

## 9. 性能影响总结

### 9.1 小消息场景（1KB）

```
CGO 开销:        ~200ns    (占比 ~50%)
C.GoBytes 拷贝:  ~100ns    (占比 ~25%)
WriteBytes 拷贝: ~100ns    (占比 ~25%)
Flush 通知:      ~50ns     (占比 ~10%)
─────────────────────────
总计:            ~450ns

正常 TCP write:  ~300ns (copy_from_user + 系统调用)
preload 基础版:  ~450ns (CGO + 2次拷贝 + Flush)
差异:            +50% 劣化
```

小消息场景下 CGO 开销占比大，但绝对值小，对延迟影响有限。

### 9.2 大消息场景（512KB）

```
CGO 开销:        ~200ns    (占比 ~0.2%)
C.GoBytes 拷贝:  ~40us     (占比 ~33%)
WriteBytes 拷贝: ~40us     (占比 ~33%)
Flush 通知:      ~20us     (占比 ~17%)
─────────────────────────
总计:            ~100us

正常 TCP write:  ~60us (copy_from_user + 系统调用)
preload 基础版:  ~100us (CGO + 2次拷贝 + Flush)
差异:            +67% 劣化
```

大消息场景下，两次数据拷贝是主要开销，比正常 TCP 多一次拷贝导致性能劣化。

### 9.3 优化方向

| 优化 | 效果 | 实现难度 |
|------|------|---------|
| 用 Reserve API 替代 C.GoBytes + WriteBytes | 消除1次拷贝，写方向从2次降为1次 | 低（优化版已实现） |
| 劫持 writev/readv | 支持批量操作，减少 CGO 调用次数 | 中（优化版已实现） |
| 应用直接集成 shmipc API | 消除所有额外拷贝，真正零拷贝 | 高（需修改应用代码） |
