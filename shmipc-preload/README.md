# shmipc-preload

shmipc 透明代理 - 应用无感替换的进程间通信加速工具

## 目录

1. [概述](#一概述)
2. [架构设计](#二架构设计)
3. [工作原理](#三工作原理)
4. [调用流程](#四调用流程)
5. [使用方式](#五使用方式)
6. [编译安装](#六编译安装)
7. [配置说明](#七配置说明)
8. [示例程序](#八示例程序)
9. [故障排查](#九故障排查)

---

## 一、概述

### 1.1 功能介绍

shmipc-preload 是一个基于 LD_PRELOAD 技术的透明代理工具，能够自动将应用程序的本地 IPC 连接（UDS/TCP loopback）转换为 shmipc 连接，实现零拷贝通信加速，无需修改应用程序代码。

### 1.2 核心特性

- **零代码修改**：应用程序无需任何修改即可使用
- **自动检测**：自动识别 UDS 和 TCP loopback 连接
- **透明降级**：不支持的场景自动回退到原始 socket
- **简单易用**：只需一个 .so 文件，一行命令启动
- **高性能**：大包场景下延迟降低 2-3 倍

### 1.3 适用场景

| 场景 | 支持状态 | 说明 |
|------|----------|------|
| qperf 性能测试 | ✅ 支持 | UDS/TCP loopback 自动加速 |
| sockperf 性能测试 | ✅ 支持 | 本地回环测试加速 |
| Redis 本地连接 | ✅ 支持 | UDS 连接加速 |
| MySQL 本地连接 | ✅ 支持 | UDS 连接加速 |
| 自定义 IPC 应用 | ✅ 支持 | 任何使用 UDS/loopback 的程序 |

---

## 二、架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              应用层 (Application Layer)                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                        应用程序 (qperf/sockperf/Redis/等)                │    │
│  │                                                                         │    │
│  │   socket() → bind() → listen() → accept() → send() → recv() → close()  │    │
│  └────────────────────────────────────────┬────────────────────────────────┘    │
│                                           │                                     │
│                                           ▼                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                              拦截层 (Interception Layer)                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                         libshmipc.so (LD_PRELOAD)                        │    │
│  │                                                                         │    │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │    │
│  │  │                    shmipc_preload.c (C 语言)                     │   │    │
│  │  │                                                                 │   │    │
│  │  │   - 劫持 socket API (socket/bind/listen/accept/connect/...)    │   │    │
│  │  │   - 判断连接类型 (UDS/TCP loopback/其他)                        │   │    │
│  │  │   - 调用 Go 层接口                                              │   │    │
│  │  │   - 管理 fd → Session → Stream 映射                            │   │    │
│  │  │                                                                 │   │    │
│  │  └──────────────────────────┬──────────────────────────────────────┘   │    │
│  │                             │ CGO 调用                                  │    │
│  │                             ▼                                          │    │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │    │
│  │  │                    shmipc_bridge.go (Go 语言)                    │   │    │
│  │  │                                                                 │   │    │
│  │  │   - 导出 C 兼容接口 (//export ShmipcXxx)                        │   │    │
│  │  │   - 封装 shmipc-go 库调用                                       │   │    │
│  │  │   - 管理 Session 和 Stream 生命周期                             │   │    │
│  │  │   - 类型转换 (C 类型 ↔ Go 类型)                                 │   │    │
│  │  │                                                                 │   │    │
│  │  └──────────────────────────┬──────────────────────────────────────┘   │    │
│  └─────────────────────────────┼───────────────────────────────────────────┘    │
│                                │                                                 │
├────────────────────────────────┼─────────────────────────────────────────────────┤
│                              核心层 (Core Layer)                                 │
│                                ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                          shmipc-go 核心库                                │    │
│  │                                                                         │    │
│  │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │    │
│  │   │   Session   │  │   Stream    │  │   Buffer    │  │   Queue     │  │    │
│  │   │   Manager   │  │   Manager   │  │   Manager   │  │   Manager   │  │    │
│  │   └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘  │    │
│  │                                                                         │    │
│  │   ┌─────────────────────────────────────────────────────────────────┐  │    │
│  │   │                      共享内存 (Shared Memory)                    │  │    │
│  │   │                                                                  │  │    │
│  │   │   ┌─────────────────────┐    ┌─────────────────────┐            │  │    │
│  │   │   │   Buffer Region     │    │    Queue Region     │            │  │    │
│  │   │   │   (数据缓冲区)       │    │    (元数据队列)      │            │  │    │
│  │   │   └─────────────────────┘    └─────────────────────┘            │  │    │
│  │   │                                                                  │  │    │
│  │   └─────────────────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 文件结构

```
shmipc-preload/
├── Makefile              # 编译脚本
├── README.md             # 本文档
├── shmipc_preload.c      # C 语言拦截层
└── shmipc_bridge.go      # Go CGO 桥接层
```

### 2.3 组件说明

| 组件 | 语言 | 功能 |
|------|------|------|
| shmipc_preload.c | C | 劫持 socket API，判断连接类型，调用 Go 接口 |
| shmipc_bridge.go | Go | 导出 C 兼容接口，封装 shmipc-go 调用 |
| shmipc-go | Go | 核心库，实现共享内存零拷贝通信 |

---

## 三、工作原理

### 3.1 LD_PRELOAD 原理

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LD_PRELOAD 工作原理                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   应用程序                                                                       │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │  socket() → bind() → listen() → accept() → send() → recv() → close()    │  │
│  └────────────────────────────────────────┬─────────────────────────────────┘  │
│                                           │                                     │
│                                           ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                    动态链接器 (ld-linux.so)                               │  │
│  │                                                                          │  │
│  │   1. 检查 LD_PRELOAD 环境变量                                            │  │
│  │   2. 优先加载预加载库中的符号                                             │  │
│  │   3. 如果预加载库没有该符号，再查找原始库                                  │  │
│  │                                                                          │  │
│  └────────────────────────────────────────┬─────────────────────────────────┘  │
│                                           │                                     │
│                     ┌─────────────────────┴─────────────────────┐               │
│                     │                                           │               │
│                     ▼                                           ▼               │
│  ┌──────────────────────────────────┐    ┌──────────────────────────────────┐  │
│  │   libshmipc.so (预加载库)         │    │   libc.so (原始库)               │  │
│  │                                  │    │                                  │  │
│  │   - socket()  ← 劫持             │    │   - socket()                     │  │
│  │   - bind()    ← 劫持             │    │   - bind()                       │  │
│  │   - listen()  ← 劫持             │    │   - listen()                     │  │
│  │   - accept()  ← 劫持             │    │   - accept()                     │  │
│  │   - connect() ← 劫持             │    │   - connect()                    │  │
│  │   - send()    ← 劫持             │    │   - send()                       │  │
│  │   - recv()    ← 劫持             │    │   - recv()                       │  │
│  │   - close()   ← 劫持             │    │   - close()                      │  │
│  │                                  │    │                                  │  │
│  │   内部调用 dlsym(RTLD_NEXT, ...)  │───►│   通过 RTLD_NEXT 调用原始函数    │  │
│  └──────────────────────────────────┘    └──────────────────────────────────┘  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 CGO 互操作原理

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           C 与 Go 互操作流程                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  C 代码 (shmipc_preload.c)                                                      │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                                                                          │  │
│  │  // 1. 声明外部 Go 函数                                                   │  │
│  │  extern int ShmipcInit(void);                                            │  │
│  │  extern int ShmipcOpenStream(int fd);                                    │  │
│  │  extern long ShmipcWrite(int stream_id, const void *data, long length);  │  │
│  │  extern long ShmipcRead(int stream_id, void *data, long length);         │  │
│  │                                                                          │  │
│  │  // 2. 调用 Go 函数                                                       │  │
│  │  int stream_id = ShmipcOpenStream(fd);                                   │  │
│  │  long n = ShmipcWrite(stream_id, buf, len);                              │  │
│  │                                                                          │  │
│  └────────────────────────────────────────┬─────────────────────────────────┘  │
│                                           │                                     │
│                                           ▼ CGO 调用边界                        │
│                                                                                 │
│  Go 代码 (shmipc_bridge.go)                                                     │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                                                                          │  │
│  │  // 1. 导出函数供 C 调用                                                  │  │
│  │  //export ShmipcOpenStream                                               │  │
│  │  func ShmipcOpenStream(fd C.int) C.int {                                 │  │
│  │      session := sessions[int(fd)]                                        │  │
│  │      stream, err := session.OpenStream()                                 │  │
│  │      if err != nil {                                                     │  │
│  │          return C.int(-1)                                                │  │
│  │      }                                                                   │  │
│  │      streamID := int(stream.StreamID())                                  │  │
│  │      streams[streamID] = stream                                          │  │
│  │      return C.int(streamID)                                              │  │
│  │  }                                                                       │  │
│  │                                                                          │  │
│  │  // 2. 类型转换                                                          │  │
│  │  // C.int → int, C.long → int64, *C.char → string                       │  │
│  │                                                                          │  │
│  │  // 3. 调用 shmipc-go 核心库                                              │  │
│  │  stream.BufferWriter().WriteBytes(buf)                                   │  │
│  │  stream.Flush(false)                                                     │  │
│  │                                                                          │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 数据流对比

#### 原始 Socket 数据流

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           原始 Socket 数据流                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   客户端进程                              服务端进程                              │
│  ┌──────────────┐                       ┌──────────────┐                        │
│  │   用户态      │                       │   用户态      │                        │
│  │  ┌────────┐  │                       │  ┌────────┐  │                        │
│  │  │应用数据│  │                       │  │应用数据│  │                        │
│  │  └────┬───┘  │                       │  └────▲───┘  │                        │
│  │       │ 拷贝 │                       │       │ 拷贝 │                        │
│  │       ▼      │                       │       │      │                        │
│  │  ┌────────┐  │                       │  ┌────────┐  │                        │
│  │  │用户缓冲│  │                       │  │用户缓冲│  │                        │
│  │  └────────┘  │                       │  └────────┘  │                        │
│  └──────────────┘                       └──────────────┘                        │
│         │                                      │                                │
│         │ 内核拷贝                              │                                │
│         ▼                                      ▼                                │
│  ┌──────────────┐                       ┌──────────────┐                        │
│  │   内核态      │                       │   内核态      │                        │
│  │  ┌────────┐  │                       │  ┌────────┐  │                        │
│  │  │内核缓冲│◄─┼───────────────────────┼─►│内核缓冲│  │                        │
│  │  └────────┘  │                       │  └────────┘  │                        │
│  └──────────────┘                       └──────────────┘                        │
│                                                                                 │
│  数据拷贝次数：4 次 (用户态↔内核态 × 2)                                          │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### shmipc 数据流

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           shmipc 数据流                                          │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   客户端进程                              服务端进程                              │
│  ┌──────────────┐                       ┌──────────────┐                        │
│  │   用户态      │                       │   用户态      │                        │
│  │  ┌────────┐  │                       │  ┌────────┐  │                        │
│  │  │应用数据│  │    共享内存（零拷贝）  │  │应用数据│  │                        │
│  │  └────┬───┘  │ ══════════════════════│  └────▲───┘  │                        │
│  │       │      │                       │       │      │                        │
│  │       ▼      │                       │       ▼      │                        │
│  │  ┌────────┐  │                       │  ┌────────┐  │                        │
│  │  │共享内存│◄─┼───────────────────────┼─►│共享内存│  │                        │
│  │  └────────┘  │                       │  └────────┘  │                        │
│  └──────────────┘                       └──────────────┘                        │
│         │                                      │                                │
│         │ UDS（仅传输元数据/通知）              │                                │
│         ▼                                      ▼                                │
│  ┌──────────────┐                       ┌──────────────┐                        │
│  │   内核态      │                       │   内核态      │                        │
│  │  ┌────────┐  │                       │  ┌────────┐  │                        │
│  │  │通知事件│◄─┼───────────────────────┼─►│通知事件│  │                        │
│  │  └────────┘  │                       │  └────────┘  │                        │
│  └──────────────┘                       └──────────────┘                        │
│                                                                                 │
│  数据拷贝次数：0 次 (零拷贝)                                                     │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 四、调用流程

### 4.1 服务端初始化流程

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           服务端初始化流程                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  应用程序调用                     libshmipc.so                  shmipc-go       │
│  ┌──────────────┐               ┌──────────────┐              ┌──────────────┐ │
│  │ socket()     │──► C 层劫持 ──►│              │              │              │ │
│  │              │               │ real_socket()│              │              │ │
│  │              │               │ 记录 fd 信息  │              │              │ │
│  └──────────────┘               └──────────────┘              └──────────────┘ │
│                                                                                 │
│  ┌──────────────┐               ┌──────────────┐              ┌──────────────┐ │
│  │ bind()       │──► C 层劫持 ──►│              │              │              │ │
│  │              │               │ 记录 UDS 路径 │              │              │ │
│  │              │               │ 标记 is_server│              │              │ │
│  └──────────────┘               └──────────────┘              └──────────────┘ │
│                                                                                 │
│  ┌──────────────┐               ┌──────────────┐              ┌──────────────┐ │
│  │ listen()     │──► C 层劫持 ──►│              │              │              │ │
│  │              │               │ 调用 Go 接口 ─┼─────────────►│ Server()    │ │
│  │              │               │              │              │ 创建 Session │ │
│  │              │               │              │◄─────────────│ 初始化共享内存│ │
│  └──────────────┘               └──────────────┘              └──────────────┘ │
│                                                                                 │
│  ┌──────────────┐               ┌──────────────┐              ┌──────────────┐ │
│  │ accept()     │──► C 层劫持 ──►│              │              │              │ │
│  │              │               │ real_accept()│              │              │ │
│  │              │               │ 调用 Go 接口 ─┼─────────────►│AcceptStream()│ │
│  │              │               │              │              │ 等待客户端    │ │
│  │              │               │ 返回 stream_id│◄─────────────│ 创建 Stream  │ │
│  └──────────────┘               └──────────────┘              └──────────────┘ │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 客户端初始化流程

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           客户端初始化流程                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  应用程序调用                     libshmipc.so                  shmipc-go       │
│  ┌──────────────┐               ┌──────────────┐              ┌──────────────┐ │
│  │ socket()     │──► C 层劫持 ──►│              │              │              │ │
│  │              │               │ real_socket()│              │              │ │
│  │              │               │ 记录 fd 信息  │              │              │ │
│  └──────────────┘               └──────────────┘              └──────────────┘ │
│                                                                                 │
│  ┌──────────────┐               ┌──────────────┐              ┌──────────────┐ │
│  │ connect()    │──► C 层劫持 ──►│              │              │              │ │
│  │              │               │ 判断连接类型  │              │              │ │
│  │              │               │ (UDS/loopback)│              │              │ │
│  │              │               │              │              │              │ │
│  │              │               │ real_connect()│              │              │ │
│  │              │               │              │              │              │ │
│  │              │               │ 调用 Go 接口 ─┼─────────────►│NewClientSession│
│  │              │               │              │              │ 初始化共享内存 │ │
│  │              │               │              │              │ 映射服务端内存 │ │
│  │              │               │              │◄─────────────│ 创建 Session  │ │
│  │              │               │              │              │              │ │
│  │              │               │ 调用 Go 接口 ─┼─────────────►│ OpenStream() │ │
│  │              │               │ 返回 stream_id│◄─────────────│ 创建 Stream  │ │
│  └──────────────┘               └──────────────┘              └──────────────┘ │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 4.3 数据发送流程

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           数据发送流程                                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  应用程序调用                     libshmipc.so                  shmipc-go       │
│  ┌──────────────┐               ┌──────────────┐              ┌──────────────┐ │
│  │ send() 或    │──► C 层劫持 ──►│              │              │              │ │
│  │ write()      │               │ 查找 fd 信息  │              │              │ │
│  │              │               │              │              │              │ │
│  │              │               │ if (shmipc) { │              │              │ │
│  │              │               │   调用 Go ────┼─────────────►│BufferWriter()│ │
│  │              │               │ }            │              │ .WriteBytes()│ │
│  │              │               │              │              │   ↓          │ │
│  │              │               │              │              │ 写入共享内存  │ │
│  │              │               │              │              │   ↓          │ │
│  │              │               │              │◄─────────────│ Flush()      │ │
│  │              │               │              │              │ wakeUpPeer() │ │
│  │              │               │ 返回写入字节数│              │              │ │
│  │              │               │ } else {     │              │              │ │
│  │              │               │   real_send()│              │              │ │
│  │              │               │ }            │              │              │ │
│  └──────────────┘               └──────────────┘              └──────────────┘ │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 4.4 数据接收流程

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           数据接收流程                                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  应用程序调用                     libshmipc.so                  shmipc-go       │
│  ┌──────────────┐               ┌──────────────┐              ┌──────────────┐ │
│  │ recv() 或    │──► C 层劫持 ──►│              │              │              │ │
│  │ read()       │               │ 查找 fd 信息  │              │              │ │
│  │              │               │              │              │              │ │
│  │              │               │ if (shmipc) { │              │              │ │
│  │              │               │   调用 Go ────┼─────────────►│BufferReader()│ │
│  │              │               │ }            │              │ .ReadBytes() │ │
│  │              │               │              │              │   ↓          │ │
│  │              │               │              │              │ 从共享内存读取│ │
│  │              │               │              │              │   ↓          │ │
│  │              │               │              │◄─────────────│ReleaseRead() │ │
│  │              │               │ 返回读取字节数│              │              │ │
│  │              │               │ } else {     │              │              │ │
│  │              │               │   real_recv()│              │              │ │
│  │              │               │ }            │              │              │ │
│  └──────────────┘               └──────────────┘              └──────────────┘ │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 4.5 关键函数映射表

| C 函数 (应用程序调用) | C 层处理 | Go 层调用 | shmipc-go 核心函数 |
|----------------------|----------|-----------|-------------------|
| `socket()` | 记录 fd 信息 | - | - |
| `bind()` | 记录 UDS 路径 | - | - |
| `listen()` | 标记服务端 | `ShmipcCreateServerSession()` | `shmipc.Server()` |
| `accept()` | 创建客户端 fd | `ShmipcAcceptStream()` | `session.AcceptStream()` |
| `connect()` | 判断连接类型 | `ShmipcCreateClientSession()`, `ShmipcOpenStream()` | `shmipc.NewClientSession()`, `session.OpenStream()` |
| `send()/write()` | 查找 stream_id | `ShmipcWrite()` | `stream.BufferWriter().WriteBytes()`, `stream.Flush()` |
| `recv()/read()` | 查找 stream_id | `ShmipcRead()` | `stream.BufferReader().ReadBytes()`, `stream.ReleaseReadAndReuse()` |
| `close()` | 清理资源 | `ShmipcCloseStream()`, `ShmipcCloseSession()` | `stream.Close()`, `session.Close()` |

---

## 五、使用方式

### 5.1 基本用法

```bash
# 基本格式
LD_PRELOAD=./libshmipc.so <your-program> [args...]
```

### 5.2 qperf 示例

```bash
# 服务端
LD_PRELOAD=./libshmipc.so qperf

# 客户端（测试 TCP 带宽）
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw

# 客户端（测试 TCP 延迟）
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_lat

# 客户端（测试多个指标）
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw tcp_lat
```

### 5.3 sockperf 示例

```bash
# 服务端
LD_PRELOAD=./libshmipc.so sockperf sr --tcp -i 127.0.0.1 -p 11111

# 客户端（Ping-Pong 测试）
LD_PRELOAD=./libshmipc.so sockperf pp --tcp -i 127.0.0.1 -p 11111 -m 64K -t 10

# 客户端（吞吐量测试）
LD_PRELOAD=./libshmipc.so sockperf tp --tcp -i 127.0.0.1 -p 11111 -m 64K -t 10
```

### 5.4 Redis 示例

```bash
# 服务端
LD_PRELOAD=./libshmipc.so redis-server --unixsocket /tmp/redis.sock

# 客户端（benchmark）
LD_PRELOAD=./libshmipc.so redis-benchmark -s /tmp/redis.sock -t set,get -n 100000

# 客户端（cli）
LD_PRELOAD=./libshmipc.so redis-cli -s /tmp/redis.sock
```

### 5.5 MySQL 示例

```bash
# 服务端
LD_PRELOAD=./libshmipc.so mysqld --socket=/tmp/mysql.sock

# 客户端
LD_PRELOAD=./libshmipc.so mysql -S /tmp/mysql.sock -u root -p
```

---

## 六、编译安装

### 6.1 系统要求

- **操作系统**: Linux (内核 3.17+，支持 memfd_create)
- **架构**: x86_64 或 arm64
- **Go 版本**: 1.20+
- **GCC**: 7.0+

### 6.2 编译

```bash
cd shmipc-preload
make
```

编译输出：
```
libshmipc.so      # 最终交付的共享库
```

### 6.3 安装

```bash
sudo make install
```

安装后使用：
```bash
LD_PRELOAD=/usr/local/lib/libshmipc.so <your-program>
```

---

## 七、配置说明

### 7.1 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `SHMIPC_LOG` | 日志级别 (0-4) | 1 |
| `SHMIPC_ENABLE` | 是否启用 (0/1) | 1 |
| `SHMIPC_QUEUE_CAP` | 队列容量 | 8192 |
| `SHMIPC_BUFFER_SIZE` | 共享内存大小 | 33554432 (32MB) |

### 7.2 日志级别

| 级别 | 说明 |
|------|------|
| 0 | 静默模式 |
| 1 | 仅错误 (默认) |
| 2 | 警告及以上 |
| 3 | 信息及以上 |
| 4 | 调试 (所有日志) |

### 7.3 使用示例

```bash
# 开启调试日志
SHMIPC_LOG=4 LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw

# 禁用 shmipc（用于对比测试）
SHMIPC_ENABLE=0 LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw

# 调整共享内存大小
SHMIPC_BUFFER_SIZE=67108864 LD_PRELOAD=./libshmipc.so <your-program>
```

---

## 八、示例程序

### 8.1 简单 Echo 服务

```c
// echo_server.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCKET_PATH "/tmp/echo.sock"
#define BUFFER_SIZE 1024

int main() {
    int server_fd, client_fd;
    struct sockaddr_un addr;
    char buffer[BUFFER_SIZE];
    
    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, SOCKET_PATH);
    unlink(SOCKET_PATH);
    
    bind(server_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(server_fd, 5);
    
    printf("Server listening on %s\n", SOCKET_PATH);
    
    client_fd = accept(server_fd, NULL, NULL);
    printf("Client connected\n");
    
    while (1) {
        ssize_t n = read(client_fd, buffer, BUFFER_SIZE);
        if (n <= 0) break;
        
        write(client_fd, buffer, n);
        printf("Echoed %zd bytes\n", n);
    }
    
    close(client_fd);
    close(server_fd);
    unlink(SOCKET_PATH);
    
    return 0;
}
```

```c
// echo_client.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCKET_PATH "/tmp/echo.sock"
#define BUFFER_SIZE 1024

int main() {
    int fd;
    struct sockaddr_un addr;
    char buffer[BUFFER_SIZE];
    
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, SOCKET_PATH);
    
    connect(fd, (struct sockaddr*)&addr, sizeof(addr));
    printf("Connected to server\n");
    
    strcpy(buffer, "Hello, shmipc!");
    write(fd, buffer, strlen(buffer));
    
    ssize_t n = read(fd, buffer, BUFFER_SIZE);
    buffer[n] = '\0';
    printf("Received: %s\n", buffer);
    
    close(fd);
    return 0;
}
```

编译和运行：
```bash
# 编译
gcc -o echo_server echo_server.c
gcc -o echo_client echo_client.c

# 运行服务端
LD_PRELOAD=./libshmipc.so ./echo_server

# 运行客户端（另一个终端）
LD_PRELOAD=./libshmipc.so ./echo_client
```

---

## 九、故障排查

### 9.1 验证是否生效

```bash
# 开启调试日志
SHMIPC_LOG=4 LD_PRELOAD=./libshmipc.so <your-program>

# 应该看到类似日志：
# [shmipc][INFO] shmipc-preload loaded (enabled: 1, log: 4)
# [shmipc][DEBUG] socket(1, 1, 0) = 3 [shmipc]
# [shmipc][DEBUG] bind(3, "/tmp/test.sock") [shmipc]
# [shmipc][DEBUG] listen(3, 5) [shmipc]
```

### 9.2 常见问题

#### 问题 1：程序无法启动

```
error while loading shared libraries: libshmipc.so: cannot open shared object file
```

解决方案：
```bash
# 方法 1：使用绝对路径
LD_PRELOAD=/path/to/libshmipc.so <your-program>

# 方法 2：安装到系统目录
sudo make install
```

#### 问题 2：没有加速效果

排查步骤：
```bash
# 1. 确认日志中显示 [shmipc]
SHMIPC_LOG=4 LD_PRELOAD=./libshmipc.so <your-program>

# 2. 确认是本地连接
# shmipc 仅对 UDS 和 TCP loopback 有效

# 3. 确认程序是动态链接
ldd $(which <your-program>)
# 应该看到 libc.so
```

#### 问题 3：共享内存不足

```
[shmipc][WARN] Failed to allocate shared memory
```

解决方案：
```bash
# 检查 /dev/shm 可用空间
df -h /dev/shm

# 清理旧的共享内存文件
rm -f /dev/shm/shmipc_*

# 调整缓冲区大小
SHMIPC_BUFFER_SIZE=16777216 LD_PRELOAD=./libshmipc.so <your-program>
```

### 9.3 性能对比测试

```bash
# 不使用 shmipc
SHMIPC_ENABLE=0 LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw

# 使用 shmipc
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw
```

---

## 附录

### A. 交付清单

只需交付一个文件：
```
libshmipc.so
```

### B. 支持的连接类型

| 连接类型 | 支持状态 | 说明 |
|----------|----------|------|
| Unix Domain Socket | ✅ | 自动检测并加速 |
| TCP Loopback (127.0.0.1) | ✅ | 自动检测并加速 |
| IPv6 Loopback (::1) | ✅ | 自动检测并加速 |
| 跨机器 TCP | ❌ | 自动回退到原始 socket |

### C. 性能参考

| 数据包大小 | shmipc 延迟 | UDS 延迟 | 提升 |
|------------|-------------|----------|------|
| 16KB | ~34μs | ~114μs | 3.3x |
| 64KB | ~97μs | ~217μs | 2.2x |
| 256KB | ~348μs | ~520μs | 1.5x |
| 1MB | ~1078μs | ~2626μs | 2.4x |
