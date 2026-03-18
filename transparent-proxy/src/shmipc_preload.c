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

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <pthread.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdarg.h>

#include "shmipc_transparent.h"

#define MAX_CONNECTIONS 4096
#define MAX_PATH_LEN 256

typedef enum {
    CONN_TYPE_UNKNOWN = 0,
    CONN_TYPE_SOCKET,       // 原始 socket
    CONN_TYPE_SHMIPC,       // shmipc 连接
} conn_type_t;

typedef struct {
    int fd;
    conn_type_t type;
    int domain;
    int type;
    int protocol;
    int is_connected;
    int is_listening;
    char path[MAX_PATH_LEN];
    void *shmipc_handle;    // shmipc session handle
    pthread_mutex_t lock;
} connection_t;

static struct {
    int initialized;
    shmipc_config_t config;
    shmipc_stats_t stats;
    connection_t connections[MAX_CONNECTIONS];
    pthread_mutex_t global_lock;
    void *shmipc_lib_handle;
    
    // Original function pointers
    int (*real_socket)(int, int, int);
    int (*real_bind)(int, const struct sockaddr *, socklen_t);
    int (*real_listen)(int, int);
    int (*real_accept)(int, struct sockaddr *, socklen_t *);
    int (*real_accept4)(int, struct sockaddr *, socklen_t *, int);
    int (*real_connect)(int, const struct sockaddr *, socklen_t);
    ssize_t (*real_send)(int, const void *, size_t, int);
    ssize_t (*real_recv)(int, void *, size_t, int);
    ssize_t (*real_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
    ssize_t (*real_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
    ssize_t (*real_sendmsg)(int, const struct msghdr *, int);
    ssize_t (*real_recvmsg)(int, struct msghdr *, int);
    ssize_t (*real_write)(int, const void *, size_t);
    ssize_t (*real_read)(int, void *, size_t);
    ssize_t (*real_writev)(int, const struct iovec *, int);
    ssize_t (*real_readv)(int, const struct iovec *, int);
    int (*real_close)(int);
    int (*real_shutdown)(int, int);
    int (*real_getsockopt)(int, int, int, void *, socklen_t *);
    int (*real_setsockopt)(int, int, int, const void *, socklen_t);
    int (*real_fcntl)(int, int, ...);
    int (*real_ioctl)(int, unsigned long, ...);
    int (*real_dup)(int);
    int (*real_dup2)(int, int);
    int (*real_dup3)(int, int, int);
} g_ctx = {0};

static void log_message(shmipc_log_level_t level, const char *fmt, ...) {
    if (level > g_ctx.config.log_level) {
        return;
    }
    
    const char *level_str[] = {"", "ERROR", "WARN", "INFO", "DEBUG"};
    
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "[shmipc-transparent][%s] ", level_str[level]);
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
}

static void init_real_functions(void) {
    if (g_ctx.real_socket != NULL) {
        return;
    }
    
    g_ctx.real_socket = dlsym(RTLD_NEXT, "socket");
    g_ctx.real_bind = dlsym(RTLD_NEXT, "bind");
    g_ctx.real_listen = dlsym(RTLD_NEXT, "listen");
    g_ctx.real_accept = dlsym(RTLD_NEXT, "accept");
    g_ctx.real_accept4 = dlsym(RTLD_NEXT, "accept4");
    g_ctx.real_connect = dlsym(RTLD_NEXT, "connect");
    g_ctx.real_send = dlsym(RTLD_NEXT, "send");
    g_ctx.real_recv = dlsym(RTLD_NEXT, "recv");
    g_ctx.real_sendto = dlsym(RTLD_NEXT, "sendto");
    g_ctx.real_recvfrom = dlsym(RTLD_NEXT, "recvfrom");
    g_ctx.real_sendmsg = dlsym(RTLD_NEXT, "sendmsg");
    g_ctx.real_recvmsg = dlsym(RTLD_NEXT, "recvmsg");
    g_ctx.real_write = dlsym(RTLD_NEXT, "write");
    g_ctx.real_read = dlsym(RTLD_NEXT, "read");
    g_ctx.real_writev = dlsym(RTLD_NEXT, "writev");
    g_ctx.real_readv = dlsym(RTLD_NEXT, "readv");
    g_ctx.real_close = dlsym(RTLD_NEXT, "close");
    g_ctx.real_shutdown = dlsym(RTLD_NEXT, "shutdown");
    g_ctx.real_getsockopt = dlsym(RTLD_NEXT, "getsockopt");
    g_ctx.real_setsockopt = dlsym(RTLD_NEXT, "setsockopt");
    g_ctx.real_fcntl = dlsym(RTLD_NEXT, "fcntl");
    g_ctx.real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    g_ctx.real_dup = dlsym(RTLD_NEXT, "dup");
    g_ctx.real_dup2 = dlsym(RTLD_NEXT, "dup2");
    g_ctx.real_dup3 = dlsym(RTLD_NEXT, "dup3");
}

static connection_t *get_connection(int fd) {
    if (fd < 0 || fd >= MAX_CONNECTIONS) {
        return NULL;
    }
    return &g_ctx.connections[fd];
}

static void init_connection(int fd, int domain, int type, int protocol) {
    if (fd < 0 || fd >= MAX_CONNECTIONS) {
        return;
    }
    
    connection_t *conn = &g_ctx.connections[fd];
    conn->fd = fd;
    conn->type = CONN_TYPE_UNKNOWN;
    conn->domain = domain;
    conn->type = type;
    conn->protocol = protocol;
    conn->is_connected = 0;
    conn->is_listening = 0;
    conn->shmipc_handle = NULL;
    conn->path[0] = '\0';
    pthread_mutex_init(&conn->lock, NULL);
}

static void cleanup_connection(int fd) {
    connection_t *conn = get_connection(fd);
    if (conn == NULL) {
        return;
    }
    
    pthread_mutex_lock(&conn->lock);
    
    if (conn->shmipc_handle != NULL) {
        // TODO: 调用 Go 层的 close 函数
        conn->shmipc_handle = NULL;
    }
    
    conn->fd = -1;
    conn->type = CONN_TYPE_UNKNOWN;
    conn->is_connected = 0;
    conn->is_listening = 0;
    
    pthread_mutex_unlock(&conn->lock);
    pthread_mutex_destroy(&conn->lock);
}

int shmipc_transparent_init(const shmipc_config_t *config) {
    if (g_ctx.initialized) {
        return 0;
    }
    
    init_real_functions();
    
    pthread_mutex_init(&g_ctx.global_lock, NULL);
    
    if (config != NULL) {
        memcpy(&g_ctx.config, config, sizeof(shmipc_config_t));
    } else {
        // Default configuration
        memset(&g_ctx.config, 0, sizeof(shmipc_config_t));
        g_ctx.config.mode = SHMIPC_MODE_AUTO;
        g_ctx.config.log_level = SHMIPC_LOG_WARN;
        g_ctx.config.shm_buffer_size = 32 * 1024 * 1024;  // 32MB
        g_ctx.config.queue_capacity = 8192;
        strcpy(g_ctx.config.shm_path_prefix, "/dev/shm/shmipc_transparent");
        g_ctx.config.enable_fallback = 1;
        g_ctx.config.enable_stats = 1;
    }
    
    // Initialize all connections
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        g_ctx.connections[i].fd = -1;
    }
    
