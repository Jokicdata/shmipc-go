# shmipc-go 项目规则

## 项目概述
Shmipc 是字节跳动开发的高性能进程间通信（IPC）库，基于 Linux 共享内存技术构建。使用 Unix domain socket 或 TCP 连接进行进程同步，实现跨进程零拷贝通信。

## 技术栈
- **语言**: Go 1.20+
- **平台**: Linux（主要），使用共享内存和 epoll
- **核心特性**: 零拷贝 IPC、批量 IO、共享内存

## 构建与测试命令

### 运行测试
```bash
go test ./...
```

### 运行基准测试
```bash
go test -bench=. -run=^$ ./...
```

### 运行特定基准测试
```bash
go test -bench=BenchmarkParallelPingPong -run BenchmarkParallelPingPong
```

### 代码检查
```bash
golangci-lint run
```

### 格式化代码
```bash
gofmt -w .
```

## 代码风格指南
- 遵循 [Go Code Review Comments](https://github.com/golang/go/wiki/CodeReviewComments)
- 遵循 [Effective Go](https://golang.org/doc/effective_go)
- 使用 gofmt 进行格式化
- 使用 golangci-lint 进行代码检查

## 项目结构
- `/adapter` - shmipc 桥接的 C 适配器
- `/doc` - 文档文件
- `/example` - 示例应用（helloworld、best_practice、hot_restart_test）
- 根目录 - 核心库文件（buffer、session、stream 等）

## 关键文件
- `buffer.go` - 缓冲区管理
- `session.go` - 会话管理
- `stream.go` - 流操作
- `listener.go` - 监听器实现
- `protocol_manager.go` - 协议管理
- `event_dispatcher.go` - 事件分发

## 重要说明
- 本项目专为 Linux 系统设计（使用 epoll、memfd_create）
- 通过共享内存实现零拷贝
- 支持同步和异步接口
- 支持热重启功能

## 提交信息规范
遵循 [AngularJS Git Commit Message Conventions](https://docs.google.com/document/d/1QrDFcIiPjSLDn3EL15IJygNPiHORgU1_OOAqWjiDU5Y/edit)

## 分支组织
使用 git-flow 分支模型（develop、feature 分支等）
