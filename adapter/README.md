# Shmipc Adapter - 应用无感适配方案

## 概述

Shmipc Adapter 提供了一种无感适配方案，通过 LD_PRELOAD 技术劫持标准 socket 函数，将普通的 Unix Domain Socket 和 TCP localhost 连接自动转换为使用 shmipc 高性能通信。

## 架构设计

### 技术方案

1. **LD_PRELOAD 劫持**：通过动态链接库劫持标准 socket 函数
2. **CGO 桥接**：使用 CGO 在 C 和 Go 之间建立接口
3. **零拷贝透明化**：对应用完全透明，无需修改应用代码
4. **智能降级**：当 shmipc 不可用时自动降级到原生 socket

### 组件架构

```
┌─────────────────────────────────────────────────────────────┐
│                  应用程序                           │
│            (qperf, sockperf, etc.)                 │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│              libshmipc_adapter.so                     │
│         (C Socket Function Interception)                │
│  ┌─────────────────────────────────────────────────┐   │
│  │ socket(), connect(), bind(), listen()       │   │
│  │ accept(), send(), recv(), read(), write() │   │
│  └─────────────────┬───────────────────────────┘   │
└──────────────────────┼──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│               libshmipc_go.so                        │
│           (Go-CGO Bridge Layer)                      │
│  ┌─────────────────────────────────────────────────┐   │
│  │ shmipc_go_init()                             │   │
│  │ shmipc_go_server(), shmipc_go_client()      │   │
│  │ shmipc_go_accept(), shmipc_go_connect()     │   │
│  │ shmipc_go_send(), shmipc_go_recv()          │   │
│  └─────────────────┬───────────────────────────┘   │
└──────────────────────┼──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│              Shmipc Core Library                     │
│         (Zero-Copy IPC Implementation)                 │
└─────────────────────────────────────────────────────────────┘
```

## 编译指南

### 前置要求

1. **Go 环境**：Go 1.20 或更高版本
2. **C 编译器**：GCC 或 Clang
3. **Linux 系统**：需要 Linux 内核支持共享内存
4. **开发工具**：make, pthread 库

### 编译步骤

#### 1. 进入适配器目录

```bash
cd /path/to/shmipc-go/adapter
```

#### 2. 编译所有组件

```bash
make
```

这将生成两个共享库：
- `lib/libshmipc_go.so`：Go 共享库（CGO 桥接层）
- `lib/libshmipc_adapter.so`：C 适配器库（socket 函数劫持）

#### 3. 可选：安装到系统

```bash
sudo make install
```

这将库安装到 `/usr/local/lib/` 并运行 `ldconfig`。

### 编译选项

#### 标准编译

```bash
make
```

#### 调试编译

```bash
make dev-build
```

#### 清理编译产物

```bash
make clean
```

## 使用指南

### 基本使用方法

#### 1. 启用 shmipc 适配器

```bash
export SHMIPC_ENABLED=1
export LD_PRELOAD=/path/to/libshmipc_adapter.so:/path/to/libshmipc_go.so
```

#### 2. 运行应用程序

```bash
./your_application
```

### 环境变量

| 变量名 | 说明 | 可选值 | 默认值 |
|--------|------|----------|----------|
| `SHMIPC_ENABLED` | 是否启用 shmipc 适配器 | 1, true, yes, 其他 | 0 (禁用) |
| `SHMIPC_CONFIG` | shmipc 配置（JSON 格式） | 配置字符串 | 使用默认配置 |

### 支持的连接类型

#### 1. Unix Domain Socket

**自动转换规则**：
- 所有 Unix Domain Socket 连接都会被劫持
- 路径保持不变，直接使用 shmipc

**示例**：
```bash
# 原始连接
connect("/tmp/my_socket.sock")

# 自动转换为 shmipc
shmipc client connect to "/tmp/my_socket.sock"
```

#### 2. TCP Localhost

