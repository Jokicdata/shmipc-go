# Shmipc Adapter - 应用无感适配方案

## 概述

Shmipc Adapter 提供了一种无感适配方案，通过 LD_PRELOAD 技术劫持标准 socket 函数，将普通的 Unix Domain Socket 和 TCP localhost 连接自动转换为使用 shmipc 高性能通信。

## 架构设计

### 技术方案

1. **LD_PRELOAD 劫持**：通过动态链接库劫持标准 socket 函数
2. **CGO 桥接**：使用 CGO 在 C 和 Go 之间建立接口
3. **零拷贝透明化**：对应用完全透明，无需修改应用代码
4. **智能降级**：当 shmipc 不可用时自动降级到原生 socket

### adapter/ 目录文件结构

```
adapter/
├── shmipc_adapter.c        # C 适配器库 - socket 函数劫持层
├── shmipc_bridge.go       # Go 桥接库 - CGO 接口实现
├── Makefile               # Make 构建系统 - 编译配置
├── build.sh               # Shell 构建脚本 - 自动化构建工具
├── test_socket_basic.c    # 基本功能测试程序 - 功能验证
├── example_app.c         # 完整示例程序 - echo 服务器/客户端
├── config.json            # 默认配置文件 - shmipc 参数配置
├── README.md              # 详细使用文档 - 完整使用指南
└── QUICKSTART.md          # 快速开始指南 - 5 分钟上手教程
```

### 文件详细作用说明

#### 1. shmipc_adapter.c
**作用**：C 适配器库，实现 socket 函数劫持

**主要功能**：
- 劫持标准 socket 函数：`socket()`, `connect()`, `bind()`, `listen()`, `accept()`, `send()`, `recv()`, `read()`, `write()`
- 连接跟踪管理：维护 shmipc 连接状态
- 智能路由判断：判断是否应该使用 shmipc 还是原生 socket
- 环境变量检查控制：根据 `SHMIPC_ENABLED` 环境变量决定是否启用劫持

**关键特性**：
- 线程安全的连接管理
- 自动降级机制：shmipc 失败时自动使用原生 socket
- 支持 Unix Domain Socket 和 TCP localhost 自动转换

#### 2. shmipc_bridge.go
**作用**：Go 桥接库，提供 CGO 接口实现

**主要功能**：
- 实现 CGO 导出函数，供 C 代码调用
- `shmipc_go_init()`：初始化 shmipc 库
- `shmipc_go_server()`：创建 shmipc 服务端
- `shmipc_go_client()`：创建 shmipc 客户端
- `shmipc_go_accept()`：接受连接
- `shmipc_go_connect()`：建立连接
- `shmipc_go_send()`：发送数据（零拷贝）
- `shmipc_go_recv()`：接收数据（零拷贝）
- `shmipc_go_close()`：关闭连接

**关键特性**：
- 保持 shmipc 的零拷贝优势
- 线程安全的连接和流管理
- 错误处理和日志记录

#### 3. Makefile
**作用**：Make 构建系统，定义编译规则

**主要目标**：

- `all`：编译所有库（默认目标）
- `directories`：创建构建目录
- `$(GO_LIB)`：编译 Go 共享库
- `$(ADAPTER_LIB)`：编译 C 适配器库
- `install`：安装库到系统
- `test`：运行测试程序
- `clean`：清理编译产物
- `dev-build`：调试版本编译
- `perf-test`：性能测试
- `help`：显示帮助信息

**使用场景**：

- 标准开发：使用 `make`
- 调试开发：使用 `make dev-build`
- 系统部署：使用 `make install`

#### 4. build.sh
**作用**：Shell 构建脚本，提供自动化构建工具

**主要功能**：
- 依赖检查：检查 Go、GCC、make 等工具是否安装
- 系统检查：验证是否为 Linux 系统
- 自动构建：自动执行清理、编译、测试等步骤
- 友好提示：彩色输出和进度提示

**使用场景**：
- 快速构建：`./build.sh build`
- 系统安装：`./build.sh install`
- 功能测试：`./build.sh test`

#### 5. test_socket_basic.c
**作用**：基本功能测试程序，验证适配器功能

**主要功能**：
- Unix Domain Socket 测试：测试 Unix socket 劫持
- TCP Localhost 测试：测试 TCP localhost 劫持
- 基本通信测试：发送和接收数据验证

