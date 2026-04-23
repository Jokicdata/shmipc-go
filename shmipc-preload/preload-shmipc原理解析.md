# preload-shmipc 原理解析

本文档详细讲解 shmipc-preload 的代码原理、函数调用关系，并对比原生 Loopback 和 shmipc 拦截后的数据路径。

---

## 1. 整体架构

shmipc-preload 由两个核心文件组成：

| 文件 | 语言 | 职责 |
|------|------|------|
| `shmipc_preload.c` | C | 劫持 socket API，管理 fd 状态，决定走 shmipc 还是原始 socket |
| `shmipc_bridge.go` | Go | CGO 桥接层，调用 shmipc-go 核心库，管理 Session/Stream |

```
┌────────────────────────────────────────────────────────────────────┐
│                          应用层 (qperf)                             │
│         write(fd, buf, len) / read(fd, buf, len)                  │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ LD_PRELOAD 劫持
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│                    C 劫持层 (shmipc_preload.c)                      │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │ g_fds[4096]  全局 fd 表                                      │  │
│  │   └─ fd_info_t { conn_type, stream_id, domain, type, ... }  │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  write(fd, buf, len) {                                            │
│      info = get_fd_info(fd);                                       │
│      if (info->conn_type == SHMIPC && info->stream_id >= 0)       │
│          return ShmipcWrite(info->stream_id, buf, len);  ← CGO    │
│      else                                                          │
│          return real_write(fd, buf, len);  ← 原始 socket          │
│  }                                                                 │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ CGO 调用
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│                    Go 桥接层 (shmipc_bridge.go)                     │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │ sessions map[int]*Session   // fd → Session                  │  │
│  │ streams  map[int]*Stream    // streamID → Stream             │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ShmipcWrite(streamID, data, length) {                            │
│      stream = streams[streamID];                                   │
│      buf = C.GoBytes(data, length);    // 拷贝1: C→Go堆          │
│      writer.WriteBytes(buf);            // 拷贝2: Go堆→共享内存   │
│      stream.Flush();                    // 通知对端               │
│  }                                                                 │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│                      shmipc-go 核心库                               │
│  共享内存 mmap (32MB)  │  无锁队列 Queue  │  epoll 通知            │
└────────────────────────────────────────────────────────────────────┘
```

---

## 2. C 劫持层代码详解

### 2.1 全局状态和数据结构

```c
/* ========== 配置常量 ========== */
#define MAX_FDS 4096           // 最大 fd 数量
#define MAX_PATH 256           // Unix socket 路径最大长度
#define SHM_BUFFER_SIZE (32 * 1024 * 1024)  // 共享内存大小 32MB
#define QUEUE_CAPACITY 8192    // 队列容量

/* ========== 连接类型 ========== */
#define CONN_TYPE_SOCKET 0     // 普通 socket 连接
#define CONN_TYPE_SHMIPC 1     // shmipc 连接

/* ========== 全局状态 ========== */
static int g_log_level = LOG_ERROR;    // 日志级别
static int g_initialized = 0;          // 是否已初始化
static int g_shmipc_enabled = 1;       // shmipc 是否启用

/* ========== 全局文件描述符表 ========== */
static fd_info_t g_fds[MAX_FDS];       // 下标即 fd 号
```

**fd_info_t 结构体**：每个 fd 一条记录，记录该 fd 的状态信息。

```c
typedef struct {
    int fd;              // 文件描述符
    int domain;          // AF_INET / AF_UNIX
    int type;            // SOCK_STREAM 等
    int protocol;        // 协议
    int conn_type;       // CONN_TYPE_SOCKET(0) 或 CONN_TYPE_SHMIPC(1)
    int is_connected;    // 是否已连接
    int is_listening;    // 是否在监听
    int is_server;       // 是否为服务端
    int stream_id;       // shmipc stream ID（-1 表示未分配）
    char path[MAX_PATH]; // Unix socket 路径
    pthread_mutex_t lock;
} fd_info_t;
```

**关键字段说明**：
- `conn_type`：决定该 fd 走 shmipc 还是原始 socket
- `stream_id`：shmipc 的 stream 标识，>=0 表示已建立 shmipc 连接
- `is_server`：标记是服务端还是客户端，用于判断是否创建 Server Session

### 2.2 原始函数指针

```c
/* ========== 原始函数指针 ========== */
static int (*real_socket)(int, int, int);
static int (*real_bind)(int, const struct sockaddr *, socklen_t);
static int (*real_listen)(int, int);
static int (*real_accept)(int, struct sockaddr *, socklen_t *);
static int (*real_connect)(int, const struct sockaddr *, socklen_t);
static ssize_t (*real_send)(int, const void *, size_t, int);
static ssize_t (*real_recv)(int, void *, size_t, int);
static ssize_t (*real_write)(int, const void *, size_t);
static ssize_t (*real_read)(int, void *, size_t);
// ... 更多函数指针
```

**作用**：保存原始 libc 函数的地址，用于：
1. 在劫持函数中调用原始实现（透传或回退）
2. 在 connect/accept 等阶段完成真实的 TCP 连接

### 2.3 初始化函数