**自动转换规则**：
- 127.0.0.1 (IPv4) 和 ::1 (IPv6) 连接会被劫持
- 端口号映射到 Unix socket 路径：`/tmp/shmipc_tcp_<port>`

**示例**：
```bash
# 原始连接
connect("127.0.0.1:12345")

# 自动转换为 shmipc
shmipc client connect to "/tmp/shmipc_tcp_12345"
```

#### 3. 其他连接

**不支持的连接**：
- 非 localhost 的 TCP 连接
- 其他协议的 socket 连接

这些连接会自动降级到原生 socket，不影响正常使用。

## 实际应用场景

### 1. qperf 性能测试

#### 服务端

```bash
# 终端 1
cd /path/to/shmipc-go/adapter
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so

# 启动 qperf 服务端
qperf -s -p 12345
```

#### 客户端

```bash
# 终端 2
cd /path/to/shmipc-go/adapter
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so

# 运行 qperf 客户端测试
qperf -c 127.0.0.1 -p 12345 -t tcp
```

#### 对比测试

```bash
# 不使用 shmipc（原生 socket）
qperf -c 127.0.0.1 -p 12345 -t tcp

# 使用 shmipc
SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so \
  qperf -c 127.0.0.1 -p 12345 -t tcp
```

### 2. sockperf 性能测试

#### 服务端

```bash
# 终端 1
cd /path/to/shmipc-go/adapter
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so

# 启动 sockperf 服务端
sockperf -s -i 127.0.0.1 -p 12345
```

#### 客户端

```bash
# 终端 2
cd /path/to/shmipc-go/adapter
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so

# 运行 sockperf 客户端测试
sockperf -c -i 127.0.0.1 -p 12345
```

### 3. 自定义应用程序

#### 示例程序

```c
#include <stdio.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

int main() {
    int sockfd;
    struct sockaddr_in addr;
    
    // 创建 socket
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    
    // 连接到 localhost
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(12345);
    
    connect(sockfd, (struct sockaddr*)&addr, sizeof(addr));
    
    // 发送数据
    send(sockfd, "Hello", 5, 0);
    
    // 接收数据
    char buffer[1024];
    recv(sockfd, buffer, sizeof(buffer), 0);
    
    close(sockfd);
    return 0;
}
```

#### 编译和运行

```bash
# 编译程序
gcc -o my_app my_app.c

# 使用 shmipc 适配器运行
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./my_app
```

## 测试程序

### 基本功能测试

#### Unix Domain Socket 测试

```bash
# 终端 1：启动服务端
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./test_socket_basic unix_server

# 终端 2：启动客户端
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./test_socket_basic unix_client
```

#### TCP Localhost 测试

```bash
# 终端 1：启动服务端
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./test_socket_basic tcp_server

# 终端 2：启动客户端
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./test_socket_basic tcp_client
```

### 运行所有测试

```bash
make test
```

## 高级配置

### 自定义配置

#### JSON 配置格式

```json
{
  "QueueCap": 65535,
  "ShareMemoryBufferCap": 268435456,
  "MemMapType": 1,
  "ConnectionWriteTimeout": 1000000000
}
```

#### 使用自定义配置

```bash
export SHMIPC_CONFIG='{"QueueCap": 131072, "ShareMemoryBufferCap": 536870912}'
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./your_application
```

### 调试和日志

#### 启用详细日志

```bash
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./your_application 2>&1 | grep "\[shmipc\]"
```

#### 调试版本

```bash
# 编译调试版本
make dev-build

# 使用调试版本运行
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./your_application
```

## 性能对比测试

### 自动化性能测试

```bash
# 运行性能测试套件
make perf-test
```

### 手动性能测试

#### 1. 基准测试（原生 socket）

```bash
# 服务端
qperf -s -p 12345 &

# 客户端
qperf -c 127.0.0.1 -p 12345 -t tcp -m 1M -l 60
```

#### 2. Shmipc 测试

