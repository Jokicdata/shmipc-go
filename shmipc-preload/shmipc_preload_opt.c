/*
 * shmipc-preload - shmipc 透明代理 (优化版)
 *
 * 功能：通过 LD_PRELOAD 劫持 socket API，自动将本地 IPC 连接转换为 shmipc 连接
 *
 * 优化点：
 * 1. 支持 writev/readv 批量操作
 * 2. 减少锁竞争 (per-FD 锁)
 * 3. 优化数据路径，避免不必要的拷贝
 * 4. 完善的回退机制：shmipc 失败时自动回退到原始 socket
 * 5. 低开销统计日志：异步写入，不影响数据路径性能
 *
 * 使用方式：
 *   LD_PRELOAD=./libshmipc.so <your-program>
 *
 * 环境变量：
 *   SHMIPC_LOG=0|1|2|3|4  日志级别 (0=静默 1=ERROR 2=WARN 3=INFO 4=DEBUG)
 *   SHMIPC_ENABLE=0|1     是否启用 shmipc (默认 1)
 *   SHMIPC_STATS=1        启用统计日志 (默认关闭)
 *   SHMIPC_STATS_FILE=路径 统计日志文件 (默认 /tmp/shmipc_stats.log)
 *   SHMIPC_STATS_INTERVAL=秒 统计日志输出间隔 (默认 10)
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
#include <sys/uio.h>
#include <sys/time.h>

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

/* ========== 回退原因 ========== */
#define FALLBACK_NONE            0
#define FALLBACK_INIT_FAILED     1
#define FALLBACK_NOT_LOCAL       2
#define FALLBACK_SESSION_FAILED  3
#define FALLBACK_STREAM_FAILED   4
#define FALLBACK_WRITE_FAILED    5
#define FALLBACK_READ_FAILED     6

static const char *fallback_reasons[] = {
    "none",
    "init_failed",
    "not_local_addr",
    "session_create_failed",
    "stream_open_failed",
    "write_failed",
    "read_failed"
};

/* ========== 外部 Go 函数声明 ========== */
extern int ShmipcInit(void);
extern void ShmipcCleanup(void);
extern int ShmipcCreateClientSession(int fd, const char *path);
extern int ShmipcCreateServerSession(int fd, const char *path);
extern int ShmipcOpenStream(int fd);
extern int ShmipcAcceptStream(int fd);
extern long ShmipcWrite(int stream_id, const void *data, long length);
extern long ShmipcWriteVectored(int stream_id, const struct iovec *iov, int iovcnt);
extern long ShmipcRead(int stream_id, void *data, long length);
extern long ShmipcReadVectored(int stream_id, const struct iovec *iov, int iovcnt);
extern int ShmipcFlush(int stream_id);
extern int ShmipcCloseStream(int stream_id);
extern int ShmipcCloseSession(int fd);
extern int ShmipcGetStats(void *stats);

/* ========== 全局状态 ========== */
static int g_log_level = LOG_ERROR;
static int g_initialized = 0;
static int g_shmipc_enabled = 1;
static int g_stats_enabled = 0;
static int g_stats_interval = 10;
static char g_stats_file[512] = "/tmp/shmipc_stats.log";
static int g_stats_fd = -1;
static pthread_t g_stats_thread = 0;
static volatile int g_stats_running = 0;

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
    int fallback_reason;
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
    uint64_t fallback_connections;
    uint64_t total_bytes_sent;
    uint64_t total_bytes_recv;
    uint64_t shmipc_bytes_sent;
    uint64_t shmipc_bytes_recv;
    uint64_t socket_bytes_sent;
    uint64_t socket_bytes_recv;
    uint64_t vectored_write_count;
    uint64_t vectored_read_count;
    uint64_t shmipc_write_calls;
    uint64_t shmipc_read_calls;
    uint64_t socket_write_calls;
    uint64_t socket_read_calls;
    uint64_t shmipc_write_errors;
    uint64_t shmipc_read_errors;
    uint64_t fallback_reason_counts[7];
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

/* ========== 获取时间戳字符串（用于统计日志）========== */
static void get_timestamp(char *buf, size_t len) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm_val;
    localtime_r(&tv.tv_sec, &tm_val);
    snprintf(buf, len, "%04d-%02d-%02d %02d:%02d:%02d.%03ld",
             tm_val.tm_year + 1900, tm_val.tm_mon + 1, tm_val.tm_mday,
             tm_val.tm_hour, tm_val.tm_min, tm_val.tm_sec,
             tv.tv_usec / 1000);
}

