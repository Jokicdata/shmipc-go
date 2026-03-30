/*
 * shmipc-preload - shmipc 透明代理
 * 
 * 功能：通过 LD_PRELOAD 劫持 socket API，自动将本地 IPC 连接转换为 shmipc 连接
 * 
 * 使用方式：
 *   LD_PRELOAD=./libshmipc.so <your-program>
 * 
 * 示例：
 *   LD_PRELOAD=./libshmipc.so qperf 127.0.0.1 tcp_bw
 *   LD_PRELOAD=./libshmipc.so sockperf sr --tcp -i 127.0.0.1
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
#include <stdarg.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>

/* ========== 配置常量 ========== */
#define MAX_FDS 4096
#define MAX_PATH 256
#define SHM_BUFFER_SIZE (32 * 1024 * 1024)
#define QUEUE_CAPACITY 8192

/* ========== 日志级别 ========== */
#define LOG_SILENT 0
#define LOG_ERROR  1
#define LOG_WARN   2
#define LOG_INFO   3
#define LOG_DEBUG  4

/* ========== 连接类型 ========== */
#define CONN_TYPE_SOCKET 0
#define CONN_TYPE_SHMIPC 1

/* ========== 流状态 ========== */
#define STREAM_STATE_OPEN   0
#define STREAM_STATE_CLOSED 1

/* ========== 外部 Go 函数声明 ========== */
extern int ShmipcInit(void);
extern void ShmipcCleanup(void);
extern int ShmipcCreateClientSession(int fd, const char *path);
extern int ShmipcCreateServerSession(int fd, const char *path);
extern int ShmipcOpenStream(int fd);
extern int ShmipcAcceptStream(int fd);
extern long ShmipcWrite(int stream_id, const void *data, long length);
extern long ShmipcRead(int stream_id, void *data, long length);
extern int ShmipcCloseStream(int stream_id);
extern int ShmipcCloseSession(int fd);
extern int ShmipcGetStats(void *stats);

/* ========== 全局状态 ========== */
static int g_log_level = LOG_ERROR;
static int g_initialized = 0;
static int g_shmipc_enabled = 1;