```c
/* ========== 初始化原始函数指针 ========== */
static void init_real_funcs(void) {
    if (real_socket != NULL) return;  // 防止重复初始化
    
    real_socket = dlsym(RTLD_NEXT, "socket");
    real_bind = dlsym(RTLD_NEXT, "bind");
    real_listen = dlsym(RTLD_NEXT, "listen");
    // ... 获取所有原始函数
}
```

**dlsym(RTLD_NEXT, "socket")** 的作用：
- `RTLD_NEXT` 表示在动态链接器的搜索顺序中查找下一个符号
- 因为我们的库通过 LD_PRELOAD 加载，所以 "socket" 符号被我们的函数覆盖
- `RTLD_NEXT` 会跳过我们的覆盖，找到原始 libc 的 socket 函数

### 2.4 库初始化（constructor）

```c
/* ========== 库初始化 ========== */
__attribute__((constructor))
static void lib_init(void) {
    init_real_funcs();                    // 1. 获取原始函数指针
    
    char *log_env = getenv("SHMIPC_LOG"); // 2. 读取环境变量
    if (log_env) {
        g_log_level = atoi(log_env);
    }
    
    char *enable_env = getenv("SHMIPC_ENABLE");
    if (enable_env && strcmp(enable_env, "0") == 0) {
        g_shmipc_enabled = 0;             // 禁用 shmipc
    }
    
    memset(g_fds, 0, sizeof(g_fds));      // 3. 初始化全局状态
    memset(&g_stats, 0, sizeof(g_stats));
    
    int ret = ShmipcInit();               // 4. 初始化 Go 侧
    if (ret != 0) {
        log_msg(LOG_WARN, "ShmipcInit failed: %d, fallback to socket", ret);
        g_shmipc_enabled = 0;             // 初始化失败，全局禁用
    }
    
    g_initialized = 1;
    log_msg(LOG_INFO, "shmipc-preload loaded (enabled: %d, log: %d)", 
            g_shmipc_enabled, g_log_level);
}
```

**`__attribute__((constructor))`** 的作用：
- 让 `lib_init` 在共享库加载时自动执行
- 在 main() 之前执行
- 对应的 `__attribute__((destructor))` 在库卸载时执行

### 2.5 socket() 劫持

```c
/* ========== socket() 劫持 ========== */
int socket(int domain, int type, int protocol) {
    init_real_funcs();
    
    int fd = real_socket(domain, type, protocol);  // 调用原始 socket
    if (fd < 0) return fd;
    
    init_fd_info(fd, domain, type, protocol);      // 初始化 fd 信息
    
    fd_info_t *info = get_fd_info(fd);
    if (info && should_use_shmipc(domain, type)) { // 判断是否应该用 shmipc
        info->conn_type = CONN_TYPE_SHMIPC;        // 标记为 shmipc 候选
        log_msg(LOG_DEBUG, "socket(%d, %d, %d) = %d [shmipc]", 
               domain, type, protocol, fd);
    } else {
        log_msg(LOG_DEBUG, "socket(%d, %d, %d) = %d [socket]", 
               domain, type, protocol, fd);
    }
    
    __sync_fetch_and_add(&g_stats.total_connections, 1);
    return fd;
}
```

**should_use_shmipc() 判断逻辑**：

```c
static int should_use_shmipc(int domain, int type) {
    if (!g_shmipc_enabled) return 0;
    
    if (domain == AF_UNIX) return 1;  // Unix socket 直接用 shmipc
    
    if ((domain == AF_INET || domain == AF_INET6) && type == SOCK_STREAM) {
        return 1;  // TCP socket 标记为候选，后续 connect 时再判断是否本地
    }
    
    return 0;
}
```

**关键点**：
- socket() 只是**标记** fd 为 shmipc 候选，不立即创建 shmipc 连接
- 真正的 shmipc 连接在 connect() 或 accept() 时建立

### 2.6 connect() 劫持

```c
/* ========== connect() 劫持 ========== */
int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    int use_shmipc = 0;
    
    // 判断是否使用 shmipc
    if (info && info->conn_type == CONN_TYPE_SHMIPC) {
        if (addr && addr->sa_family == AF_UNIX) {
            struct sockaddr_un *un = (struct sockaddr_un *)addr;
            strncpy(info->path, un->sun_path, MAX_PATH - 1);
            use_shmipc = 1;                              // Unix socket
        } else if (addr && is_loopback_addr(addr, addrlen)) {
            use_shmipc = 1;                              // 本地回环地址
        }
    }
    
    // 先完成真实的 TCP 连接
    int ret = real_connect(sockfd, addr, addrlen);
    
    if (ret == 0 && info) {
        info->is_connected = 1;
        
        if (use_shmipc) {
            // 创建 shmipc 客户端 Session
            int shmipc_ret = ShmipcCreateClientSession(sockfd, info->path);
            if (shmipc_ret == 0) {
                // 打开 shmipc Stream
                int stream_id = ShmipcOpenStream(sockfd);
                if (stream_id >= 0) {
                    info->stream_id = stream_id;        // 记录 stream_id
                    log_msg(LOG_DEBUG, "connect(%d, \"%s\") stream=%d [shmipc]", 
                           sockfd, info->path, stream_id);
                }
            } else {
                log_msg(LOG_WARN, "ShmipcCreateClientSession failed: %d", shmipc_ret);
            }
            
            __sync_fetch_and_add(&g_stats.shmipc_connections, 1);
        } else {
            __sync_fetch_and_add(&g_stats.socket_connections, 1);
        }
    }
    
    return ret;
}
```

