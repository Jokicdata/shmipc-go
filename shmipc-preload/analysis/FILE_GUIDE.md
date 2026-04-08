# shmipc-preload 性能分析工具文件说明

## 一、文件结构总览

```
shmipc-preload/analysis/
├── README.md                    # 性能分析方案总览文档
├── QUICKSTART.md                # 快速入门指南
├── SUMMARY.md                   # 问题总结和优化建议
├── FILE_GUIDE.md                # 本文档 - 文件说明
├── perf_analysis.sh             # 性能分析脚本
├── bandwidth_analysis.sh        # 带宽分析脚本
├── ftrace_analysis.sh           # ftrace 内核追踪脚本
├── shmipc_trace.bt              # eBPF 函数追踪脚本
└── docs/
    ├── perf_guide.md            # perf 使用指南
    ├── ebpf_guide.md            # eBPF 使用指南
    ├── ftrace_guide.md          # ftrace 使用指南
    └── logging_guide.md         # 日志打点方案
```

---

## 二、文档文件说明

### 2.1 README.md

**文件作用**：性能分析方案的总览文档，包含完整的问题分析、数据流对比、分析方法和优化建议。

**主要内容**：
- 问题现象描述
- 根因分析（CGO 内存拷贝问题）
- 数据流对比图
- 性能开销分解
- 分析方法总览
- 具体分析工具使用方法
- 优化方向建议

**适用人群**：需要全面了解性能分析方案的开发者

**阅读顺序**：首先阅读此文档，了解整体方案

---

### 2.2 QUICKSTART.md

**文件作用**：快速入门指南，帮助用户快速上手性能分析。

**主要内容**：
- 快速开始步骤
- 问题确认方法
- 深入分析示例
- 优化方案概述
- 常用命令速查表

**适用人群**：希望快速开始分析的开发者

**阅读顺序**：在阅读 README.md 后，使用此文档快速上手

---

### 2.3 SUMMARY.md

**文件作用**：问题总结和优化建议的精简版文档。

**主要内容**：
- 问题现象总结
- 根因分析
- 数据流对比
- 分析工具对比
- 分析脚本使用方法
- 优化方向建议
- 预期优化效果
- 下一步行动计划

**适用人群**：需要快速了解问题和解决方案的开发者

**阅读顺序**：作为问题总结和优化参考

---

### 2.4 FILE_GUIDE.md

**文件作用**：本文档，说明每个文件的用途和使用方法。

**主要内容**：
- 文件结构总览
- 每个文件的详细说明
- 使用方法和注意事项

**适用人群**：所有使用此分析工具的开发者

**阅读顺序**：作为文件索引和参考

---

### 2.5 docs/perf_guide.md

**文件作用**：perf 性能分析工具的详细使用指南。

**主要内容**：
- perf 简介
- 常用命令
- shmipc-preload 分析场景
- perf 事件列表
- 分析脚本示例
- 常见问题

**适用人群**：需要使用 perf 进行深入分析的开发者

**阅读顺序**：在需要使用 perf 分析时参考

---

### 2.6 docs/ebpf_guide.md

**文件作用**：eBPF 性能分析工具的详细使用指南。

**主要内容**：
- eBPF 简介
- 工具安装
- bpftrace 基础语法
- shmipc-preload 分析场景
- 高级分析脚本
- bcc 工具集使用

**适用人群**：需要使用 eBPF 进行函数耗时追踪的开发者

**阅读顺序**：在需要使用 eBPF 分析时参考

---

### 2.7 docs/ftrace_guide.md

**文件作用**：ftrace 内核追踪工具的详细使用指南。

**主要内容**：
- ftrace 简介
- 基本使用方法
- 函数追踪
- shmipc-preload 分析场景
- 输出分析方法
- 高级用法

**适用人群**：需要使用 ftrace 追踪内核函数的开发者

**阅读顺序**：在需要使用 ftrace 分析时参考

---

### 2.8 docs/logging_guide.md

**文件作用**：日志打点分析方案，说明如何在代码中添加精确的性能打点。

**主要内容**：
- 打点位置说明
- C 层打点实现
- Go 层打点实现
- 分析脚本示例
- 预期输出示例

**适用人群**：需要修改源码添加性能打点的开发者

**阅读顺序**：在需要精确分析函数耗时时参考

---

## 三、脚本文件说明

### 3.1 perf_analysis.sh

**文件作用**：自动化性能分析脚本，运行延迟和带宽测试并收集分析数据。

**主要功能**：
- 运行延迟测试（小包/大包）
- 运行带宽测试
- 运行对比测试（推荐）
- perf CPU 热点分析
- strace 系统调用分析

**使用方法**：
```bash
# 运行对比测试（推荐）
./perf_analysis.sh comparison

# 测试延迟
./perf_analysis.sh latency 65536

# 测试带宽
./perf_analysis.sh bandwidth 1048576

# perf 分析
sudo ./perf_analysis.sh perf <pid>
```

**输出结果**：
- `logs/latency_*.log` - 延迟测试结果
- `logs/bandwidth_*.log` - 带宽测试结果
- `logs/comparison_*.csv` - 对比测试结果

**依赖工具**：
- perf
- qperf
- sockperf（可选）

---

### 3.2 bandwidth_analysis.sh

**文件作用**：带宽瓶颈和内存带宽使用情况分析脚本。

**主要功能**：
- 获取内存带宽信息
- 获取 CPU 缓存信息
- 分析缓存性能
- 运行带宽测试
- 分析内存带宽使用
- 生成带宽分析报告