/* ========== 原始函数指针 ========== */
static int (*real_socket)(int, int, int);
static int (*real_bind)(int, const struct sockaddr *, socklen_t);
static int (*real_listen)(int, int);
static int (*real_accept)(int, struct sockaddr *, socklen_t *);
static int (*real_accept4)(int, struct sockaddr *, socklen_t *, int);
static int (*real_connect)(int, const struct sockaddr *, socklen_t);
static ssize_t (*real_send)(int, const void *, size_t, int);
static ssize_t (*real_recv)(int, void *, size_t, int);
static ssize_t (*real_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static ssize_t (*real_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
static ssize_t (*real_write)(int, const void *, size_t);
static ssize_t (*real_read)(int, void *, size_t);
static ssize_t (*real_writev)(int, const struct iovec *, int);
static ssize_t (*real_readv)(int, const struct iovec *, int);
static int (*real_close)(int);
static int (*real_shutdown)(int, int);
static int (*real_getsockopt)(int, int, int, void *, socklen_t *);
static int (*real_setsockopt)(int, int, int, const void *, socklen_t);
static int (*real_fcntl)(int, int, ...);
static int (*real_dup)(int);
static int (*real_dup2)(int, int);

/* ========== 连接信息结构 ========== */
typedef struct {
    int fd;
    int domain;
    int type;
    int protocol;
    int conn_type;
    int is_connected;
    int is_listening;
    int is_server;
    int stream_id;
    char path[MAX_PATH];
    pthread_mutex_t lock;
} fd_info_t;

/* ========== 全局文件描述符表 ========== */
static fd_info_t g_fds[MAX_FDS];
static pthread_mutex_t g_global_lock = PTHREAD_MUTEX_INITIALIZER;

/* ========== 统计信息 ========== */
static struct {
    uint64_t total_connections;
    uint64_t shmipc_connections;
    uint64_t socket_connections;
    uint64_t total_bytes_sent;
    uint64_t total_bytes_recv;
    uint64_t shmipc_bytes_sent;
    uint64_t shmipc_bytes_recv;
} g_stats;

/* ========== 日志函数 ========== */
static void log_msg(int level, const char *fmt, ...) {
    if (level > g_log_level) return;
    
    const char *levels[] = {"", "ERROR", "WARN", "INFO", "DEBUG"};
    fprintf(stderr, "[shmipc][%s] ", levels[level]);
    
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
}

/* ========== 初始化原始函数指针 ========== */
static void init_real_funcs(void) {
    if (real_socket != NULL) return;
    
    real_socket = dlsym(RTLD_NEXT, "socket");
    real_bind = dlsym(RTLD_NEXT, "bind");
    real_listen = dlsym(RTLD_NEXT, "listen");
    real_accept = dlsym(RTLD_NEXT, "accept");
    real_accept4 = dlsym(RTLD_NEXT, "accept4");
    real_connect = dlsym(RTLD_NEXT, "connect");
    real_send = dlsym(RTLD_NEXT, "send");
    real_recv = dlsym(RTLD_NEXT, "recv");
    real_sendto = dlsym(RTLD_NEXT, "sendto");
    real_recvfrom = dlsym(RTLD_NEXT, "recvfrom");
    real_write = dlsym(RTLD_NEXT, "write");
    real_read = dlsym(RTLD_NEXT, "read");
    real_writev = dlsym(RTLD_NEXT, "writev");
    real_readv = dlsym(RTLD_NEXT, "readv");
    real_close = dlsym(RTLD_NEXT, "close");
    real_shutdown = dlsym(RTLD_NEXT, "shutdown");
    real_getsockopt = dlsym(RTLD_NEXT, "getsockopt");
    real_setsockopt = dlsym(RTLD_NEXT, "setsockopt");
    real_fcntl = dlsym(RTLD_NEXT, "fcntl");
    real_dup = dlsym(RTLD_NEXT, "dup");
    real_dup2 = dlsym(RTLD_NEXT, "dup2");
}

/* ========== 获取文件描述符信息 ========== */
static fd_info_t* get_fd_info(int fd) {
    if (fd < 0 || fd >= MAX_FDS) return NULL;
    return &g_fds[fd];
}

/* ========== 初始化文件描述符信息 ========== */
static void init_fd_info(int fd, int domain, int type, int protocol) {
    if (fd < 0 || fd >= MAX_FDS) return;
    
    fd_info_t *info = &g_fds[fd];
    memset(info, 0, sizeof(*info));
    info->fd = fd;
    info->domain = domain;
    info->type = type;
    info->protocol = protocol;
    info->conn_type = CONN_TYPE_SOCKET;
    info->stream_id = -1;
    pthread_mutex_init(&info->lock, NULL);
}

/* ========== 清理文件描述符信息 ========== */
static void cleanup_fd_info(int fd) {
    fd_info_t *info = get_fd_info(fd);
    if (info == NULL) return;
    
    pthread_mutex_lock(&info->lock);
    
    if (info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        ShmipcCloseStream(info->stream_id);
        info->stream_id = -1;
    }
    
    if (info->conn_type == CONN_TYPE_SHMIPC) {
        ShmipcCloseSession(fd);
    }
    
    pthread_mutex_unlock(&info->lock);
    pthread_mutex_destroy(&info->lock);
    memset(info, 0, sizeof(*info));
}

/* ========== 判断是否应该使用 shmipc ========== */
static int should_use_shmipc(int domain, int type) {
    if (!g_shmipc_enabled) return 0;
    
    if (domain == AF_UNIX) return 1;
    
    // 对于 TCP 连接，暂时返回 0，在 bind/connect 时根据地址决定
    // if ((domain == AF_INET || domain == AF_INET6) && type == SOCK_STREAM) {
    //     return 1;
    // }
    
    return 0;
}

/* ========== 判断是否为本地回环地址 ========== */
static int is_loopback_addr(const struct sockaddr *addr, socklen_t addrlen) {
    if (addr == NULL) return 0;
    
    if (addr->sa_family == AF_INET) {
        struct sockaddr_in *in = (struct sockaddr_in *)addr;
        uint32_t ip = ntohl(in->sin_addr.s_addr);
        return (ip == 0x7f000001);
    }
    
    if (addr->sa_family == AF_INET6) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)addr;
        static const unsigned char loopback[16] = {
            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1
        };
        return (memcmp(in6->sin6_addr.s6_addr, loopback, 16) == 0);
    }
    
    return 0;
}