**is_loopback_addr() 判断本地回环**：

```c
static int is_loopback_addr(const struct sockaddr *addr, socklen_t addrlen) {
    if (addr == NULL) return 0;
    
    if (addr->sa_family == AF_INET) {
        struct sockaddr_in *in = (struct sockaddr_in *)addr;
        uint32_t ip = ntohl(in->sin_addr.s_addr);
        return (ip == 0x7f000001);  // 127.0.0.1
    }
    
    if (addr->sa_family == AF_INET6) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)addr;
        static const unsigned char loopback[16] = {
            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1
        };
        return (memcmp(in6->sin6_addr.s6_addr, loopback, 16) == 0);  // ::1
    }
    
    return 0;
}
```

**关键点**：
1. **先调用 real_connect()**：完成真实的 TCP 连接
2. **再创建 shmipc Session**：在 TCP 连接基础上建立共享内存通信
3. **shmipc 利用 TCP 连接**：用于传递 memfd 和同步通知

### 2.7 accept() 劫持

```c
/* ========== accept() 劫持 ========== */
int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    init_real_funcs();
    
    fd_info_t *server_info = get_fd_info(sockfd);
    
    // 调用原始 accept 获取客户端 fd
    int client_fd = real_accept(sockfd, addr, addrlen);
    if (client_fd < 0) return client_fd;
    
    if (server_info && server_info->conn_type == CONN_TYPE_SHMIPC) {
        // 初始化客户端 fd 信息
        init_fd_info(client_fd, server_info->domain, server_info->type, server_info->protocol);
        
        fd_info_t *client_info = get_fd_info(client_fd);
        if (client_info) {
            client_info->conn_type = CONN_TYPE_SHMIPC;
            client_info->is_connected = 1;
            client_info->is_server = 0;
            strncpy(client_info->path, server_info->path, MAX_PATH - 1);
            
            // 接受 shmipc Stream
            int stream_id = ShmipcAcceptStream(sockfd);
            if (stream_id >= 0) {
                client_info->stream_id = stream_id;
                log_msg(LOG_DEBUG, "accept(%d) = %d, stream=%d [shmipc]", 
                       sockfd, client_fd, stream_id);
            }
            
            __sync_fetch_and_add(&g_stats.shmipc_connections, 1);
        }
    } else {
        __sync_fetch_and_add(&g_stats.socket_connections, 1);
    }
    
    return client_fd;
}
```

**关键点**：
- 服务端在 accept() 时创建 shmipc Stream
- `ShmipcAcceptStream()` 会阻塞等待客户端的 `ShmipcOpenStream()`

### 2.8 write() 劫持

```c
/* ========== write() 劫持 ========== */
ssize_t write(int fd, const void *buf, size_t count) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(fd);
    
    // 判断是否走 shmipc
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        // 调用 Go 侧的 ShmipcWrite
        long ret = ShmipcWrite(info->stream_id, buf, (long)count);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_sent, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
            return (ssize_t)ret;
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

**判断条件**：
- `info->conn_type == CONN_TYPE_SHMIPC`：fd 被标记为 shmipc 连接
- `info->stream_id >= 0`：shmipc Stream 已建立

**回退机制**：
- 如果 `ShmipcWrite` 返回 <= 0，自动回退到 `real_write`

### 2.9 read() 劫持

```c
/* ========== read() 劫持 ========== */
ssize_t read(int fd, void *buf, size_t count) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(fd);
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        long ret = ShmipcRead(info->stream_id, buf, (long)count);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_recv, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
            return (ssize_t)ret;
        }
    }
    
    ssize_t ret = real_read(fd, buf, count);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
    }
    return ret;
}
```

### 2.10 send()/recv() 劫持

```c
/* ========== send() 劫持 ========== */
ssize_t send(int sockfd, const void *buf, size_t len, int flags) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        long ret = ShmipcWrite(info->stream_id, buf, (long)len);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_sent, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
            return (ssize_t)ret;
        }
    }
    
    ssize_t ret = real_send(sockfd, buf, len, flags);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
    }
    return ret;
}

/* ========== recv() 劫持 ========== */
ssize_t recv(int sockfd, void *buf, size_t len, int flags) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        long ret = ShmipcRead(info->stream_id, buf, (long)len);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_recv, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
            return (ssize_t)ret;
        }
    }
    
    ssize_t ret = real_recv(sockfd, buf, len, flags);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
    }
    return ret;
}
```

**注意**：`send()` 和 `write()` 的区别是 `send()` 多一个 `flags` 参数，但在 shmipc 中忽略 flags，直接调用 `ShmipcWrite`。

### 2.11 透传函数

以下函数**不劫持**，直接透传到原始实现：

```c
/* ========== 其他函数直接透传 ========== */
int shutdown(int sockfd, int how) {
    init_real_funcs();
    return real_shutdown(sockfd, how);
}

int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen) {
    init_real_funcs();
    return real_getsockopt(sockfd, level, optname, optval, optlen);
}

int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen) {
    init_real_funcs();
    return real_setsockopt(sockfd, level, optname, optval, optlen);
}

