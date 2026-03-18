# shmipc-transparent: 应用无感替换工具

## 目录

1. [概述](#一概述)
2. [技术方案](#二技术方案)
3. [架构设计](#三架构设计)
4. [安装与编译](#四安装与编译)
5. [使用指南](#五使用指南)
6. [配置说明](#六配置说明)
7. [示例程序](#七示例程序)
8. [兼容性与限制](#八兼容性与限制)
9. [性能对比](#九性能对比)
10. [故障排查](#十故障排查)
11. [高级用法](#十一高级用法)

---

## 一、概述

### 1.1 项目背景

在进程间通信（IPC）场景中，传统的 Unix Domain Socket（UDS）和 TCP Loopback 虽然使用广泛，但在高吞吐量和大包场景下存在性能瓶颈。shmipc 通过共享内存技术实现了零拷贝通信，可以显著提升性能。

然而，现有应用通常已经使用标准 socket API 进行开发，要使用 shmipc 需要修改应用代码，这带来了以下问题：

1. **侵入性**：需要修改现有代码，增加开发成本
2. **兼容性**：第三方库或工具无法直接使用 shmipc
3. **维护性**：需要维护两套代码（原生和 shmipc 版本）

### 1.2 解决方案

**shmipc-transparent** 是一个应用无感替换工具，通过 LD_PRELOAD 技术劫持标准 socket API，自动将符合条件的 IPC 连接转换为 shmipc 连接，实现：

- **零代码修改**：应用无需任何修改即可使用 shmipc
- **自动检测**：自动识别 UDS 和本地 TCP 连接
- **透明降级**：不支持的场景自动回退到原始 socket
- **统计监控**：提供运行时统计信息

### 1.3 适用场景

| 场景 | 适用性 | 说明 |
|------|--------|------|
| qperf 性能测试 | ✅ 高度适用 | UDS 性能测试可自动加速 |
| sockperf 性能测试 | ✅ 高度适用 | 本地回环测试可加速 |
| 数据库客户端 | ✅ 适用 | MySQL/Redis 本地连接 |
| 微服务通信 | ✅ 适用 | 同机服务间通信 |
| 消息队列 | ✅ 适用 | 本地消息队列通信 |
| 跨机器通信 | ❌ 不适用 | shmipc 仅支持同机通信 |

---

## 二、技术方案

### 2.1 方案对比

| 方案 | 优点 | 缺点 | 适用性 |
|------|------|------|--------|
| **LD_PRELOAD** | 用户态、无 root、兼容性好 | 仅动态链接程序 | ⭐⭐⭐⭐⭐ |
| eBPF | 内核态拦截、性能好 | 需要新内核、root | ⭐⭐⭐ |
| 内核模块 | 完全控制 | 风险高、维护难 | ⭐⭐ |
| 容器网络 | 隔离性好 | 需要容器环境 | ⭐⭐⭐ |

### 2.2 LD_PRELOAD 原理

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
│  │   libshmipc_preload.so           │    │   libc.so (原始库)               │  │
│  │   (预加载库)                      │    │                                  │  │
│  │                                  │    │   - socket()                     │  │
│  │   - socket()  ← 劫持             │    │   - bind()                       │  │
│  │   - bind()    ← 劫持             │    │   - listen()                     │  │
│  │   - listen()  ← 劫持             │    │   - accept()                     │  │
│  │   - accept()  ← 劫持             │    │   - send()                       │  │
│  │   - send()    ← 劫持             │    │   - recv()                       │  │
│  │   - recv()    ← 劫持             │    │   - close()                      │  │
│  │   - close()   ← 劫持             │    │                                  │  │
│  │                                  │    │                                  │  │
│  │   内部调用 dlsym(RTLD_NEXT, ...)  │───►│   通过 RTLD_NEXT 调用原始函数    │  │
│  │   获取原始函数指针                │    │                                  │  │
│  └──────────────────────────────────┘    └──────────────────────────────────┘  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 C 与 Go 互操作

由于 shmipc 核心库使用 Go 语言编写，而 LD_PRELOAD 需要使用 C 语言，因此需要解决 C 与 Go 的互操作问题：

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           C 与 Go 互操作架构                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                           应用程序 (C/C++/其他语言)                        │  │
│  └────────────────────────────────────────┬─────────────────────────────────┘  │
│                                           │                                     │
│                                           ▼ socket API 调用                     │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                     libshmipc_preload.so (C)                              │  │
│  │                                                                          │  │
│  │   - 拦截 socket API 调用                                                 │  │
│  │   - 判断是否应该使用 shmipc                                              │  │
│  │   - 调用 Go 层接口                                                       │  │
│  │                                                                          │  │
│  └────────────────────────────────────────┬─────────────────────────────────┘  │
│                                           │ CGO 调用                           │
│                                           ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                     libshmipc_go.so (Go, buildmode=c-shared)             │  │
│  │                                                                          │  │
│  │   - 导出 C 兼容接口 (//export FunctionName)                              │  │
│  │   - 封装 shmipc-go 库调用                                                │  │
│  │   - 管理 Session 和 Stream 生命周期                                      │  │
│  │                                                                          │  │
│  └────────────────────────────────────────┬─────────────────────────────────┘  │
│                                           │ Go 函数调用                        │
│                                           ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                           shmipc-go (核心库)                              │  │
│  │                                                                          │  │
│  │   - Session 管理                                                         │  │
│  │   - Stream 管理                                                          │  │
│  │   - 共享内存管理                                                          │  │
│  │   - 零拷贝数据传输                                                        │  │
│  │                                                                          │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**CGO 关键技术点：**

1. **导出 C 兼容函数**
```go
//export ShmipcOpenStream
func ShmipcOpenStream(fd C.int) C.int {
    // Go 实现
}
```

2. **C 类型转换**
```go
// C 字符串转 Go 字符串
goPath := C.GoString(path)

// Go 字节切片转 C 指针
buf := C.GoBytes(data, length)
```

3. **回调函数处理**
```go
// 使用 unsafe.Pointer 传递回调
//export ShmipcSetCallback
func ShmipcSetCallback(cb unsafe.Pointer) {
    // 保存回调指针
}
```

---

## 三、架构设计

### 3.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           shmipc-transparent 架构                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                              应用层                                        │  │
│  │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │  │
│  │   │   qperf     │  │  sockperf   │  │   Redis     │  │   MySQL     │    │  │
│  │   │   client    │  │   client    │  │   client    │  │   client    │    │  │
│  │   └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘    │  │
│  └────────────────────────────────────────┬─────────────────────────────────┘  │
│                                           │                                     │
│                                           ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                           拦截层 (LD_PRELOAD)                             │  │
│  │   ┌─────────────────────────────────────────────────────────────────┐    │  │
│  │   │                    libshmipc_preload.so                          │    │  │
│  │   │                                                                  │    │  │
│  │   │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐            │    │  │
│  │   │   │ socket()    │  │ bind()      │  │ listen()    │            │    │  │
│  │   │   │ connect()   │  │ accept()    │  │ send/recv() │            │    │  │
│  │   │   └─────────────┘  └─────────────┘  └─────────────┘            │    │  │
│  │   │                                                                  │    │  │
│  │   │   ┌─────────────────────────────────────────────────────────┐  │    │  │
│  │   │   │              连接判断逻辑                                 │  │    │  │
│  │   │   │                                                          │  │    │  │
│  │   │   │   - 是否为 UDS 连接？                                     │  │    │  │
│  │   │   │   - 是否为本地 TCP 连接？                                 │  │    │  │
│  │   │   │   - 是否在白名单中？                                      │  │    │  │
│  │   │   │   - 是否在黑名单中？                                      │  │    │  │
│  │   │   │                                                          │  │    │  │
│  │   │   └─────────────────────────────────────────────────────────┘  │    │  │
│  │   │                                                                  │    │  │
│  │   └─────────────────────────────────────────────────────────────────┘    │  │
│  └────────────────────────────────────────┬─────────────────────────────────┘  │
│                                           │                                     │
│                    ┌──────────────────────┴──────────────────────┐              │
│                    │                                              │              │
│                    ▼                                              ▼              │
│  ┌──────────────────────────────────┐    ┌──────────────────────────────────┐  │
│  │     libshmipc_go.so (Go)         │    │        libc.so (原始)            │  │
│  │                                  │    │                                  │  │
│  │   - ShmipcCreateClientSession()  │    │   - 原始 socket API              │  │
│  │   - ShmipcCreateServerSession()  │    │   - 用于不支持 shmipc 的场景     │  │
│  │   - ShmipcOpenStream()           │    │                                  │  │
│  │   - ShmipcAcceptStream()         │    │                                  │  │
│  │   - ShmipcWrite()                │    │                                  │  │
│  │   - ShmipcRead()                 │    │                                  │  │
│  │   - ShmipcCloseStream()          │    │                                  │  │
│  │   - ShmipcCloseSession()         │    │                                  │  │
│  │                                  │    │                                  │  │
│  └──────────────────────────────────┘    └──────────────────────────────────┘  │
│                    │                                                           │
│                    ▼                                                           │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                           shmipc-go 核心库                                │  │
│  │                                                                          │  │
│  │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │  │
│  │   │   Session   │  │   Stream    │  │   Buffer    │  │   Queue     │    │  │
│  │   │   Manager   │  │   Manager   │  │   Manager   │  │   Manager   │    │  │
│  │   └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘    │  │
│  │                                                                          │  │
│  │   ┌─────────────────────────────────────────────────────────────────┐    │  │
│  │   │                      共享内存 (Shared Memory)                    │    │  │
│  │   │                                                                  │    │  │
│  │   │   ┌─────────────────────┐    ┌─────────────────────┐            │    │  │
│  │   │   │   Buffer Region     │    │    Queue Region     │            │    │  │
│  │   │   │   (数据缓冲区)       │    │    (元数据队列)      │            │    │  │
│  │   │   └─────────────────────┘    └─────────────────────┘            │    │  │
│  │   │                                                                  │    │  │
│  │   └─────────────────────────────────────────────────────────────────┘    │  │
│  │                                                                          │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 文件结构

```
transparent-proxy/
├── include/
│   └── shmipc_transparent.h      # C 接口定义
├── src/
│   ├── shmipc_preload.c          # LD_PRELOAD 拦截实现
│   └── shmipc_bridge.go          # Go CGO 桥接层
├── lib/                          # 编译输出目录
│   ├── libshmipc_preload.so      # C 预加载库
│   ├── libshmipc_go.so           # Go 共享库
│   └── shmipc-run.sh             # 运行脚本
├── examples/
│   ├── echo_server.c             # 示例服务端
│   └── echo_client.c             # 示例客户端
├── scripts/
│   └── build.sh                  # 编译脚本
├── Makefile                      # Make 构建文件
└── README.md                     # 本文档
```

### 3.3 核心数据结构

```c
// 连接类型
typedef enum {
    CONN_TYPE_UNKNOWN = 0,      // 未知类型
    CONN_TYPE_SOCKET,           // 原始 socket
    CONN_TYPE_SHMIPC,           // shmipc 连接
} conn_type_t;

// 连接信息
typedef struct {
    int fd;                     // 文件描述符
    conn_type_t type;           // 连接类型
    int domain;                 // 协议族 (AF_UNIX, AF_INET)
    int type;                   // socket 类型 (SOCK_STREAM)
    int protocol;               // 协议
    int is_connected;           // 是否已连接
    int is_listening;           // 是否在监听
    char path[256];             // UDS 路径
    void *shmipc_handle;        // shmipc session 句柄
} connection_t;

// 配置
typedef struct {
    shmipc_mode_t mode;         // 工作模式
    shmipc_log_level_t log_level; // 日志级别
    uint32_t shm_buffer_size;   // 共享内存大小
    uint32_t queue_capacity;    // 队列容量
    char shm_path_prefix[256];  // 共享内存路径前缀
    int enable_fallback;        // 启用降级
    int enable_stats;           // 启用统计
} shmipc_config_t;

// 统计信息
typedef struct {
    uint64_t total_connections;     // 总连接数
    uint64_t shmipc_connections;    // shmipc 连接数
    uint64_t fallback_connections;  // 降级连接数
    uint64_t total_bytes_sent;      // 总发送字节数
    uint64_t total_bytes_recv;      // 总接收字节数
    uint64_t shmipc_bytes_sent;     // shmipc 发送字节数
    uint64_t shmipc_bytes_recv;     // shmipc 接收字节数
} shmipc_stats_t;
```

---

## 四、安装与编译

### 4.1 系统要求

- **操作系统**: Linux (内核 3.17+，支持 memfd_create)
- **架构**: x86_64 或 arm64
- **Go 版本**: 1.20+
- **GCC**: 7.0+
- **Glibc**: 2.17+

### 4.2 依赖安装

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y build-essential golang-go

# CentOS/RHEL
sudo yum groupinstall -y "Development Tools"
sudo yum install -y golang

# Arch Linux
sudo pacman -S base-devel go
```

### 4.3 编译

```bash
# 进入项目目录
cd transparent-proxy

# 使用 Make 编译
make all

# 或使用脚本编译
./scripts/build.sh
```

编译输出：
```
lib/
├── libshmipc_preload.so      # C 预加载库
├── libshmipc_go.so           # Go 共享库
└── shmipc-run.sh             # 运行脚本
```

### 4.4 安装（可选）

```bash
# 安装到系统目录
sudo make install

# 这将安装：
# - /usr/local/lib/libshmipc_preload.so
# - /usr/local/lib/libshmipc_go.so
# - /usr/local/include/shmipc_transparent.h
```

---

## 五、使用指南

### 5.1 基本用法

#### 方法一：使用运行脚本

```bash
# 使用 shmipc-run.sh 运行任意程序
./lib/shmipc-run.sh <your-program> [args...]

# 示例：运行 qperf
./lib/shmipc-run.sh qperf -t 10 -l 1 -m 64K 127.0.0.1 tcp_lat

# 示例：运行 sockperf
./lib/shmipc-run.sh sockperf sr --tcp -i 127.0.0.1 -p 11111
```

#### 方法二：设置环境变量

```bash
# 设置库路径
export LD_LIBRARY_PATH=/path/to/shmipc-transparent/lib:$LD_LIBRARY_PATH

# 设置预加载库
export LD_PRELOAD=/path/to/shmipc-transparent/lib/libshmipc_preload.so:/path/to/shmipc-transparent/lib/libshmipc_go.so

# 运行程序
<your-program>
```

#### 方法三：在程序启动命令中指定

```bash
LD_PRELOAD="./lib/libshmipc_preload.so:./lib/libshmipc_go.so" \
LD_LIBRARY_PATH="./lib" \
<your-program>
```

### 5.2 与常用工具集成

#### qperf

```bash
# 服务端
./lib/shmipc-run.sh qperf

# 客户端（测试 UDS）
./lib/shmipc-run.sh qperf -t 10 -l 1 -m 64K -oo 1 -vu 127.0.0.1 tcp_lat

# 客户端（测试 TCP loopback）
./lib/shmipc-run.sh qperf -t 10 -l 1 -m 64K 127.0.0.1 tcp_lat
```

#### sockperf

```bash
# 服务端
./lib/shmipc-run.sh sockperf sr --tcp -i 127.0.0.1 -p 11111

# 客户端
./lib/shmipc-run.sh sockperf pp --tcp -i 127.0.0.1 -p 11111 -m 64K -t 10
```

#### Redis 客户端

```bash
# 启动 Redis 服务端（使用 UDS）
./lib/shmipc-run.sh redis-server --unixsocket /tmp/redis.sock

# 使用 redis-benchmark 测试
./lib/shmipc-run.sh redis-benchmark -s /tmp/redis.sock -t set,get -n 100000
```

#### MySQL 客户端

```bash
# 启动 MySQL 服务端
./lib/shmipc-run.sh mysqld --socket=/tmp/mysql.sock

# 使用 mysql 客户端连接
./lib/shmipc-run.sh mysql -S /tmp/mysql.sock -u root -p
```

### 5.3 验证是否生效

```bash
# 设置调试日志级别
export SHMIPC_LOG_LEVEL=4

# 运行程序，查看日志输出
./lib/shmipc-run.sh <your-program>

# 如果看到以下日志，说明 shmipc 已生效：
# [shmipc-transparent][INFO] socket(...) = 3 [shmipc]
# [shmipc-transparent][DEBUG] connect(3, "/tmp/test.sock") [shmipc]
```

---

## 六、配置说明

### 6.1 环境变量

| 环境变量 | 说明 | 默认值 | 可选值 |
|----------|------|--------|--------|
| `SHMIPC_MODE` | 工作模式 | `auto` | `auto`, `force_shmipc`, `force_socket` |
| `SHMIPC_LOG_LEVEL` | 日志级别 | `1` | `0`(静默) - `4`(调试) |
| `SHMIPC_BUFFER_SIZE` | 共享内存缓冲区大小 | `33554432` (32MB) | 任意正整数 |
| `SHMIPC_PATH_PREFIX` | 共享内存路径前缀 | `/dev/shm/shmipc_transparent` | 任意路径 |
| `SHMIPC_WHITELIST` | 路径白名单 | 空 | 逗号分隔的路径列表 |
| `SHMIPC_BLACKLIST` | 路径黑名单 | 空 | 逗号分隔的路径列表 |

### 6.2 工作模式

#### auto（自动模式）

自动检测连接类型，符合条件的连接自动使用 shmipc：

- UDS 连接：自动使用 shmipc
- TCP loopback (127.0.0.1 / ::1)：自动使用 shmipc
- 其他连接：使用原始 socket

```bash
export SHMIPC_MODE=auto
```

#### force_shmipc（强制 shmipc）

强制所有连接使用 shmipc（不推荐，可能导致不兼容问题）：

```bash
export SHMIPC_MODE=force_shmipc
```

#### force_socket（强制原始 socket）

禁用 shmipc，所有连接使用原始 socket：

```bash
export SHMIPC_MODE=force_socket
```

### 6.3 日志级别

| 级别 | 说明 |
|------|------|
| 0 | 静默模式，不输出任何日志 |
| 1 | 仅输出错误日志 |
| 2 | 输出警告及以上级别日志 |
| 3 | 输出信息及以上级别日志 |
| 4 | 输出所有日志（调试模式） |

### 6.4 白名单/黑名单

```bash
# 仅对特定路径启用 shmipc
export SHMIPC_WHITELIST="/tmp/app1.sock,/tmp/app2.sock"

# 排除特定路径
export SHMIPC_BLACKLIST="/tmp/no_accelerate.sock"
```

---

## 七、示例程序

### 7.1 Echo 服务端/客户端

项目包含一个简单的 echo 服务端和客户端示例：

```bash
# 编译示例
make examples

# 终端 1：启动服务端
./lib/shmipc-run.sh ./build/echo_server

# 终端 2：启动客户端
./lib/shmipc-run.sh ./build/echo_client 10
```

### 7.2 性能对比测试

```bash
# 创建测试脚本
cat > benchmark.sh << 'EOF'
#!/bin/bash

SOCKET_PATH="/tmp/bench.sock"
MSG_SIZE=65536  # 64KB
COUNT=1000

echo "=== shmipc-transparent Benchmark ==="
echo "Message Size: $MSG_SIZE bytes"
echo "Count: $COUNT"
echo ""

# 启动服务端
./lib/shmipc-run.sh ./build/echo_server &
SERVER_PID=$!
sleep 1

# 测试
echo "Running benchmark..."
time ./lib/shmipc-run.sh ./build/echo_client $COUNT

# 清理
kill $SERVER_PID
EOF

chmod +x benchmark.sh
./benchmark.sh
```

### 7.3 统计信息查看

```c
// 在程序中获取统计信息
#include <shmipc_transparent.h>

void print_stats() {
    shmipc_stats_t stats;
    if (shmipc_transparent_get_stats(&stats) == 0) {
        printf("Total Connections: %lu\n", stats.total_connections);
        printf("Shmipc Connections: %lu\n", stats.shmipc_connections);
        printf("Shmipc Bytes Sent: %lu\n", stats.shmipc_bytes_sent);
        printf("Shmipc Bytes Recv: %lu\n", stats.shmipc_bytes_recv);
    }
}
```

---

## 八、兼容性与限制

### 8.1 支持的场景

| 场景 | 支持状态 | 说明 |
|------|----------|------|
| Unix Domain Socket (SOCK_STREAM) | ✅ 完全支持 | 主要优化目标 |
| TCP Loopback (127.0.0.1) | ✅ 支持 | 自动检测 |
| TCP Loopback (::1) | ✅ 支持 | IPv6 本地回环 |
| 非阻塞 socket | ✅ 支持 | 内部处理 |
| 多线程 | ✅ 支持 | 线程安全 |
| 多进程 | ✅ 支持 | fork 后可用 |

### 8.2 不支持的场景

| 场景 | 原因 | 处理方式 |
|------|------|----------|
| 跨机器通信 | shmipc 仅支持同机 | 自动降级到原始 socket |
| UDP socket | shmipc 仅支持流式传输 | 自动降级 |
| 原始 socket (SOCK_RAW) | 不适用 | 自动降级 |
| 静态链接程序 | LD_PRELOAD 不生效 | 需要重新编译 |
| 非 Linux 系统 | 依赖 Linux 特性 | 不支持 |

### 8.3 已知限制

1. **静态链接程序**：LD_PRELOAD 无法劫持静态链接的程序
   - 解决方案：使用动态链接编译，或使用 eBPF 方案

2. **setuid/setgid 程序**：出于安全考虑，LD_PRELOAD 对这类程序无效
   - 解决方案：以 root 权限运行，或使用其他方案

3. **直接系统调用**：程序如果直接使用 syscall() 而非 libc，无法被劫持
   - 解决方案：修改程序使用 libc 接口

4. **内存压力**：大量连接时共享内存占用较大
   - 解决方案：调整 `SHMIPC_BUFFER_SIZE`

### 8.4 兼容性检查

```bash
# 检查程序是否动态链接
ldd /path/to/your/program

# 如果输出包含 libc.so，则可以劫持
# 如果输出 "not a dynamic executable"，则无法劫持

# 检查程序是否使用 setuid
ls -la /path/to/your/program
# 如果权限位包含 's'（如 -rwsr-xr-x），则 LD_PRELOAD 可能无效
```

---

## 九、性能对比

### 9.1 理论性能提升

| 数据包大小 | shmipc 延迟 | UDS 延迟 | 提升比例 |
|------------|-------------|----------|----------|
| 64B | ~7.7μs | ~5.5μs | 相当 |
| 1KB | ~11.5μs | ~10.8μs | 相当 |
| 16KB | ~34.2μs | ~114.3μs | **3.3x** |
| 64KB | ~97.1μs | ~216.5μs | **2.2x** |
| 256KB | ~347.6μs | ~520.2μs | **1.5x** |
| 1MB | ~1078.2μs | ~2626.4μs | **2.4x** |
| 4MB | ~4163.4μs | ~5893.3μs | **1.4x** |

### 9.2 实际测试

```bash
# 测试不同包大小的吞吐量
for size in 64 512 1024 4096 16384 65536; do
    echo "Testing with message size: $size bytes"
    
    # 启动服务端
    ./lib/shmipc-run.sh ./build/echo_server &
    SERVER_PID=$!
    sleep 1
    
    # 测试
    time ./lib/shmipc-run.sh ./build/echo_client 1000
    
    # 清理
    kill $SERVER_PID
    sleep 1
done
```

### 9.3 性能优化建议

1. **调整缓冲区大小**
   ```bash
   # 大包场景增加缓冲区
   export SHMIPC_BUFFER_SIZE=134217728  # 128MB
   ```

2. **调整队列容量**
   ```bash
   # 高并发场景增加队列
   # 需要修改源码中的 queue_capacity
   ```

3. **选择合适的日志级别**
   ```bash
   # 生产环境使用静默模式
   export SHMIPC_LOG_LEVEL=0
   ```

---

## 十、故障排查

### 10.1 常见问题

#### 问题 1：程序无法启动

**症状**：
```
error while loading shared libraries: libshmipc_go.so: cannot open shared object file
```

**解决方案**：
```bash
# 检查库路径
export LD_LIBRARY_PATH=/path/to/lib:$LD_LIBRARY_PATH

# 或安装到系统目录
sudo make install
sudo ldconfig
```

#### 问题 2：没有加速效果

**症状**：性能没有明显提升

**排查步骤**：
```bash
# 1. 检查日志确认 shmipc 是否生效
export SHMIPC_LOG_LEVEL=4
./lib/shmipc-run.sh <your-program>

# 2. 确认连接类型
# 应该看到类似日志：
# [shmipc-transparent][DEBUG] socket(...) = 3 [shmipc]

# 3. 检查是否为本地连接
# shmipc 仅对本地连接有效
```

#### 问题 3：程序崩溃

**症状**：程序运行时崩溃

**排查步骤**：
```bash
# 1. 检查是否为静态链接程序
ldd <your-program>

# 2. 使用 gdb 调试
LD_PRELOAD=./lib/libshmipc_preload.so:./lib/libshmipc_go.so \
gdb <your-program>

# 3. 检查日志
export SHMIPC_LOG_LEVEL=4
```

#### 问题 4：共享内存不足

**症状**：
```
[shmipc-transparent][ERROR] Failed to allocate shared memory
```

**解决方案**：
```bash
# 检查 /dev/shm 可用空间
df -h /dev/shm

# 清理旧的共享内存文件
rm -f /dev/shm/shmipc_*

# 调整缓冲区大小
export SHMIPC_BUFFER_SIZE=16777216  # 16MB
```

### 10.2 调试技巧

```bash
# 1. 使用 strace 跟踪系统调用
strace -e trace=socket,bind,listen,accept,connect,send,recv \
    ./lib/shmipc-run.sh <your-program>

# 2. 使用 ltrace 跟踪库调用
ltrace -e '*socket*' \
    ./lib/shmipc-run.sh <your-program>

# 3. 查看共享内存状态
ls -la /dev/shm/shmipc_*
ipcs -m

# 4. 查看进程内存映射
pmap -x <pid> | grep shm
```

### 10.3 日志分析

```bash
# 启用调试日志
export SHMIPC_LOG_LEVEL=4

# 重定向日志到文件
./lib/shmipc-run.sh <your-program> 2>shmipc.log

# 分析日志
grep -E "\[shmipc-transparent\]" shmipc.log
grep -E "ERROR|WARN" shmipc.log
```

---

## 十一、高级用法

### 11.1 与容器集成

```dockerfile
# Dockerfile
FROM ubuntu:22.04

# 安装依赖
RUN apt-get update && apt-get install -y \
    build-essential \
    golang-go \
    && rm -rf /var/lib/apt/lists/*

# 复制 shmipc-transparent
COPY transparent-proxy /opt/shmipc-transparent

# 设置环境变量
ENV LD_LIBRARY_PATH=/opt/shmipc-transparent/lib:$LD_LIBRARY_PATH
ENV LD_PRELOAD=/opt/shmipc-transparent/lib/libshmipc_preload.so:/opt/shmipc-transparent/lib/libshmipc_go.so

# 运行应用
CMD ["/opt/shmipc-transparent/lib/shmipc-run.sh", "your-app"]
```

### 11.2 与 systemd 服务集成

```ini
# /etc/systemd/system/your-service.service
[Unit]
Description=Your Service with shmipc

[Service]
Type=simple
Environment="LD_LIBRARY_PATH=/opt/shmipc-transparent/lib"
Environment="LD_PRELOAD=/opt/shmipc-transparent/lib/libshmipc_preload.so:/opt/shmipc-transparent/lib/libshmipc_go.so"
Environment="SHMIPC_LOG_LEVEL=1"
ExecStart=/usr/bin/your-service
Restart=always

[Install]
WantedBy=multi-user.target
```

### 11.3 动态加载

```c
#include <dlfcn.h>

int main() {
    // 动态加载 shmipc 库
    void *handle = dlopen("libshmipc_preload.so", RTLD_LAZY);
    if (handle) {
        // 库加载成功，shmipc 已启用
        printf("shmipc-transparent loaded\n");
    }
    
    // 正常程序逻辑
    // ...
    
    if (handle) {
        dlclose(handle);
    }
    return 0;
}
```

### 11.4 编程接口

```c
#include <shmipc_transparent.h>

int main() {
    // 初始化
    shmipc_config_t config = {
        .mode = SHMIPC_MODE_AUTO,
        .log_level = SHMIPC_LOG_INFO,
        .shm_buffer_size = 32 * 1024 * 1024,
        .queue_capacity = 8192,
        .enable_fallback = 1,
        .enable_stats = 1,
    };
    shmipc_transparent_init(&config);
    
    // 正常程序逻辑
    // ...
    
    // 获取统计信息
    shmipc_stats_t stats;
    shmipc_transparent_get_stats(&stats);
    printf("Shmipc connections: %lu\n", stats.shmipc_connections);
    
    // 清理
    shmipc_transparent_cleanup();
    return 0;
}
```

---

## 附录

### A. API 参考

```c
// 初始化
int shmipc_transparent_init(const shmipc_config_t *config);

// 获取配置
int shmipc_transparent_get_config(shmipc_config_t *config);

// 获取统计
int shmipc_transparent_get_stats(shmipc_stats_t *stats);

// 重置统计
int shmipc_transparent_reset_stats(void);

// 清理
void shmipc_transparent_cleanup(void);

// 判断是否应该拦截
int shmipc_should_intercept(int domain, int type, int protocol);

// 判断是否为本地 UDS
int shmipc_is_local_uds(const char *path);

// 判断是否为本地 TCP
int shmipc_is_local_tcp(const struct sockaddr *addr, socklen_t addrlen);
```

### B. 环境变量完整列表

| 变量 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `SHMIPC_MODE` | string | `auto` | 工作模式 |
| `SHMIPC_LOG_LEVEL` | int | `1` | 日志级别 |
| `SHMIPC_BUFFER_SIZE` | int | `33554432` | 缓冲区大小 |
| `SHMIPC_PATH_PREFIX` | string | `/dev/shm/shmipc_transparent` | 路径前缀 |
| `SHMIPC_WHITELIST` | string | 空 | 白名单路径 |
| `SHMIPC_BLACKLIST` | string | 空 | 黑名单路径 |
| `SHMIPC_QUEUE_CAP` | int | `8192` | 队列容量 |
| `SHMIPC_ENABLE_FALLBACK` | int | `1` | 启用降级 |
| `SHMIPC_ENABLE_STATS` | int | `1` | 启用统计 |

### C. 参考资料

- [shmipc-go GitHub](https://github.com/cloudwego/shmipc-go)
- [LD_PRELOAD 原理](https://man7.org/linux/man-pages/man8/ld.so.8.html)
- [CGO 文档](https://golang.org/cmd/cgo/)
- [Unix Domain Socket](https://man7.org/linux/man-pages/man7/unix.7.html)