/* ========== 库初始化 ========== */
__attribute__((constructor))
static void lib_init(void) {
    init_real_funcs();
    
    char *log_env = getenv("SHMIPC_LOG");
    if (log_env) {
        g_log_level = atoi(log_env);
    }
    
    char *enable_env = getenv("SHMIPC_ENABLE");
    if (enable_env && strcmp(enable_env, "0") == 0) {
        g_shmipc_enabled = 0;
    }
    
    memset(g_fds, 0, sizeof(g_fds));
    memset(&g_stats, 0, sizeof(g_stats));
    
    int ret = ShmipcInit();
    if (ret != 0) {
        log_msg(LOG_WARN, "ShmipcInit failed: %d, fallback to socket", ret);
        g_shmipc_enabled = 0;
    }
    
    g_initialized = 1;
    log_msg(LOG_INFO, "shmipc-preload loaded (enabled: %d, log: %d)", 
            g_shmipc_enabled, g_log_level);
}

/* ========== 库清理 ========== */
__attribute__((destructor))
static void lib_fini(void) {
    for (int i = 0; i < MAX_FDS; i++) {
        if (g_fds[i].fd > 0) {
            cleanup_fd_info(i);
        }
    }
    
    ShmipcCleanup();
    log_msg(LOG_INFO, "shmipc-preload unloaded");
}

/* ========== socket() 劫持 ========== */
int socket(int domain, int type, int protocol) {
    init_real_funcs();
    
    int fd = real_socket(domain, type, protocol);
    if (fd < 0) return fd;
    
    init_fd_info(fd, domain, type, protocol);
    
    fd_info_t *info = get_fd_info(fd);
    if (info && should_use_shmipc(domain, type)) {
        info->conn_type = CONN_TYPE_SHMIPC;
        log_msg(LOG_DEBUG, "socket(%d, %d, %d) = %d [shmipc]", 
               domain, type, protocol, fd);
    } else {
        log_msg(LOG_DEBUG, "socket(%d, %d, %d) = %d [socket]", 
               domain, type, protocol, fd);
    }
    
    __sync_fetch_and_add(&g_stats.total_connections, 1);
    return fd;
}

/* ========== bind() 劫持 ========== */
int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    
    if (info && addr) {
        if (addr->sa_family == AF_UNIX) {
            struct sockaddr_un *un = (struct sockaddr_un *)addr;
            strncpy(info->path, un->sun_path, MAX_PATH - 1);
            info->is_server = 1;
            log_msg(LOG_DEBUG, "bind(%d, \"%s\") [shmipc]", sockfd, info->path);
        } else if (addr->sa_family == AF_INET) {
            struct sockaddr_in *in = (struct sockaddr_in *)addr;
            snprintf(info->path, MAX_PATH - 1, "tcp://%s:%d", 
                     inet_ntoa(in->sin_addr), ntohs(in->sin_port));
            info->is_server = 1;
            log_msg(LOG_DEBUG, "bind(%d, \"%s\") [shmipc]", sockfd, info->path);
        } else if (addr->sa_family == AF_INET6) {
            struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)addr;
            char ip6[INET6_ADDRSTRLEN];
            inet_ntop(AF_INET6, &in6->sin6_addr, ip6, INET6_ADDRSTRLEN);
            snprintf(info->path, MAX_PATH - 1, "tcp6://%s:%d", 
                     ip6, ntohs(in6->sin6_port));
            info->is_server = 1;
            log_msg(LOG_DEBUG, "bind(%d, \"%s\") [shmipc]", sockfd, info->path);
        }
    }
    
    return real_bind(sockfd, addr, addrlen);
}