int fcntl(int fd, int cmd, ...) { /* ... */ }
int dup(int oldfd) { /* ... */ }
int dup2(int oldfd, int newfd) { /* ... */ }

ssize_t sendto(int sockfd, const void *buf, size_t len, int flags,
               const struct sockaddr *dest_addr, socklen_t addrlen) {
    init_real_funcs();
    return real_sendto(sockfd, buf, len, flags, dest_addr, addrlen);
}

ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags,
                 struct sockaddr *src_addr, socklen_t *addrlen) {
    init_real_funcs();
    return real_recvfrom(sockfd, buf, len, flags, src_addr, addrlen);
}

ssize_t writev(int fd, const struct iovec *iov, int iovcnt) {
    init_real_funcs();
    return real_writev(fd, iov, iovcnt);
}

ssize_t readv(int fd, const struct iovec *iov, int iovcnt) {
    init_real_funcs();
    return real_readv(fd, iov, iovcnt);
}
```

**重要**：`writev()` 和 `readv()` **不劫持**，如果应用使用这两个函数，数据会走原始 socket，即使 fd 标记为 SHMIPC。

---

## 3. Go 桥接层代码详解

### 3.1 全局状态

```go
var (
    mu       sync.RWMutex
    sessions = make(map[int]*shmipc.Session)  // fd → Session
    streams  = make(map[int]*shmipc.Stream)   // streamID → Stream
    config   *shmipc.Config
)
```

**两个映射表**：
- `sessions`：fd 到 shmipc Session 的映射
- `streams`：streamID 到 shmipc Stream 的映射

### 3.2 ShmipcCreateClientSession()

```go
//export ShmipcCreateClientSession
func ShmipcCreateClientSession(fd C.int, path *C.char) C.int {
    goPath := C.GoString(path)

    mu.Lock()
    defer mu.Unlock()

    if _, exists := sessions[int(fd)]; exists {
        return C.int(-1)  // 已存在
    }

    // 1. 用 fd 创建 Go file 对象
    file := os.NewFile(uintptr(fd), "unix")
    if file == nil {
        return C.int(-2)
    }

    // 2. 从 file 获取 net.Conn
    conn, err := net.FileConn(file)
    if err != nil {
        return C.int(-3)
    }

    // 3. 创建 shmipc 客户端 Session
    shmConfig := getShmipcConfig(goPath + "_client")
    session, err := shmipc.Client(conn, shmConfig)
    if err != nil {
        conn.Close()
        return C.int(-4)
    }

    // 4. 保存到 sessions 映射表
    sessions[int(fd)] = session
    return C.int(0)
}
```

**shmipc.Client() 内部做了什么**：
1. `memfd_create()` 创建匿名共享内存文件
2. `ftruncate()` 设置大小（32MB）
3. `mmap()` 映射到进程地址空间
4. 通过 Unix socket 将 memfd 传递给对端

### 3.3 ShmipcOpenStream()

```go
//export ShmipcOpenStream
func ShmipcOpenStream(fd C.int) C.int {
    mu.Lock()
    defer mu.Unlock()

    session, exists := sessions[int(fd)]
    if !exists {
        return C.int(-1)
    }

    // 在 Session 上打开一个 Stream
    stream, err := session.OpenStream()
    if err != nil {
        return C.int(-2)
    }

    streamID := int(stream.StreamID())
    streams[streamID] = stream
    return C.int(streamID)
}
```

**Stream 的作用**：
- 一个 Session 可以有多个 Stream
- 每个 Stream 独立收发数据
- StreamID 用于标识具体的 Stream

### 3.4 ShmipcWrite() — 数据写入

```go
//export ShmipcWrite
func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()

    if !exists {
        return C.long(-1)
    }

    // ★★★ 第1次拷贝：C 内存 → Go 堆 ★★★
    buf := C.GoBytes(data, C.int(length))
    // C.GoBytes 内部：
    //   1. 在 Go 堆分配 length 字节
    //   2. 调用 runtime.memmove 拷贝数据

    // ★★★ 第2次拷贝：Go 堆 → 共享内存 ★★★
    writer := stream.BufferWriter()
    n, err := writer.WriteBytes(buf)
    // WriteBytes 内部：
    //   遍历 linkedBuffer 的 bufferSlice
    //   对每个 slice 调用 copy(slice.buf, data)

    if err != nil {
        return C.long(-2)
    }

    // 通知对端
    err = stream.Flush(false)
    if err != nil {
        return C.long(-3)
    }

    return C.long(n)
}
```

**两次拷贝**：
1. `C.GoBytes(data, length)`：C 内存 → Go 堆
2. `writer.WriteBytes(buf)`：Go 堆 → 共享内存

### 3.5 ShmipcRead() — 数据读取

```go
//export ShmipcRead
func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) C.long {
    mu.RLock()
    stream, exists := streams[int(streamID)]
    mu.RUnlock()

    if !exists {
        return C.long(-1)
    }

    reader := stream.BufferReader()
    
    // 从共享内存读取数据
    buf, err := reader.ReadBytes(int(length))
    // ReadBytes 快速路径：
    //   直接返回共享内存的子切片（零拷贝）
    // ReadBytes 慢速路径：
    //   跨切片时需要 append 拷贝

    if err != nil {
        return C.long(-2)
    }

    // ★★★ 拷贝：共享内存 → C 内存 ★★★
    copy((*[1 << 30]byte)(data)[:len(buf)], buf)

    stream.ReleaseReadAndReuse()
    return C.long(len(buf))
}
```

**读方向只有一次实际拷贝**：
- `copy(data[:], buf)`：共享内存 → C 内存
- `ReadBytes` 快速路径下 buf 直接指向共享内存，不算额外拷贝

---

## 4. 原生 Loopback 调用图

### 4.1 服务端调用图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           qperf server                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ socket(AF_INET, SOCK_STREAM, 0)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              glibc                                       │
│                                                                         │
│  socket() ──────────────────────────────────────────────► syscall       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ 系统调用
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  SYSCALL_DEFINE4(socket, ...)                                           │
│    └─► __sys_socket()                                                   │
│          └─► sock_create() ──► 创建 struct socket                       │
│          └─► sock_map_fd()  ──► 返回 fd=3                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ bind(3, 0.0.0.0:19765)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  SYSCALL_DEFINE3(bind, ...)                                             │
│    └─► __sys_bind()                                                     │
│          └─► inet_bind() ──► 绑定地址到 socket                          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ listen(3, 128)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  SYSCALL_DEFINE2(listen, ...)                                           │
│    └─► __sys_listen()                                                   │
│          └─► inet_listen() ──► socket 状态变为 LISTEN                   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ accept(3, ...) ──► 阻塞等待
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  SYSCALL_DEFINE4(accept, ...)                                           │
│    └─► __sys_accept()                                                   │
│          └─► inet_accept()                                              │
│                └─► inet_csk_accept()                                    │
│                      └─► 等待连接队列非空                                │
│                      └─► 从队列取出 struct sock                          │
│                      └─► sock_map_fd() ──► 返回 client_fd=4             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ recv(4, buf, 524288, 0) ──► 阻塞等待数据
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  SYSCALL_DEFINE4(recv, ...)                                             │
│    └─► __sys_recv()                                                     │
│          └─► sock_recvmsg()                                             │
│                └─► inet_recvmsg()                                       │
│                      └─► tcp_recvmsg()                                  │
│                            └─► 从 socket 接收队列读取数据                │
│                            └─► ★ copy_to_user() ★                       │
│                                  └─► 内核 SKB → 用户 buf                │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ send(4, buf, 524288, 0)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  SYSCALL_DEFINE4(send, ...)                                             │
│    └─► __sys_send()                                                     │
│          └─► sock_sendmsg()                                             │
│                └─► inet_sendmsg()                                       │
│                      └─► tcp_sendmsg()                                  │
│                            └─► ★ copy_from_user() ★                     │
│                            │     └─► 用户 buf → 内核 SKB                │
│                            └─► tcp_push()                               │
│                                  └─► ip_queue_xmit()                    │
│                                        └─► dev_queue_xmit()             │
│                                              └─► loopback_xmit()        │
│                                                    └─► 数据进入 lo 网卡  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 客户端调用图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           qperf client                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ socket(AF_INET, SOCK_STREAM, 0)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  同服务端，返回 fd=3                                                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ connect(3, 127.0.0.1:19765)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  SYSCALL_DEFINE3(connect, ...)                                          │
│    └─► __sys_connect()                                                  │
│          └─► inet_stream_connect()                                      │
│                └─► tcp_v4_connect()                                     │
│                      └─► 发送 SYN 包                                    │
│                      └─► 等待 SYN-ACK                                   │
│                      └─► 发送 ACK ──► 三次握手完成                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ write(3, buf, 524288)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  SYSCALL_DEFINE3(write, ...)                                            │
│    └─► ksys_write()                                                     │
│          └─► vfs_write()                                                │
│                └─► sock_write_iter()                                    │
│                      └─► sock_sendmsg()                                 │
│                            └─► tcp_sendmsg()                            │
│                                  └─► ★ copy_from_user() ★               │
│                                  │     └─► 用户 buf → 内核 SKB          │
│                                  └─► loopback_xmit()                    │
│                                        └─► 数据进入 lo 网卡             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ read(3, buf, 524288)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  SYSCALL_DEFINE3(read, ...)                                             │
│    └─► ksys_read()                                                      │
│          └─► vfs_read()                                                 │
│                └─► sock_read_iter()                                     │
│                      └─► sock_recvmsg()                                 │
│                            └─► tcp_recvmsg()                            │
│                                  └─► ★ copy_to_user() ★                 │
│                                        └─► 内核 SKB → 用户 buf          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.3 原生 Loopback 数据流

```
┌──────────────────┐                              ┌──────────────────┐
│  qperf client    │                              │  qperf server    │
│                  │                              │                  │
│  buf (malloc)    │                              │  buf (malloc)    │
│  PG#100          │                              │  PG#500          │
└────────┬─────────┘                              └────────▲─────────┘
         │                                                 │
         │ write(3, buf, 524288)                           │
         ▼                                                 │