**使用方法**：
```bash
# 运行完整分析
./bandwidth_analysis.sh

# 测试特定消息大小的带宽
./bandwidth_analysis.sh test 1048576

# 仅分析内存带宽
./bandwidth_analysis.sh memory

# 仅分析缓存性能
./bandwidth_analysis.sh cache

# 生成分析报告
./bandwidth_analysis.sh report
```

**输出结果**：
- `logs/mem_bandwidth_*.log` - 内存带宽测试结果
- `logs/cache_info_*.log` - CPU 缓存信息
- `logs/cache_perf_*.log` - 缓存性能数据
- `logs/bandwidth_report_*.txt` - 带宽分析报告

**依赖工具**：
- perf
- qperf
- mbw（可选）

---

### 3.3 ftrace_analysis.sh

**文件作用**：使用 ftrace 追踪内核函数调用和耗时。

**主要功能**：
- 追踪 socket 相关内核函数
- 追踪内存操作函数
- 追踪 IPC 相关函数
- 分析追踪结果

**使用方法**：
```bash
# 追踪 socket 函数
sudo ./ftrace_analysis.sh socket "qperf 127.0.0.1 tcp_lat"

# 追踪内存函数
sudo ./ftrace_analysis.sh memory "qperf 127.0.0.1 tcp_bw"

# 追踪 IPC 函数
sudo ./ftrace_analysis.sh ipc "qperf 127.0.0.1 tcp_lat"

# 追踪所有函数
sudo ./ftrace_analysis.sh all "qperf 127.0.0.1 tcp_lat"
```

**输出结果**：
- `logs/ftrace/trace_*.log` - ftrace 追踪结果
- `logs/ftrace/trace_*_analysis.txt` - 分析报告

**依赖工具**：
- ftrace（内核内置）
- root 权限

---

### 3.4 shmipc_trace.bt

**文件作用**：eBPF 追踪脚本，追踪 shmipc-preload 各函数的耗时分布。

**主要功能**：
- 追踪 ShmipcWrite 函数耗时
- 追踪 ShmipcRead 函数耗时
- 追踪 ShmipcOpenStream 函数耗时
- 追踪 ShmipcAcceptStream 函数耗时
- 追踪 ShmipcCreateClientSession 函数耗时
- 追踪 ShmipcCreateServerSession 函数耗时
- 追踪 memcpy 函数耗时（内存拷贝开销）
- 输出耗时直方图和统计信息

**使用方法**：
```bash
# 追踪所有 shmipc 函数
sudo bpftrace shmipc_trace.bt

# 追踪特定进程
sudo bpftrace -e 'pid:$1' shmipc_trace.bt <pid>
```

**输出结果**：
- 实时输出到终端
- 包含耗时直方图
- 包含调用次数统计
- 包含平均耗时

**依赖工具**：
- bpftrace
- root 权限

---

## 四、使用流程建议

### 4.1 初次使用

1. 阅读 `README.md` 了解整体方案
2. 阅读 `QUICKSTART.md` 快速上手
3. 运行 `./perf_analysis.sh comparison` 确认问题

### 4.2 深入分析

1. 使用 `perf` 分析 CPU 热点（参考 `docs/perf_guide.md`）
2. 使用 `eBPF` 追踪函数耗时（运行 `shmipc_trace.bt`）
3. 使用 `ftrace` 追踪内核函数（运行 `ftrace_analysis.sh`）

### 4.3 带宽分析

1. 运行 `./bandwidth_analysis.sh` 进行完整分析
2. 查看生成的报告文件

### 4.4 精确分析

1. 参考 `docs/logging_guide.md` 添加日志打点
2. 重新编译运行
3. 分析打点数据

---

## 五、注意事项

### 5.1 权限要求

| 脚本 | 权限要求 |
|------|----------|
| perf_analysis.sh | 部分 sudo |
| bandwidth_analysis.sh | 部分 sudo |
| ftrace_analysis.sh | 需要 sudo |
| shmipc_trace.bt | 需要 sudo |

### 5.2 依赖工具

| 工具 | 用途 | 安装方法 |
|------|------|----------|
| perf | CPU 性能分析 | `yum install perf` 或 `apt install linux-tools-common` |
| qperf | 网络性能测试 | `yum install qperf` 或 `apt install qperf` |
| bpftrace | eBPF 追踪 | 参考 `docs/ebpf_guide.md` |
| mbw | 内存带宽测试（可选） | `yum install mbw` 或 `apt install mbw` |

### 5.3 输出目录

所有分析结果保存在 `logs/` 目录下：
- `logs/` - perf_analysis.sh 输出
- `logs/bandwidth/` - bandwidth_analysis.sh 输出
- `logs/ftrace/` - ftrace_analysis.sh 输出

---

## 六、常见问题

### 6.1 脚本无法执行

```bash
# 添加执行权限
chmod +x *.sh
```

### 6.2 找不到依赖工具

```bash
# 检查依赖
./perf_analysis.sh help

# 安装缺失工具
yum install perf qperf
# 或
apt install linux-tools-common qperf
```

### 6.3 eBPF 无法运行

```bash
# 检查 bpftrace 是否安装
which bpftrace

# 检查内核版本（需要 4.9+）
uname -r

# 安装 bpftrace
# 参考 docs/ebpf_guide.md
```

### 6.4 ftrace 无权限

```bash
# 检查是否有权限访问
ls -la /sys/kernel/debug/tracing

# 使用 sudo 运行
sudo ./ftrace_analysis.sh socket "qperf 127.0.0.1 tcp_lat"
```

---

## 七、联系与反馈

如有问题或建议，请参考项目主目录的 README.md 或联系开发团队。