    // Load shmipc-go library
    // TODO: Load the Go shared library
    
    g_ctx.initialized = 1;
    log_message(SHMIPC_LOG_INFO, "shmipc transparent proxy initialized");
    
    return 0;
}

int shmipc_transparent_get_config(shmipc_config_t *config) {
    if (config == NULL) {
        return -1;
    }
    memcpy(config, &g_ctx.config, sizeof(shmipc_config_t));
    return 0;
}

int shmipc_transparent_get_stats(shmipc_stats_t *stats) {
    if (stats == NULL) {
        return -1;
    }
    memcpy(stats, &g_ctx.stats, sizeof(shmipc_stats_t));
    return 0;
}

int shmipc_transparent_reset_stats(void) {
    memset(&g_ctx.stats, 0, sizeof(shmipc_stats_t));
    return 0;
}

void shmipc_transparent_cleanup(void) {
    if (!g_ctx.initialized) {
        return;
    }
    
    // Close all connections
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (g_ctx.connections[i].fd >= 0) {
            cleanup_connection(i);
        }
    }
    
    pthread_mutex_destroy(&g_ctx.global_lock);
    g_ctx.initialized = 0;
    
    log_message(SHMIPC_LOG_INFO, "shmipc transparent proxy cleaned up");
}

int shmipc_should_intercept(int domain, int type, int protocol) {
    if (!g_ctx.initialized) {
        return 0;
    }
    
    if (g_ctx.config.mode == SHMIPC_MODE_FORCE_SOCKET) {
        return 0;
    }
    
    // Only intercept AF_UNIX (UDS) and AF_INET/AF_INET6 loopback
    if (domain == AF_UNIX) {
        return 1;
    }
    
    // TODO: Check for loopback TCP connections
    
    return 0;
}