┌─────────────────────────────────────────────────────────────────────────┐
│                              内核                                        │
│                                                                         │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐         │
│  │ copy_from_   │      │   lo 网卡    │      │ copy_to_     │         │
│  │ user()       │      │  (loopback)  │      │ user()       │         │
│  │              │      │              │      │              │         │
│  │ PG#100 → SKB │ ───► │ SKB → SKB   │ ───► │ SKB → PG#500 │         │
│  │  ★ 拷贝1    │      │   (无拷贝)   │      │  ★ 拷贝2    │         │
│  └──────────────┘      └──────────────┘      └──────────────┘         │
│                                                                         │
│  /proc/net/dev lo 流量统计：+524288 bytes                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

数据流：用户 buf ──copy_from_user──► 内核 SKB ──loopback──► 内核 SKB ──copy_to_user──► 用户 buf
拷贝次数：2次
```

---

## 5. shmipc 拦截后调用图

### 5.1 服务端调用图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           qperf server                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ socket(AF_INET, SOCK_STREAM, 0)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_preload.c (劫持层)                            │
│                                                                         │
│  int socket(int domain, int type, int protocol) {                       │
│      fd = real_socket(domain, type, protocol);  ──► 内核，返回 fd=3     │
│      init_fd_info(fd, domain, type, protocol);                          │
│      if (should_use_shmipc(domain, type))                               │
│          info->conn_type = CONN_TYPE_SHMIPC;  ◄── 标记为 shmipc 候选    │
│      return fd;                                                         │
│  }                                                                      │
│                                                                         │
│  g_fds[3] = { conn_type=SHMIPC, stream_id=-1, ... }                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ bind(3, 0.0.0.0:19765)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_preload.c (劫持层)                            │
│                                                                         │
│  int bind(int sockfd, const struct sockaddr *addr, ...) {               │
│      info = get_fd_info(sockfd);                                        │
│      // addr 是 AF_INET，不是 AF_UNIX，不记录 path                       │
│      return real_bind(sockfd, addr, addrlen);  ──► 内核                 │
│  }                                                                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ listen(3, 128)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_preload.c (劫持层)                            │
│                                                                         │
│  int listen(int sockfd, int backlog) {                                  │
│      info = get_fd_info(sockfd);                                        │
│      info->is_listening = 1;                                            │
│      // info->is_server = 0 (因为没有 bind Unix socket)                 │
│      // 所以不调用 ShmipcCreateServerSession                            │
│      return real_listen(sockfd, backlog);  ──► 内核                     │
│  }                                                                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ accept(3, ...) ──► 阻塞等待
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_preload.c (劫持层)                            │
│                                                                         │
│  int accept(int sockfd, struct sockaddr *addr, ...) {                   │
│      server_info = get_fd_info(sockfd);                                 │
│      client_fd = real_accept(sockfd, addr, addrlen);  ──► 内核，返回 4  │
│                                                                         │
│      if (server_info->conn_type == SHMIPC) {                            │
│          init_fd_info(client_fd, ...);                                  │
│          client_info->conn_type = CONN_TYPE_SHMIPC;                     │
│                                                                         │
│          stream_id = ShmipcAcceptStream(sockfd);  ◄── CGO 调用          │
│          // 等待客户端 ShmipcOpenStream                                  │
│          client_info->stream_id = stream_id;                            │
│      }                                                                  │
│      return client_fd;                                                  │
│  }                                                                      │
│                                                                         │
│  g_fds[4] = { conn_type=SHMIPC, stream_id=1, ... }                      │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               │ CGO: ShmipcAcceptStream(sockfd)
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_bridge.go (Go 桥接层)                         │
│                                                                         │
│  func ShmipcAcceptStream(fd C.int) C.int {                              │
│      session = sessions[int(fd)];                                       │
│      stream, err := session.AcceptStream();  ◄── 阻塞等待客户端         │
│      streamID = int(stream.StreamID());                                 │
│      streams[streamID] = stream;                                        │
│      return C.int(streamID);                                            │
│  }                                                                      │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        shmipc-go 核心库                                  │
│                                                                         │
│  AcceptStream() {                                                       │
│      // 1. 从共享内存队列读取客户端发来的 Stream 请求                    │
│      // 2. 创建 Stream 对象                                             │
│      // 3. 返回 Stream                                                  │
│  }                                                                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ recv(4, buf, 524288, 0)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_preload.c (劫持层)                            │
│                                                                         │
│  ssize_t recv(int sockfd, void *buf, size_t len, int flags) {           │
│      info = get_fd_info(sockfd);                                        │
│                                                                         │
│      if (info->conn_type == SHMIPC && info->stream_id >= 0) {           │
│          ret = ShmipcRead(info->stream_id, buf, len);  ◄── CGO 调用     │
│          if (ret > 0) return ret;                                       │
│      }                                                                  │
│      return real_recv(sockfd, buf, len, flags);  // 回退                │
│  }                                                                      │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               │ CGO: ShmipcRead(stream_id=1, buf, 524288)
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_bridge.go (Go 桥接层)                         │
│                                                                         │
│  func ShmipcRead(streamID C.int, data unsafe.Pointer, length C.long) {  │
│      stream = streams[int(streamID)];                                   │
│      reader := stream.BufferReader();                                   │
│                                                                         │
│      buf, _ := reader.ReadBytes(int(length));                           │
│      // buf 直接指向共享内存（零拷贝）                                   │
│                                                                         │
│      copy((*[1 << 30]byte)(data)[:len(buf)], buf);                      │
│      // ★ 拷贝：共享内存 → C 内存（qperf buf）★                         │
│                                                                         │
│      stream.ReleaseReadAndReuse();                                      │
│      return C.long(len(buf));                                           │
│  }                                                                      │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        共享内存 (mmap)                                   │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Stream 1 接收缓冲区 (512KB)                                      │   │
│  │  物理页: PG#300                                                   │   │
│  │  虚拟地址: 0x7f0000a00000                                         │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  数据已在共享内存中，由客户端 ShmipcWrite 写入                          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 客户端调用图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           qperf client                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ socket(AF_INET, SOCK_STREAM, 0)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_preload.c (劫持层)                            │
│                                                                         │
│  g_fds[3] = { conn_type=SHMIPC, stream_id=-1, ... }                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ connect(3, 127.0.0.1:19765)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_preload.c (劫持层)                            │
│                                                                         │
│  int connect(int sockfd, const struct sockaddr *addr, ...) {            │
│      info = get_fd_info(sockfd);                                        │
│      use_shmipc = 0;                                                    │
│                                                                         │
│      if (info->conn_type == SHMIPC) {                                   │
│          if (is_loopback_addr(addr))  ◄── 127.0.0.1 是本地回环          │
│              use_shmipc = 1;                                            │
│      }                                                                  │
│                                                                         │
│      ret = real_connect(sockfd, addr, addrlen);  ──► 内核 TCP 连接      │
│                                                                         │
│      if (ret == 0 && use_shmipc) {                                      │
│          ShmipcCreateClientSession(sockfd, path);  ◄── CGO 调用         │
│          stream_id = ShmipcOpenStream(sockfd);      ◄── CGO 调用        │
│          info->stream_id = stream_id;                                   │
│      }                                                                  │
│      return ret;                                                        │
│  }                                                                      │
│                                                                         │
│  g_fds[3] = { conn_type=SHMIPC, stream_id=1, ... }                      │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               │ CGO: ShmipcCreateClientSession(3, "")
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_bridge.go (Go 桥接层)                         │
│                                                                         │
│  func ShmipcCreateClientSession(fd C.int, path *C.char) C.int {         │
│      file := os.NewFile(uintptr(fd), "unix");                           │
│      conn, _ := net.FileConn(file);                                     │
│                                                                         │
│      session, _ := shmipc.Client(conn, config);                         │
│      // shmipc.Client 内部：                                            │
│      //   1. memfd_create() 创建共享内存                                │
│      //   2. ftruncate(32MB)                                            │
│      //   3. mmap() 映射到进程地址空间                                  │
│      //   4. 通过 Unix socket 将 memfd 传给服务端                       │
│                                                                         │
│      sessions[int(fd)] = session;                                       │
│      return 0;                                                          │
│  }                                                                      │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               │ CGO: ShmipcOpenStream(3)
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_bridge.go (Go 桥接层)                         │
│                                                                         │
│  func ShmipcOpenStream(fd C.int) C.int {                                │
│      session = sessions[int(fd)];                                       │
│      stream, _ := session.OpenStream();                                 │
│      // OpenStream 内部：                                               │
│      //   1. 分配 StreamID                                              │
│      //   2. 创建 Stream 对象                                           │
│      //   3. 将 Stream 请求写入共享内存队列                             │
│      //   4. 通知服务端 AcceptStream                                    │
│                                                                         │
│      streamID = int(stream.StreamID());                                 │
│      streams[streamID] = stream;                                        │
│      return C.int(streamID);                                            │
│  }                                                                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ write(3, buf, 524288)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_preload.c (劫持层)                            │
│                                                                         │
│  ssize_t write(int fd, const void *buf, size_t count) {                 │
│      info = get_fd_info(fd);                                            │
│                                                                         │
│      if (info->conn_type == SHMIPC && info->stream_id >= 0) {           │
│          ret = ShmipcWrite(info->stream_id, buf, count);  ◄── CGO 调用  │
│          if (ret > 0) return ret;                                       │
│      }                                                                  │
│      return real_write(fd, buf, count);  // 回退                        │
│  }                                                                      │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               │ CGO: ShmipcWrite(stream_id=1, buf, 524288)
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_bridge.go (Go 桥接层)                         │
│                                                                         │
│  func ShmipcWrite(streamID C.int, data unsafe.Pointer, length C.long) { │
│      stream = streams[int(streamID)];                                   │
│                                                                         │
│      // ★★★ 第1次拷贝：C 内存 → Go 堆 ★★★                              │
│      buf := C.GoBytes(data, C.int(length));                             │
│      // data = qperf buf 地址 (PG#100)                                  │
│      // buf  = Go 堆新分配的 []byte (PG#150)                            │
│                                                                         │
│      writer := stream.BufferWriter();                                   │
│                                                                         │
│      // ★★★ 第2次拷贝：Go 堆 → 共享内存 ★★★                           │
│      n, _ := writer.WriteBytes(buf);                                    │
│      // buf = Go 堆 (PG#150)                                            │
│      // writer 内部 buffer = 共享内存 (PG#300)                          │
│                                                                         │
│      stream.Flush(false);  // 通知服务端                                │
│      return C.long(n);                                                  │
│  }                                                                      │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        共享内存 (mmap)                                   │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Stream 1 发送缓冲区 (512KB)                                      │   │
│  │  物理页: PG#300                                                   │   │
│  │  虚拟地址: 0x7f0000a00000                                         │   │
│  │                                                                   │   │
│  │  数据已写入，等待 Flush 通知服务端                                │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  Flush() 内部：                                                         │
│    1. sendQueue.put(offset)  // 写入共享内存队列                       │
│    2. wakeUpPeer()           // 通过 Unix socket 通知服务端            │
│                                                                         │
│  /proc/net/dev lo 流量统计：只有少量 UDS 通知（几十字节）               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.3 shmipc 拦截后数据流

```
┌──────────────────┐                              ┌──────────────────┐
│  qperf client    │                              │  qperf server    │
│                  │                              │                  │
│  buf (malloc)    │                              │  buf (malloc)    │
│  PG#100          │                              │  PG#500          │
└────────┬─────────┘                              └────────▲─────────┘
         │                                                 │
         │ write(3, buf, 524288)                           │
         ▼                                                 │
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_preload.c (C 劫持层)                          │
│                                                                         │
│  write(fd, buf, count) {                                                │
│      if (conn_type == SHMIPC && stream_id >= 0)                         │
│          return ShmipcWrite(stream_id, buf, count);                     │
│  }                                                                      │
│                                                                         │
│  buf 仍然指向 qperf 堆内存，尚未拷贝                                    │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ CGO
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_bridge.go (Go 桥接层)                         │
│                                                                         │
│  ┌──────────────────┐      ┌──────────────────┐      ┌──────────────┐ │
│  │ C.GoBytes(data)  │      │ WriteBytes(buf)  │      │ Flush()      │ │
│  │                  │      │                  │      │              │ │
│  │ PG#100 → PG#150  │ ───► │ PG#150 → PG#300  │ ───► │ 通知服务端   │ │
│  │  ★ 拷贝1       │      │  ★ 拷贝2       │      │ (UDS 通知)   │ │
│  └──────────────────┘      └──────────────────┘      └──────────────┘ │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        共享内存 (mmap)                                   │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐ │
│  │                      同一块物理内存 PG#300                          │ │
│  │  ┌─────────────────────┐        ┌─────────────────────┐           │ │
│  │  │ client 进程映射      │        │ server 进程映射      │           │ │
│  │  │ 虚拟地址: 0x7f0000a0 │ ◄────► │ 虚拟地址: 0x7f8800b0 │           │ │
│  │  └─────────────────────┘        └─────────────────────┘           │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  数据在共享内存中，服务端直接 mmap 读取，无需经过内核                   │
│                                                                         │
│  /proc/net/dev lo 流量统计：≈ 0（只有 UDS 通知）                        │
│                                                                         │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               │ recv(4, buf, 524288)
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     shmipc_bridge.go (Go 桥接层)                         │
│                                                                         │
│  ┌──────────────────┐      ┌──────────────────┐                        │
│  │ ReadBytes(n)     │      │ copy(data, buf)  │                        │
│  │                  │      │                  │                        │
│  │ PG#300 → buf     │ ───► │ PG#300 → PG#500  │                        │
│  │ (零拷贝，直接    │      │  ★ 拷贝3       │                        │
│  │  返回 shm 地址)  │      │                  │                        │
│  └──────────────────┘      └──────────────────┘                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