/* ========== 统计日志写入（低开销：只写文件，不格式化到 stderr）========== */
static void stats_log(const char *msg) {
    if (g_stats_fd < 0) return;
    int len = strlen(msg);
    write(g_stats_fd, msg, len);
}

/* ========== 统计线程（定期输出统计信息到文件）========== */
static void *stats_thread_func(void *arg) {
    (void)arg;
    char buf[2048];
    char ts[64];

    while (g_stats_running) {
        sleep(g_stats_interval);

        get_timestamp(ts, sizeof(ts));

        int n = snprintf(buf, sizeof(buf),
            "[%s] STATS\n"
            "  connections: total=%lu shmipc=%lu socket=%lu fallback=%lu\n"
            "  shmipc_traffic: sent=%lu bytes (%lu calls) recv=%lu bytes (%lu calls)\n"
            "  socket_traffic: sent=%lu bytes (%lu calls) recv=%lu bytes (%lu calls)\n"
            "  errors: write_errors=%lu read_errors=%lu\n"
            "  fallback_reasons: init=%lu not_local=%lu session=%lu stream=%lu write=%lu read=%lu\n"
            "  vectored: writes=%lu reads=%lu\n"
            "  shmipc_ratio: sent=%.1f%% recv=%.1f%%\n",
            ts,
            (unsigned long)g_stats.total_connections,
            (unsigned long)g_stats.shmipc_connections,
            (unsigned long)g_stats.socket_connections,
            (unsigned long)g_stats.fallback_connections,
            (unsigned long)g_stats.shmipc_bytes_sent,
            (unsigned long)g_stats.shmipc_write_calls,
            (unsigned long)g_stats.shmipc_bytes_recv,
            (unsigned long)g_stats.shmipc_read_calls,
            (unsigned long)g_stats.socket_bytes_sent,
            (unsigned long)g_stats.socket_write_calls,
            (unsigned long)g_stats.socket_bytes_recv,
            (unsigned long)g_stats.socket_read_calls,
            (unsigned long)g_stats.shmipc_write_errors,
            (unsigned long)g_stats.shmipc_read_errors,
            (unsigned long)g_stats.fallback_reason_counts[FALLBACK_INIT_FAILED],
            (unsigned long)g_stats.fallback_reason_counts[FALLBACK_NOT_LOCAL],
            (unsigned long)g_stats.fallback_reason_counts[FALLBACK_SESSION_FAILED],
            (unsigned long)g_stats.fallback_reason_counts[FALLBACK_STREAM_FAILED],
            (unsigned long)g_stats.fallback_reason_counts[FALLBACK_WRITE_FAILED],
            (unsigned long)g_stats.fallback_reason_counts[FALLBACK_READ_FAILED],
            (unsigned long)g_stats.vectored_write_count,
            (unsigned long)g_stats.vectored_read_count,
            g_stats.total_bytes_sent > 0 ?
                100.0 * g_stats.shmipc_bytes_sent / g_stats.total_bytes_sent : 0.0,
            g_stats.total_bytes_recv > 0 ?
                100.0 * g_stats.shmipc_bytes_recv / g_stats.total_bytes_recv : 0.0
        );

        if (n > 0 && n < (int)sizeof(buf)) {
            stats_log(buf);
        }
    }

    return NULL;
}

/* ========== 启动统计线程 ========== */
static void start_stats_thread(void) {
    if (!g_stats_enabled) return;

    g_stats_fd = open(g_stats_file, O_WRONLY | O_CREAT | O_APPEND | O_NONBLOCK, 0644);
    if (g_stats_fd < 0) {
        log_msg(LOG_WARN, "Failed to open stats file: %s", g_stats_file);
        return;
    }

    g_stats_running = 1;
    if (pthread_create(&g_stats_thread, NULL, stats_thread_func, NULL) != 0) {
        log_msg(LOG_WARN, "Failed to create stats thread");
        close(g_stats_fd);
        g_stats_fd = -1;
        g_stats_running = 0;
        return;
    }

    char ts[64];
    get_timestamp(ts, sizeof(ts));
    char msg[256];
    snprintf(msg, sizeof(msg), "[%s] shmipc stats logging started (interval=%ds, pid=%d)\n",
             ts, g_stats_interval, getpid());
    stats_log(msg);
}