/* ========== listen() 劫持 ========== */
int listen(int sockfd, int backlog) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    if (info) {
        info->is_listening = 1;
        
        // 对于 TCP 连接，检查是否为本地回环地址
        if ((info->domain == AF_INET || info->domain == AF_INET6) && 
            info->type == SOCK_STREAM && info->is_server) {
            // 检查 path 是否包含本地回环地址
            if (strstr(info->path, "127.0.0.1") || strstr(info->path, "::1")) {
                info->conn_type = CONN_TYPE_SHMIPC;
                int ret = ShmipcCreateServerSession(sockfd, info->path);
                if (ret != 0) {
                    log_msg(LOG_WARN, "ShmipcCreateServerSession failed: %d", ret);
                }
                log_msg(LOG_DEBUG, "listen(%d, %d) [shmipc]", sockfd, backlog);
            }
        } else if (info->conn_type == CONN_TYPE_SHMIPC && info->is_server) {
            int ret = ShmipcCreateServerSession(sockfd, info->path);
            if (ret != 0) {
                log_msg(LOG_WARN, "ShmipcCreateServerSession failed: %d", ret);
            }
            log_msg(LOG_DEBUG, "listen(%d, %d) [shmipc]", sockfd, backlog);
        }
    }
    
    return real_listen(sockfd, backlog);
}

