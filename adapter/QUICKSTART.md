# Shmipc Adapter - 快速开始指南

## 🚀 5 分钟快速开始

### 1. 编译适配器

```bash
cd /path/to/shmipc-go/adapter
./build.sh build
```

### 2. 测试基本功能

#### 终端 1：启动服务端

```bash
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./test_socket_basic unix_server
```

#### 终端 2：启动客户端

```bash
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
./test_socket_basic unix_client
```

### 3. 使用 qperf 进行性能测试

#### 服务端

```bash
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
qperf -s -p 12345
```

#### 客户端

```bash
export SHMIPC_ENABLED=1
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so
qperf -c 127.0.0.1 -p 12345 -t tcp
```

## 📊 性能对比

### 基准测试（原生 socket）

```bash
# 服务端
qperf -s -p 12345 &

# 客户端
qperf -c 127.0.0.1 -p 12345 -t tcp -m 1M -l 60
```

### Shmipc 测试

```bash
# 服务端
SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so \
  qperf -s -p 12345 &

# 客户端
SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so \
  qperf -c 127.0.0.1 -p 12345 -t tcp -m 1M -l 60
```

## 🔧 常用命令

### 编译命令

```bash
./build.sh build     # 编译所有库
./build.sh clean     # 清理编译产物
./build.sh install   # 安装到系统
./build.sh test      # 编译并测试
./build.sh help      # 显示帮助信息
```

### 环境变量

```bash
export SHMIPC_ENABLED=1                                    # 启用 shmipc
export SHMIPC_CONFIG='{"ShareMemoryBufferCap": 536870912}'  # 自定义配置
export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so  # 加载适配器
```

## 🎯 支持的连接类型

### ✅ 自动转换

1. **Unix Domain Socket**：所有 Unix socket 连接
2. **TCP Localhost**：127.0.0.1 和 ::1 的 TCP 连接

### ❌ 不转换

1. **远程 TCP 连接**：非 localhost 的 TCP 连接
2. **其他协议**：UDP、Unix datagram 等

## 📝 预期输出

### 成功加载

```
[shmipc] Adapter loaded, shmipc enabled
[shmipc-go] Initialized with config: 
[shmipc] Intercepting connect to /tmp/shmipc_test.sock
[shmipc-go] Client created for path: /tmp/shmipc_test.sock
[shmipc-go] Stream accepted
```

### 性能提升

大包场景（≥ 4KB）预期性能提升：
- **4KB**：约 90% 性能提升
- **16KB**：约 230% 性能提升  
- **64KB**：约 120% 性能提升
- **1MB+**：约 140% 性能提升

## 🐛 故障排除

### 库加载失败

```bash
# 检查库文件
ls -la lib/libshmipc_adapter.so lib/libshmipc_go.so

# 使用绝对路径
export LD_PRELOAD=/absolute/path/to/lib/libshmipc_adapter.so:/absolute/path/to/lib/libshmipc_go.so
```

### 权限问题

```bash
# 检查 /dev/shm 权限
ls -la /dev/shm

# 设置权限
sudo chmod 777 /dev/shm
```

### 端口冲突

```bash
# 清理残留文件
rm -f /tmp/shmipc_*
```

## 📚 更多文档

- **详细文档**：`README.md` - 完整的使用指南和 API 文档
- **技术架构**：`../doc/technical_architecture.md` - 深度技术分析
- **性能分析**：`../doc/benchmark_analysis.md` - 性能测试详细分析

## 💡 提示

1. **首次使用**：先用 `test_socket_basic` 测试基本功能
2. **性能调优**：根据应用特点调整共享内存大小
3. **生产环境**：建议使用 `./build.sh install` 安装到系统
4. **监控日志**：使用 `2>&1 | grep "\[shmipc\]"` 查看详细日志

## 🎉 开始使用

现在你已经准备好了！选择以下任一方式开始：

```bash
# 方式 1：使用测试程序
./build.sh test

# 方式 2：直接使用 qperf
SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so qperf -s

# 方式 3：应用到你的程序
SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so ./your_app
```

享受 shmipc 带来的高性能提升！🚀