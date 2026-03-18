/*
 * Copyright 2023 CloudWeGo Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef SHMIPC_TRANSPARENT_H
#define SHMIPC_TRANSPARENT_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SHMIPC_MAX_PATH_LEN 256
#define SHMIPC_MAX_ADDR_LEN 128

typedef enum {
    SHMIPC_MODE_AUTO = 0,       // 自动检测，UDS 自动切换到 shmipc
    SHMIPC_MODE_FORCE_SHMIPC,   // 强制使用 shmipc
    SHMIPC_MODE_FORCE_SOCKET,   // 强制使用原始 socket
} shmipc_mode_t;

typedef enum {
    SHMIPC_LOG_SILENT = 0,      // 静默模式
    SHMIPC_LOG_ERROR,           // 仅错误
    SHMIPC_LOG_WARN,            // 警告及以上
    SHMIPC_LOG_INFO,            // 信息及以上
    SHMIPC_LOG_DEBUG,           // 调试及以上
} shmipc_log_level_t;

typedef struct shmipc_config {
    shmipc_mode_t mode;
    shmipc_log_level_t log_level;
    uint32_t shm_buffer_size;       // 共享内存缓冲区大小 (默认 32MB)
    uint32_t queue_capacity;        // 队列容量 (默认 8192)
    char shm_path_prefix[SHMIPC_MAX_PATH_LEN];  // 共享内存路径前缀
    int enable_fallback;            // 启用降级到原始 socket
    int enable_stats;               // 启用统计信息
} shmipc_config_t;

typedef struct shmipc_stats {
    uint64_t total_connections;
    uint64_t shmipc_connections;
    uint64_t fallback_connections;
    uint64_t total_bytes_sent;
    uint64_t total_bytes_recv;
    uint64_t shmipc_bytes_sent;
    uint64_t shmipc_bytes_recv;
    uint64_t fallback_bytes_sent;
    uint64_t fallback_bytes_recv;
} shmipc_stats_t;

// 初始化透明代理库
int shmipc_transparent_init(const shmipc_config_t *config);

// 获取当前配置
int shmipc_transparent_get_config(shmipc_config_t *config);

// 获取统计信息
int shmipc_transparent_get_stats(shmipc_stats_t *stats);

// 重置统计信息
int shmipc_transparent_reset_stats(void);

// 清理资源
void shmipc_transparent_cleanup(void);

// 检查是否应该使用 shmipc
// 返回 1 表示应该使用 shmipc，0 表示使用原始 socket
int shmipc_should_intercept(int domain, int type, int protocol);

// 检查地址是否为本地 UDS
int shmipc_is_local_uds(const char *path);

// 检查地址是否为本地 TCP (loopback)
int shmipc_is_local_tcp(const struct sockaddr *addr, socklen_t addrlen);

#ifdef __cplusplus
}
#endif

#endif // SHMIPC_TRANSPARENT_H