**使用场景**：
- 功能验证：验证适配器基本功能是否正常
- 问题诊断：快速定位劫持相关问题
- 开发调试：在开发过程中快速测试

#### 6. example_app.c
**作用**：完整示例程序，展示实际应用场景

**主要功能**：
- Echo 服务器：多线程 echo 服务器实现
- Echo 客户端：发送数据并接收回显
- 性能统计：显示传输的字节数和连接信息

**使用场景**：
- 学习参考：展示如何使用适配器
- 性能测试：测试实际应用场景性能
- 集成测试：验证与现有应用的兼容性

#### 7. config.json
**作用**：默认配置文件，定义 shmipc 参数

**配置参数**：
- `QueueCap`：队列容量（默认：65535）
- `ShareMemoryBufferCap`：共享内存缓冲区大小（默认：256MB）
- `MemMapType`：内存映射类型（1 = MemFd）
- `ConnectionWriteTimeout`：连接写入超时（默认：1秒）
- `BufferSliceSizes`：缓冲区切片大小配置

**使用场景**：
- 默认配置：提供合理的默认参数
- 性能调优：根据应用特点调整参数
- 资源限制：适应不同的系统资源限制

#### 8. README.md
**作用**：详细使用文档，提供完整的使用指南

**主要内容**：
- 架构设计：技术方案和组件说明
- 编译指南：详细的编译步骤和选项
- 使用指南：各种使用场景和示例
- 环境变量：所有环境变量的详细说明
- 故障排除：常见问题和解决方案
- 性能测试：性能对比和优化建议

**使用场景**：
- 学习文档：全面了解适配器功能
- 问题解决：遇到问题时查找解决方案
- 最佳实践：学习正确的使用方法

#### 9. QUICKSTART.md
**作用**：快速开始指南，帮助用户快速上手

**主要内容**：
- 5 分钟快速开始：最简化的使用流程
- 性能对比：快速的性能对比示例
- 常用命令：最常用的命令和操作
- 预期输出：成功运行的预期结果

**使用场景**：
- 新手入门：快速体验适配器功能
- 快速验证：快速验证安装是否成功
- 演示展示：向他人展示适配器功能

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

### 环境变量详解

#### export 命令作用范围

**重要概念**：`export` 命令只在当前 shell 会话及其子进程中生效，不会影响整个系统。

```bash
# 只在当前终端窗口生效
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so

# 在这个终端里运行的所有程序都会受到影响
./your_application

# 但在其他终端窗口中不会生效
```

#### 在 shell 脚本中使用 export

在 shell 脚本中使用 `export` 会对该脚本执行期间的所有命令生效，脚本结束后环境变量不会保留到父 shell。

```bash
#!/bin/bash
# test_with_shmipc.sh

export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so

# 这些命令会使用 shmipc
./test_socket_basic unix_server
./test_socket_basic unix_client

# 脚本结束后，父 shell 的环境变量不受影响
```

#### 控制是否使用 shmipc 拦截

**方法 1：通过 SHMIPC_ENABLED 环境变量控制**

```bash
# 场景 1：测试时使用 shmipc
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./qperf -c 127.0.0.1 -p 12345 -t tcp

# 场景 2：测试时不使用 shmipc（基线测试）
unset SHMIPC_ENABLED
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./qperf -c 127.0.0.1 -p 12345 -t tcp

# 或者完全不设置环境变量
./qperf -c 127.0.0.1 -p 12345 -t tcp
```

**方法 2：创建不同的测试脚本**

```bash
# shmipc_test.sh - 使用 shmipc
#!/bin/bash
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./qperf "$@"

# baseline_test.sh - 不使用 shmipc
#!/bin/bash
unset SHMIPC_ENABLED
./qperf "$@"
```

**方法 3：在命令行直接控制**

```bash
# 业务运行时完全使用 shmipc
SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so ./your_business_app

# 测试时根据需要选择
# 使用 shmipc
SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so ./qperf -c 127.0.0.1 -p 12345

# 不使用 shmipc
./qperf -c 127.0.0.1 -p 12345
```

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

**环境变量使用说明**：

- `SHMIPC_ENABLED=1`：启用 shmipc 拦截，所有符合条件的连接都会使用 shmipc
- `SHMIPC_ENABLED=0` 或不设置：禁用 shmipc 拦截，所有连接使用原生 socket
- `SHMIPC_CONFIG`：可选的 JSON 配置字符串，用于自定义 shmipc 参数

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