int shmipc_is_local_uds(const char *path) {
    if (path == NULL) {
        return 0;
    }
    
    // Check if it's a UDS path
    return (strncmp(path, "/", 1) == 0 || strncmp(path, "@", 1) == 0);
}

int shmipc_is_local_tcp(const struct sockaddr *addr, socklen_t addrlen) {
    if (addr == NULL) {
        return 0;
    }
    
    if (addr->sa_family == AF_INET) {
        struct sockaddr_in *addr_in = (struct sockaddr_in *)addr;
        // Check for 127.0.0.1
        return (ntohl(addr_in->sin_addr.s_addr) == 0x7f000001);
    } else if (addr->sa_family == AF_INET6) {
        struct sockaddr_in6 *addr_in6 = (struct sockaddr_in6 *)addr;
        // Check for ::1
        static const unsigned char loopback6[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1};
        return (memcmp(addr_in6->sin6_addr.s6_addr, loopback6, 16) == 0);
    }
    
    return 0;
}

// ============== Socket API Interception ==============

int socket(int domain, int type, int protocol) {
    init_real_functions();
    
    if (!g_ctx.initialized) {
        shmipc_transparent_init(NULL);
    }
    
    int fd = g_ctx.real_socket(domain, type, protocol);
    if (fd >= 0) {
        init_connection(fd, domain, type, protocol);
        
        if (shmipc_should_intercept(domain, type, protocol)) {
            connection_t *conn = get_connection(fd);
            if (conn != NULL) {
                conn->type = CONN_TYPE_SHMIPC;
                log_message(SHMIPC_LOG_DEBUG, "socket(%d, %d, %d) = %d [shmipc]", 
                           domain, type, protocol, fd);
            }
        } else {
            connection_t *conn = get_connection(fd);
            if (conn != NULL) {
                conn->type = CONN_TYPE_SOCKET;
            }
        }
        
        __sync_fetch_and_add(&g_ctx.stats.total_connections, 1);
    }
    
    return fd;
}

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    init_real_functions();
    
    connection_t *conn = get_connection(sockfd);
    if (conn == NULL) {
        return g_ctx.real_bind(sockfd, addr, addrlen);
    }
    
    // Store the bind address for later use
    if (addr->sa_family == AF_UNIX) {
        struct sockaddr_un *un_addr = (struct sockaddr_un *)addr;
        strncpy(conn->path, un_addr->sun_path, MAX_PATH_LEN - 1);
        log_message(SHMIPC_LOG_DEBUG, "bind(%d, \"%s\") [shmipc]", sockfd, conn->path);
    }
    
    return g_ctx.real_bind(sockfd, addr, addrlen);
}

int listen(int sockfd, int backlog) {
    init_real_functions();
    
    connection_t *conn = get_connection(sockfd);
    if (conn == NULL) {
        return g_ctx.real_listen(sockfd, backlog);
    }
    
    conn->is_listening = 1;
    
    log_message(SHMIPC_LOG_DEBUG, "listen(%d, %d) [shmipc]", sockfd, backlog);
    
    return g_ctx.real_listen(sockfd, backlog);
}

int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    init_real_functions();
    
    connection_t *server_conn = get_connection(sockfd);
    if (server_conn == NULL || server_conn->type != CONN_TYPE_SHMIPC) {
        return g_ctx.real_accept(sockfd, addr, addrlen);
    }
    
    int client_fd = g_ctx.real_accept(sockfd, addr, addrlen);
    if (client_fd >= 0) {
        init_connection(client_fd, server_conn->domain, server_conn->type, server_conn->protocol);
        
        connection_t *client_conn = get_connection(client_fd);
        if (client_conn != NULL) {
            client_conn->type = CONN_TYPE_SHMIPC;
            client_conn->is_connected = 1;
            strncpy(client_conn->path, server_conn->path, MAX_PATH_LEN - 1);
            
            // TODO: Initialize shmipc session for accepted connection
            
            __sync_fetch_and_add(&g_ctx.stats.shmipc_connections, 1);
        }
        
        log_message(SHMIPC_LOG_DEBUG, "accept(%d) = %d [shmipc]", sockfd, client_fd);
    }
    
    return client_fd;
}

int accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags) {
    init_real_functions();
    
    connection_t *server_conn = get_connection(sockfd);
    if (server_conn == NULL || server_conn->type != CONN_TYPE_SHMIPC) {
        return g_ctx.real_accept4(sockfd, addr, addrlen, flags);
    }
    
    int client_fd = g_ctx.real_accept4(sockfd, addr, addrlen, flags);
    if (client_fd >= 0) {
        init_connection(client_fd, server_conn->domain, server_conn->type, server_conn->protocol);
        
        connection_t *client_conn = get_connection(client_fd);
        if (client_conn != NULL) {
            client_conn->type = CONN_TYPE_SHMIPC;
            client_conn->is_connected = 1;
            strncpy(client_conn->path, server_conn->path, MAX_PATH_LEN - 1);
            
            __sync_fetch_and_add(&g_ctx.stats.shmipc_connections, 1);
        }
        
        log_message(SHMIPC_LOG_DEBUG, "accept4(%d) = %d [shmipc]", sockfd, client_fd);
    }
    
    return client_fd;
}

int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    init_real_functions();
    
    connection_t *conn = get_connection(sockfd);
    if (conn == NULL) {
        return g_ctx.real_connect(sockfd, addr, addrlen);
    }
    
    int should_use_shmipc = 0;
    
    // Check if this is a local connection that should use shmipc
    if (addr->sa_family == AF_UNIX) {
        struct sockaddr_un *un_addr = (struct sockaddr_un *)addr;
        strncpy(conn->path, un_addr->sun_path, MAX_PATH_LEN - 1);
        should_use_shmipc = 1;
    } else if (shmipc_is_local_tcp(addr, addrlen)) {
        should_use_shmipc = 1;
    }
    
    if (should_use_shmipc && conn->type == CONN_TYPE_SHMIPC) {
        log_message(SHMIPC_LOG_DEBUG, "connect(%d, \"%s\") [shmipc]", sockfd, conn->path);
        
        // TODO: Initialize shmipc client session
        // For now, fall through to real connect
        
        __sync_fetch_and_add(&g_ctx.stats.shmipc_connections, 1);
    }
    
    int ret = g_ctx.real_connect(sockfd, addr, addrlen);
    if (ret == 0) {
        conn->is_connected = 1;
    }
    
    return ret;
}

ssize_t send(int sockfd, const void *buf, size_t len, int flags) {
    init_real_functions();
    
    connection_t *conn = get_connection(sockfd);
    if (conn == NULL || conn->type != CONN_TYPE_SHMIPC || conn->shmipc_handle == NULL) {
        return g_ctx.real_send(sockfd, buf, len, flags);
    }
    
    // TODO: Use shmipc send
    ssize_t ret = g_ctx.real_send(sockfd, buf, len, flags);
    
    if (ret > 0) {
        __sync_fetch_and_add(&g_ctx.stats.shmipc_bytes_sent, ret);
        __sync_fetch_and_add(&g_ctx.stats.total_bytes_sent, ret);
    }
    
    return ret;
}

ssize_t recv(int sockfd, void *buf, size_t len, int flags) {
    init_real_functions();
    
    connection_t *conn = get_connection(sockfd);
    if (conn == NULL || conn->type != CONN_TYPE_SHMIPC || conn->shmipc_handle == NULL) {
        return g_ctx.real_recv(sockfd, buf, len, flags);
    }
    
    // TODO: Use shmipc recv
    ssize_t ret = g_ctx.real_recv(sockfd, buf, len, flags);
    
    if (ret > 0) {
        __sync_fetch_and_add(&g_ctx.stats.shmipc_bytes_recv, ret);
        __sync_fetch_and_add(&g_ctx.stats.total_bytes_recv, ret);
    }
    
    return ret;
}