/* ========== accept() 劫持 ========== */
int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen) {
    init_real_funcs();
    
    fd_info_t *server_info = get_fd_info(sockfd);
    
    int client_fd = real_accept(sockfd, addr, addrlen);
    if (client_fd < 0) return client_fd;
    
    if (server_info && server_info->conn_type == CONN_TYPE_SHMIPC) {
        init_fd_info(client_fd, server_info->domain, server_info->type, server_info->protocol);
        
        fd_info_t *client_info = get_fd_info(client_fd);
        if (client_info) {
            client_info->conn_type = CONN_TYPE_SHMIPC;
            client_info->is_connected = 1;
            client_info->is_server = 0;
            strncpy(client_info->path, server_info->path, MAX_PATH - 1);
            
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

/* ========== accept4() 劫持 ========== */
int accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags) {
    init_real_funcs();
    
    fd_info_t *server_info = get_fd_info(sockfd);
    
    int client_fd = real_accept4(sockfd, addr, addrlen, flags);
    if (client_fd < 0) return client_fd;
    
    if (server_info && server_info->conn_type == CONN_TYPE_SHMIPC) {
        init_fd_info(client_fd, server_info->domain, server_info->type, server_info->protocol);
        
        fd_info_t *client_info = get_fd_info(client_fd);
        if (client_info) {
            client_info->conn_type = CONN_TYPE_SHMIPC;
            client_info->is_connected = 1;
            client_info->is_server = 0;
            strncpy(client_info->path, server_info->path, MAX_PATH - 1);
            
            int stream_id = ShmipcAcceptStream(sockfd);
            if (stream_id >= 0) {
                client_info->stream_id = stream_id;
                log_msg(LOG_DEBUG, "accept4(%d) = %d, stream=%d [shmipc]", 
                       sockfd, client_fd, stream_id);
            }
            
            __sync_fetch_and_add(&g_stats.shmipc_connections, 1);
        }
    } else {
        __sync_fetch_and_add(&g_stats.socket_connections, 1);
    }
    
    return client_fd;
}

/* ========== connect() 劫持 ========== */
int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(sockfd);
    int use_shmipc = 0;
    
    if (info) {
        if (info->conn_type == CONN_TYPE_SHMIPC) {
            if (addr && addr->sa_family == AF_UNIX) {
                struct sockaddr_un *un = (struct sockaddr_un *)addr;
                strncpy(info->path, un->sun_path, MAX_PATH - 1);
                use_shmipc = 1;
            } else if (addr && is_loopback_addr(addr, addrlen)) {
                // 为 TCP 回环连接设置 path
                if (addr->sa_family == AF_INET) {
                    struct sockaddr_in *in = (struct sockaddr_in *)addr;
                    snprintf(info->path, MAX_PATH - 1, "tcp://%s:%d", 
                             inet_ntoa(in->sin_addr), ntohs(in->sin_port));
                } else if (addr->sa_family == AF_INET6) {
                    struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)addr;
                    char ip6[INET6_ADDRSTRLEN];
                    inet_ntop(AF_INET6, &in6->sin6_addr, ip6, INET6_ADDRSTRLEN);
                    snprintf(info->path, MAX_PATH - 1, "tcp6://%s:%d", 
                             ip6, ntohs(in6->sin6_port));
                }
                use_shmipc = 1;
            }
        } else if ((info->domain == AF_INET || info->domain == AF_INET6) && 
                   info->type == SOCK_STREAM && addr && is_loopback_addr(addr, addrlen)) {
            // 对于 TCP 连接，检查是否为本地回环地址
            info->conn_type = CONN_TYPE_SHMIPC;
            // 设置 path
            if (addr->sa_family == AF_INET) {
                struct sockaddr_in *in = (struct sockaddr_in *)addr;
                snprintf(info->path, MAX_PATH - 1, "tcp://%s:%d", 
                         inet_ntoa(in->sin_addr), ntohs(in->sin_port));
            } else if (addr->sa_family == AF_INET6) {
                struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)addr;
                char ip6[INET6_ADDRSTRLEN];
                inet_ntop(AF_INET6, &in6->sin6_addr, ip6, INET6_ADDRSTRLEN);
                snprintf(info->path, MAX_PATH - 1, "tcp6://%s:%d", 
                         ip6, ntohs(in6->sin6_port));
            }
            use_shmipc = 1;
        }
    }
    
    int ret = real_connect(sockfd, addr, addrlen);
    
    if (ret == 0 && info) {
        info->is_connected = 1;
        
        if (use_shmipc) {
            int shmipc_ret = ShmipcCreateClientSession(sockfd, info->path);
            if (shmipc_ret == 0) {
                int stream_id = ShmipcOpenStream(sockfd);
                if (stream_id >= 0) {
                    info->stream_id = stream_id;
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

/* ========== write() 劫持 ========== */
ssize_t write(int fd, const void *buf, size_t count) {
    init_real_funcs();
    
    fd_info_t *info = get_fd_info(fd);
    
    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0) {
        long ret = ShmipcWrite(info->stream_id, buf, (long)count);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_sent, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
            return (ssize_t)ret;
        }
    }
    
    ssize_t ret = real_write(fd, buf, count);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
    }
    return ret;
}

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

/* ========== close() 劫持 ========== */
int close(int fd) {
    init_real_funcs();
    
    cleanup_fd_info(fd);
    
    return real_close(fd);
}

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

int fcntl(int fd, int cmd, ...) {
    init_real_funcs();
    
    va_list args;
    va_start(args, cmd);
    void *arg = va_arg(args, void *);
    va_end(args);
    
    return real_fcntl(fd, cmd, arg);
}

int dup(int oldfd) {
    init_real_funcs();
    return real_dup(oldfd);
}

int dup2(int oldfd, int newfd) {
    init_real_funcs();
    return real_dup2(oldfd, newfd);
}

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
