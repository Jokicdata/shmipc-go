# shmipc-preload

shmipc 透明代理 - 简单易用的进程间通信加速工具

## 快速开始

### 编译

```bash
cd shmipc-preload
make
```

编译后生成 `libshmipc.so` 文件。

### 使用方式

只需在命令前添加 `LD_PRELOAD=./libshmipc.so`：

```bash
LD_PRELOAD=./libshmipc.so <your-program> [args...]
```

## 示例

### qperf

```bash
# 服务端
LD_PRELOAD=./libshmipc.so qperf

# 客户端
LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw tcp_lat
```

### sockperf

```bash
# 服务端
LD_PRELOAD=./libshmipc.so sockperf sr --tcp -i 127.0.0.1 -p 11111

# 客户端
LD_PRELOAD=./libshmipc.so sockperf pp --tcp -i 127.0.0.1 -p 11111 -m 64K -t 10
```

### Redis

```bash
# 服务端
LD_PRELOAD=./libshmipc.so redis-server --unixsocket /tmp/redis.sock

# 客户端
LD_PRELOAD=./libshmipc.so redis-benchmark -s /tmp/redis.sock -t set,get -n 100000
```

### MySQL

```bash
# 服务端
LD_PRELOAD=./libshmipc.so mysqld --socket=/tmp/mysql.sock

# 客户端
LD_PRELOAD=./libshmipc.so mysql -S /tmp/mysql.sock -u root -p
```

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `SHMIPC_LOG` | 日志级别 (0-4) | 1 |

日志级别：
- 0: 静默
- 1: 错误 (默认)
- 2: 警告
- 3: 信息
- 4: 调试

示例：
```bash
# 开启调试日志
SHMIPC_LOG=4 LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw
```

## 安装

```bash
sudo make install
```

安装后可以在任意目录使用：
```bash
LD_PRELOAD=/usr/local/lib/libshmipc.so qperf 127.0.0.1 tcp_bw
```

## 工作原理

```
┌─────────────────────────────────────────────────────────────────┐
│                        应用程序                                  │
│                    (qperf/sockperf/等)                          │
└───────────────────────────┬─────────────────────────────────────┘
                            │ socket API 调用
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     libshmipc.so                                │
│                   (LD_PRELOAD 劫持)                             │
│                                                                 │
│   - 拦截 socket/connect/send/recv 等调用                       │
│   - 检测是否为本地 IPC 连接 (UDS/loopback)                      │
│   - 自动使用 shmipc 加速                                        │
│   - 不支持的连接自动回退到原始 socket                           │
└───────────────────────────┬─────────────────────────────────────┘
                            │
          ┌─────────────────┴─────────────────┐
          ▼                                   ▼
┌───────────────────────┐         ┌───────────────────────┐
│      shmipc-go        │         │      原始 socket      │
│   (共享内存零拷贝)    │         │    (内核缓冲区拷贝)   │
└───────────────────────┘         └───────────────────────┘
```

## 支持的场景

| 场景 | 支持状态 |
|------|----------|
| Unix Domain Socket | ✅ 支持 |
| TCP Loopback (127.0.0.1) | ✅ 支持 |
| IPv6 Loopback (::1) | ✅ 支持 |
| 跨机器通信 | ❌ 不支持 (自动回退) |

## 性能提升

| 数据包大小 | 延迟提升 |
|------------|----------|
| 16KB | ~3x |
| 64KB | ~2x |
| 256KB | ~1.5x |
| 1MB | ~2.4x |

## 交付清单

只需交付一个文件：
```
libshmipc.so
```

## 故障排查

### 查看是否生效

```bash
# 开启调试日志
SHMIPC_LOG=4 LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw

# 如果看到以下日志，说明已生效：
# [shmipc][INFO] shmipc-transparent loaded
# [shmipc][DEBUG] socket(...) = 3 [shmipc]
# [shmipc][DEBUG] connect(...) [shmipc]
```

### 检查程序是否动态链接

```bash
ldd $(which qperf)
# 如果输出包含 libc.so，则可以使用 LD_PRELOAD
```

## 限制

1. 仅支持动态链接的程序
2. 不支持静态链接的程序
3. 仅支持 Linux 系统