ssize_t sendto(int sockfd, const void *buf, size_t len, int flags,
               const struct sockaddr *dest_addr, socklen_t addrlen) {
    init_real_functions();
    
    connection_t *conn = get_connection(sockfd);
    if (conn == NULL || conn->type != CONN_TYPE_SHMIPC) {
        return g_ctx.real_sendto(sockfd, buf, len, flags, dest_addr, addrlen);
    }
    
    // shmipc doesn't support sendto, use send instead
    return send(sockfd, buf, len, flags);
}

ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags,
                 struct sockaddr *src_addr, socklen_t *addrlen) {
    init_real_functions();
    
    connection_t *conn = get_connection(sockfd);
    if (conn == NULL || conn->type != CONN_TYPE_SHMIPC) {
        return g_ctx.real_recvfrom(sockfd, buf, len, flags, src_addr, addrlen);
    }
    
    // shmipc doesn't support recvfrom, use recv instead
    return recv(sockfd, buf, len, flags);
}

ssize_t write(int fd, const void *buf, size_t count) {
    init_real_functions();
    
    connection_t *conn = get_connection(fd);
    if (conn == NULL || conn->type != CONN_TYPE_SHMIPC || conn->shmipc_handle == NULL) {
        return g_ctx.real_write(fd, buf, count);
    }
    
    ssize_t ret = g_ctx.real_write(fd, buf, count);
    
    if (ret > 0) {
        __sync_fetch_and_add(&g_ctx.stats.shmipc_bytes_sent, ret);
        __sync_fetch_and_add(&g_ctx.stats.total_bytes_sent, ret);
    }
    
    return ret;
}

ssize_t read(int fd, void *buf, size_t count) {
    init_real_functions();
    
    connection_t *conn = get_connection(fd);
    if (conn == NULL || conn->type != CONN_TYPE_SHMIPC || conn->shmipc_handle == NULL) {
        return g_ctx.real_read(fd, buf, count);
    }
    
    ssize_t ret = g_ctx.real_read(fd, buf, count);
    
    if (ret > 0) {
        __sync_fetch_and_add(&g_ctx.stats.shmipc_bytes_recv, ret);
        __sync_fetch_and_add(&g_ctx.stats.total_bytes_recv, ret);
    }
    
    return ret;
}

int close(int fd) {
    init_real_functions();
    
    connection_t *conn = get_connection(fd);
    if (conn != NULL) {
        cleanup_connection(fd);
    }
    
    return g_ctx.real_close(fd);
}

int shutdown(int sockfd, int how) {
    init_real_functions();
    
    connection_t *conn = get_connection(sockfd);
    if (conn != NULL && conn->type == CONN_TYPE_SHMIPC) {
        log_message(SHMIPC_LOG_DEBUG, "shutdown(%d, %d) [shmipc]", sockfd, how);
    }
    
    return g_ctx.real_shutdown(sockfd, how);
}

// Constructor - called when library is loaded
__attribute__((constructor))
static void library_init(void) {
    // Read environment variables for configuration
    shmipc_config_t config = {0};
    
    char *mode = getenv("SHMIPC_MODE");
    if (mode != NULL) {
        if (strcmp(mode, "auto") == 0) {
            config.mode = SHMIPC_MODE_AUTO;
        } else if (strcmp(mode, "force_shmipc") == 0) {
            config.mode = SHMIPC_MODE_FORCE_SHMIPC;
        } else if (strcmp(mode, "force_socket") == 0) {
            config.mode = SHMIPC_MODE_FORCE_SOCKET;
        }
    } else {
        config.mode = SHMIPC_MODE_AUTO;
    }
    
    char *log_level = getenv("SHMIPC_LOG_LEVEL");
    if (log_level != NULL) {
        config.log_level = atoi(log_level);
    } else {
        config.log_level = SHMIPC_LOG_WARN;
    }
    
    char *buffer_size = getenv("SHMIPC_BUFFER_SIZE");
    if (buffer_size != NULL) {
        config.shm_buffer_size = atoi(buffer_size);
    } else {
        config.shm_buffer_size = 32 * 1024 * 1024;
    }
    
    char *path_prefix = getenv("SHMIPC_PATH_PREFIX");
    if (path_prefix != NULL) {
        strncpy(config.shm_path_prefix, path_prefix, SHMIPC_MAX_PATH_LEN - 1);
    } else {
        strcpy(config.shm_path_prefix, "/dev/shm/shmipc_transparent");
    }
    
    config.enable_fallback = 1;
    config.enable_stats = 1;
    
    shmipc_transparent_init(&config);
}

// Destructor - called when library is unloaded
__attribute__((destructor))
static void library_fini(void) {
    shmipc_transparent_cleanup();
}