/* ========== 停止统计线程 ========== */
static void stop_stats_thread(void) {
    if (!g_stats_running) return;

    g_stats_running = 0;
    if (g_stats_thread) {
        pthread_join(g_stats_thread, NULL);
        g_stats_thread = 0;
    }

    if (g_stats_fd >= 0) {
        char ts[64];
        get_timestamp(ts, sizeof(ts));

        char buf[2048];
        int n = snprintf(buf, sizeof(buf),
            "[%s] shmipc stats final report\n"
            "  connections: total=%lu shmipc=%lu socket=%lu fallback=%lu\n"
            "  shmipc_traffic: sent=%lu bytes (%lu calls) recv=%lu bytes (%lu calls)\n"
            "  socket_traffic: sent=%lu bytes (%lu calls) recv=%lu bytes (%lu calls)\n"
            "  errors: write_errors=%lu read_errors=%lu\n"
            "  shmipc_ratio: sent=%.1f%% recv=%.1f%%\n"
            "  shmipc stats logging stopped\n",
            ts,
            (unsigned long)g_stats.total_connections,
            (unsigned long)g_stats.shmipc_connections,
            (unsigned long)g_stats.socket_connections,
            (unsigned long)g_stats.fallback_connections,
            (unsigned long)g_stats.shmipc_bytes_sent,
            (unsigned long)g_stats.shmipc_write_calls,
            (unsigned long)g_stats.shmipc_bytes_recv,
            (unsigned long)g_stats.shmipc_read_calls,
            (unsigned long)g_stats.socket_bytes_sent,
            (unsigned long)g_stats.socket_write_calls,
            (unsigned long)g_stats.socket_bytes_recv,
            (unsigned long)g_stats.socket_read_calls,
            (unsigned long)g_stats.shmipc_write_errors,
            (unsigned long)g_stats.shmipc_read_errors,
            g_stats.total_bytes_sent > 0 ?
                100.0 * g_stats.shmipc_bytes_sent / g_stats.total_bytes_sent : 0.0,
            g_stats.total_bytes_recv > 0 ?
                100.0 * g_stats.shmipc_bytes_recv / g_stats.total_bytes_recv : 0.0
        );
        if (n > 0) write(g_stats_fd, buf, n);

        close(g_stats_fd);
        g_stats_fd = -1;
    }
}

/* ========== 回退到 socket（标记 fd 并记录原因）========== */
static void fallback_to_socket(fd_info_t *info, int reason) {
    if (info == NULL) return;

    int was_shmipc = (info->conn_type == CONN_TYPE_SHMIPC);
    info->conn_type = CONN_TYPE_SOCKET;
    info->stream_id = -1;
    info->fallback_reason = reason;

    if (was_shmipc) {
        __sync_fetch_and_add(&g_stats.fallback_connections, 1);
        __sync_fetch_and_add(&g_stats.fallback_reason_counts[reason], 1);
        __sync_fetch_and_sub(&g_stats.shmipc_connections, 1);
        __sync_fetch_and_add(&g_stats.socket_connections, 1);
        log_msg(LOG_INFO, "fd=%d fallback to socket: %s",
                info->fd, fallback_reasons[reason]);
    }
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
    info->fallback_reason = FALLBACK_NONE;
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

    if ((domain == AF_INET || domain == AF_INET6) && type == SOCK_STREAM) {
        return 1;
    }

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

    char *stats_env = getenv("SHMIPC_STATS");
    if (stats_env && strcmp(stats_env, "1") == 0) {
        g_stats_enabled = 1;
    }

    char *stats_file_env = getenv("SHMIPC_STATS_FILE");
    if (stats_file_env) {
        strncpy(g_stats_file, stats_file_env, sizeof(g_stats_file) - 1);
    }

    char *stats_interval_env = getenv("SHMIPC_STATS_INTERVAL");
    if (stats_interval_env) {
        g_stats_interval = atoi(stats_interval_env);
        if (g_stats_interval < 1) g_stats_interval = 10;
    }

    memset(g_fds, 0, sizeof(g_fds));
    memset(&g_stats, 0, sizeof(g_stats));

    int ret = ShmipcInit();
    if (ret != 0) {
        log_msg(LOG_WARN, "ShmipcInit failed: %d, fallback to socket for all connections", ret);
        g_shmipc_enabled = 0;
        __sync_fetch_and_add(&g_stats.fallback_reason_counts[FALLBACK_INIT_FAILED], 1);
    }

    start_stats_thread();

    g_initialized = 1;
    log_msg(LOG_INFO, "shmipc-preload loaded (enabled: %d, log: %d, stats: %d, pid: %d)",
            g_shmipc_enabled, g_log_level, g_stats_enabled, getpid());
}