```bash
# 服务端
SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so \
  qperf -s -p 12345 &

# 客户端
SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so \
  qperf -c 127.0.0.1 -p 12345 -t tcp -m 1M -l 60
```

#### 3. 结果对比

比较两个测试的吞吐量、延迟和 CPU 使用率。

## 故障排除

### 常见问题

#### 1. 库加载失败

**问题**：
```
error while loading shared libraries: libshmipc_adapter.so: cannot open shared object file
```

**解决方案**：
```bash
# 检查库文件是否存在
ls -la lib/libshmipc_adapter.so lib/libshmipc_go.so

# 使用绝对路径
export LD_PRELOAD=/absolute/path/to/lib/libshmipc_adapter.so:/absolute/path/to/lib/libshmipc_go.so

# 或者安装到系统
sudo make install
```

#### 2. 权限问题

**问题**：
```
permission denied when creating shared memory
```

**解决方案**：
```bash
# 检查 /dev/shm 权限
ls -la /dev/shm

# 设置适当权限
sudo chmod 777 /dev/shm
```

#### 3. 端口冲突

**问题**：
```
address already in use
```

**解决方案**：
```bash
# 清理残留的 socket 文件
rm -f /tmp/shmipc_*

# 使用不同的端口
qperf -s -p 12346
```

#### 4. 性能不如预期

**可能原因**：
- 小包场景：shmipc 在小包场景下性能提升不明显
- 配置不当：共享内存大小或队列容量不足
- 系统限制：ulimit 或内核参数限制

**解决方案**：
```bash
# 增加共享内存大小
export SHMIPC_CONFIG='{"ShareMemoryBufferCap": 1073741824}'

# 检查系统限制
ulimit -a

# 调整内核参数（需要 root 权限）
sudo sysctl -w kernel.shmmax=1073741824
```

### 调试技巧

#### 1. 检查库加载

```bash
# 使用 ldd 检查依赖
ldd ./your_application

# 使用 LD_DEBUG 查看库加载过程
LD_DEBUG=libs ./your_application
```

#### 2. 检查函数劫持

```bash
# 使用 strace 跟踪系统调用
strace -e trace=socket,connect,bind,listen,accept ./your_application

# 使用 ltrace 跟踪库函数调用
ltrace -e socket,connect,bind,listen,accept ./your_application
```

#### 3. 性能分析

```bash
# 使用 perf 分析性能
perf stat ./your_application

# 使用 perf record 分析热点
perf record -g ./your_application
perf report
```

## 限制和注意事项

### 当前限制

1. **仅支持 Linux**：shmipc 依赖 Linux 特有的共享内存机制
2. **localhost TCP 限制**：只支持 127.0.0.1 和 ::1 的 TCP 连接
3. **部分 socket 选项**：某些 socket 选项可能不被支持
4. **异步 I/O 限制**：异步 I/O 操作可能不完全支持

### 注意事项

1. **线程安全**：适配器是线程安全的，可以在多线程环境中使用
2. **资源清理**：确保正确关闭所有 socket，避免资源泄漏
3. **错误处理**：适配器会在错误时自动降级到原生 socket
4. **性能调优**：根据应用特点调整共享内存配置

## 未来扩展

### 计划功能

1. **配置文件支持**：支持从配置文件读取配置
2. **更多协议支持**：支持更多的 socket 协议和选项
3. **性能监控**：集成性能监控和统计功能
4. **自动调优**：根据工作负载自动调整配置参数

### 贡献指南

欢迎贡献代码和改进建议：

1. Fork 项目
2. 创建特性分支
3. 提交更改
4. 发起 Pull Request

## 总结

Shmipc Adapter 提供了一种简单而强大的方式，让现有应用程序无需修改代码就能享受 shmipc 的高性能优势。通过 LD_PRELOAD 技术和 CGO 桥接，实现了对应用的完全透明适配，特别适合性能测试工具和现有应用的性能优化。