数据流：
  写方向：qperf buf ──C.GoBytes──► Go 堆 ──WriteBytes──► 共享内存
          PG#100        PG#150           PG#300
          拷贝1         拷贝2

  读方向：共享内存 ──copy──► qperf buf
          PG#300        PG#500
          拷贝3

总拷贝次数：3次（写2次 + 读1次）
```

---

## 6. 对比总结

### 6.1 调用路径对比

| 阶段 | 原生 Loopback | shmipc 拦截 |
|------|--------------|-------------|
| socket() | 内核创建 socket | 内核创建 + 标记为 SHMIPC 候选 |
| connect() | 内核 TCP 三次握手 | 内核 TCP + 创建 shmipc Session/Stream |
| accept() | 内核返回 client_fd | 内核返回 + 创建 shmipc Stream |
| write() | 内核 copy_from_user + loopback | CGO → ShmipcWrite → 共享内存 |
| read() | 内核 copy_to_user | CGO → ShmipcRead → 从共享内存读取 |
| lo 网卡 | 经过，统计流量 | 不经过，流量≈0 |

### 6.2 数据拷贝对比

| 方向 | 原生 Loopback | shmipc 拦截 |
|------|--------------|-------------|
| 写 | 1次 (copy_from_user) | 2次 (C.GoBytes + WriteBytes) |
| 读 | 1次 (copy_to_user) | 1次 (copy) |
| **总计** | **2次** | **3次** |

### 6.3 关键差异

1. **原生 Loopback**：
   - 数据经过内核协议栈
   - lo 网卡统计流量
   - 2次拷贝（用户态↔内核态）

2. **shmipc 拦截**：
   - 数据通过共享内存
   - lo 网卡几乎无流量（只有 UDS 通知）
   - 3次拷贝（C→Go堆→共享内存→C）
   - 多一次拷贝是因为 CGO 的 `C.GoBytes`