/* ========== 库清理 ========== */
__attribute__((destructor))
static void lib_fini(void) {
    stop_stats_thread();

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
        log_msg(LOG_DEBUG, "socket(%d, %d, %d) = %d [shmipc candidate]",
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

        if (info->conn_type == CONN_TYPE_SHMIPC && info->is_server) {
            int ret = ShmipcCreateServerSession(sockfd, info->path);
            if (ret != 0) {
                log_msg(LOG_WARN, "ShmipcCreateServerSession(fd=%d) failed: %d, fallback to socket", sockfd, ret);
                fallback_to_socket(info, FALLBACK_SESSION_FAILED);
            } else {
                log_msg(LOG_INFO, "ShmipcCreateServerSession(fd=%d) OK [shmipc]", sockfd);
            }
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
                __sync_fetch_and_add(&g_stats.shmipc_connections, 1);
                log_msg(LOG_INFO, "accept(%d) = %d, stream=%d [shmipc]",
                       sockfd, client_fd, stream_id);
            } else {
                log_msg(LOG_WARN, "ShmipcAcceptStream(fd=%d) failed: %d, fallback to socket", sockfd, stream_id);
                fallback_to_socket(client_info, FALLBACK_STREAM_FAILED);
            }
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
                __sync_fetch_and_add(&g_stats.shmipc_connections, 1);
                log_msg(LOG_INFO, "accept4(%d) = %d, stream=%d [shmipc]",
                       sockfd, client_fd, stream_id);
            } else {
                log_msg(LOG_WARN, "ShmipcAcceptStream(fd=%d) failed: %d, fallback to socket", sockfd, stream_id);
                fallback_to_socket(client_info, FALLBACK_STREAM_FAILED);
            }
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

    if (info && info->conn_type == CONN_TYPE_SHMIPC) {
        if (addr && addr->sa_family == AF_UNIX) {
            struct sockaddr_un *un = (struct sockaddr_un *)addr;
            strncpy(info->path, un->sun_path, MAX_PATH - 1);
            use_shmipc = 1;
        } else if (addr && is_loopback_addr(addr, addrlen)) {
            use_shmipc = 1;
        } else {
            log_msg(LOG_INFO, "connect(%d) non-local address, fallback to socket", sockfd);
            fallback_to_socket(info, FALLBACK_NOT_LOCAL);
        }
    }

    int ret = real_connect(sockfd, addr, addrlen);

    if (ret == 0 && info) {
        info->is_connected = 1;

        if (use_shmipc && info->conn_type == CONN_TYPE_SHMIPC) {
            int shmipc_ret = ShmipcCreateClientSession(sockfd, info->path);
            if (shmipc_ret == 0) {
                int stream_id = ShmipcOpenStream(sockfd);
                if (stream_id >= 0) {
                    info->stream_id = stream_id;
                    __sync_fetch_and_add(&g_stats.shmipc_connections, 1);
                    log_msg(LOG_INFO, "connect(%d) stream=%d [shmipc]",
                           sockfd, stream_id);
                } else {
                    log_msg(LOG_WARN, "ShmipcOpenStream(fd=%d) failed: %d, fallback to socket", sockfd, stream_id);
                    fallback_to_socket(info, FALLBACK_STREAM_FAILED);
                }
            } else {
                log_msg(LOG_WARN, "ShmipcCreateClientSession(fd=%d) failed: %d, fallback to socket", sockfd, shmipc_ret);
                fallback_to_socket(info, FALLBACK_SESSION_FAILED);
            }
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
            __sync_fetch_and_add(&g_stats.shmipc_write_calls, 1);
            return (ssize_t)ret;
        }
        __sync_fetch_and_add(&g_stats.shmipc_write_errors, 1);
        log_msg(LOG_WARN, "ShmipcWrite(stream=%d) failed: %ld, fallback to socket", info->stream_id, ret);
        fallback_to_socket(info, FALLBACK_WRITE_FAILED);
    }

    ssize_t ret = real_send(sockfd, buf, len, flags);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.socket_bytes_sent, ret);
        __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
        __sync_fetch_and_add(&g_stats.socket_write_calls, 1);
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
            __sync_fetch_and_add(&g_stats.shmipc_read_calls, 1);
            return (ssize_t)ret;
        }
        __sync_fetch_and_add(&g_stats.shmipc_read_errors, 1);
        log_msg(LOG_WARN, "ShmipcRead(stream=%d) failed: %ld, fallback to socket", info->stream_id, ret);
        fallback_to_socket(info, FALLBACK_READ_FAILED);
    }

    ssize_t ret = real_recv(sockfd, buf, len, flags);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.socket_bytes_recv, ret);
        __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
        __sync_fetch_and_add(&g_stats.socket_read_calls, 1);
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
            __sync_fetch_and_add(&g_stats.shmipc_write_calls, 1);
            return (ssize_t)ret;
        }
        __sync_fetch_and_add(&g_stats.shmipc_write_errors, 1);
        log_msg(LOG_WARN, "ShmipcWrite(stream=%d) failed: %ld, fallback to socket", info->stream_id, ret);
        fallback_to_socket(info, FALLBACK_WRITE_FAILED);
    }

    ssize_t ret = real_write(fd, buf, count);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.socket_bytes_sent, ret);
        __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
        __sync_fetch_and_add(&g_stats.socket_write_calls, 1);
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
            __sync_fetch_and_add(&g_stats.shmipc_read_calls, 1);
            return (ssize_t)ret;
        }
        __sync_fetch_and_add(&g_stats.shmipc_read_errors, 1);
        log_msg(LOG_WARN, "ShmipcRead(stream=%d) failed: %ld, fallback to socket", info->stream_id, ret);
        fallback_to_socket(info, FALLBACK_READ_FAILED);
    }

    ssize_t ret = real_read(fd, buf, count);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.socket_bytes_recv, ret);
        __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
        __sync_fetch_and_add(&g_stats.socket_read_calls, 1);
    }
    return ret;
}

/* ========== writev() 劫持 - 批量写优化 ========== */
ssize_t writev(int fd, const struct iovec *iov, int iovcnt) {
    init_real_funcs();

    fd_info_t *info = get_fd_info(fd);

    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0 && iov != NULL && iovcnt > 0) {
        long ret = ShmipcWriteVectored(info->stream_id, iov, iovcnt);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_sent, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
            __sync_fetch_and_add(&g_stats.vectored_write_count, 1);
            __sync_fetch_and_add(&g_stats.shmipc_write_calls, 1);
            return (ssize_t)ret;
        }
        __sync_fetch_and_add(&g_stats.shmipc_write_errors, 1);
        log_msg(LOG_WARN, "ShmipcWriteVectored(stream=%d) failed: %ld, fallback to socket", info->stream_id, ret);
        fallback_to_socket(info, FALLBACK_WRITE_FAILED);
    }

    ssize_t ret = real_writev(fd, iov, iovcnt);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.socket_bytes_sent, ret);
        __sync_fetch_and_add(&g_stats.total_bytes_sent, ret);
        __sync_fetch_and_add(&g_stats.socket_write_calls, 1);
    }
    return ret;
}

/* ========== readv() 劫持 - 批量读优化 ========== */
ssize_t readv(int fd, const struct iovec *iov, int iovcnt) {
    init_real_funcs();

    fd_info_t *info = get_fd_info(fd);

    if (info && info->conn_type == CONN_TYPE_SHMIPC && info->stream_id >= 0 && iov != NULL && iovcnt > 0) {
        long ret = ShmipcReadVectored(info->stream_id, iov, iovcnt);
        if (ret > 0) {
            __sync_fetch_and_add(&g_stats.shmipc_bytes_recv, ret);
            __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
            __sync_fetch_and_add(&g_stats.vectored_read_count, 1);
            __sync_fetch_and_add(&g_stats.shmipc_read_calls, 1);
            return (ssize_t)ret;
        }
        __sync_fetch_and_add(&g_stats.shmipc_read_errors, 1);
        log_msg(LOG_WARN, "ShmipcReadVectored(stream=%d) failed: %ld, fallback to socket", info->stream_id, ret);
        fallback_to_socket(info, FALLBACK_READ_FAILED);
    }

    ssize_t ret = real_readv(fd, iov, iovcnt);
    if (ret > 0) {
        __sync_fetch_and_add(&g_stats.socket_bytes_recv, ret);
        __sync_fetch_and_add(&g_stats.total_bytes_recv, ret);
        __sync_fetch_and_add(&g_stats.socket_read_calls, 1);
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
