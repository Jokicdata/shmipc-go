/*
 * Example application demonstrating shmipc adapter usage
 * 
 * This is a simple echo server/client that can work with or without
 * the shmipc adapter, demonstrating transparent adaptation.
 * 
 * Usage: ./example_app [server|client] [port]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>

#define DEFAULT_PORT 12345
#define MAX_CONNECTIONS 100
#define BUFFER_SIZE 65536

volatile int running = 1;

typedef struct {
    int client_fd;
    int server_fd;
    struct sockaddr_in client_addr;
} connection_info_t;

void signal_handler(int sig) {
    printf("\n[Server] Received signal %d, shutting down...\n", sig);
    running = 0;
}

void handle_client(void* arg) {
    connection_info_t* conn_info = (connection_info_t*)arg;
    int client_fd = conn_info->client_fd;
    char client_ip[INET_ADDRSTRLEN];
    
    inet_ntop(AF_INET, &conn_info->client_addr.sin_addr, client_ip, sizeof(client_ip));
    printf("[Server] New connection from %s:%d\n", 
           client_ip, ntohs(conn_info->client_addr.sin_port));
    
    char buffer[BUFFER_SIZE];
    ssize_t bytes_received, bytes_sent;
    long total_bytes = 0;
    
    while (running) {
        // Receive data
        bytes_received = recv(client_fd, buffer, sizeof(buffer), 0);
        
        if (bytes_received <= 0) {
            if (bytes_received < 0) {
                perror("[Server] recv error");
            } else {
                printf("[Server] Client disconnected\n");
            }
            break;
        }
        
        total_bytes += bytes_received;
        
        // Echo data back
        bytes_sent = send(client_fd, buffer, bytes_received, 0);
        
        if (bytes_sent < 0) {
            perror("[Server] send error");
            break;
        }
        
        if (bytes_sent != bytes_received) {
            printf("[Server] Warning: Only sent %zd of %zd bytes\n", 
                   bytes_sent, bytes_received);
        }
    }
    
    printf("[Server] Connection closed, total bytes transferred: %ld\n", total_bytes);
    close(client_fd);
    free(conn_info);
    pthread_exit(NULL);
}

int run_server(int port) {
    int server_fd, client_fd;
    struct sockaddr_in server_addr, client_addr;
    socklen_t client_len = sizeof(client_addr);
    pthread_t threads[MAX_CONNECTIONS];
    int thread_count = 0;
    
    printf("[Server] Starting echo server on port %d\n", port);
    
    // Setup signal handler
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Create socket
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("[Server] socket creation failed");
        return -1;
    }
    
    // Set socket options
    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        perror("[Server] setsockopt SO_REUSEADDR failed");
        close(server_fd);
        return -1;
    }
    
    // Setup address
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    server_addr.sin_port = htons(port);
    
    // Bind
    if (bind(server_fd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("[Server] bind failed");
        close(server_fd);
        return -1;
    }
    
    // Listen
    if (listen(server_fd, 10) < 0) {
        perror("[Server] listen failed");
        close(server_fd);
        return -1;
    }
    
    printf("[Server] Server listening on 127.0.0.1:%d\n", port);
    printf("[Server] Press Ctrl+C to stop\n");
    
    // Accept connections
    while (running && thread_count < MAX_CONNECTIONS) {
        client_len = sizeof(client_addr);
        client_fd = accept(server_fd, (struct sockaddr*)&client_addr, &client_len);
        
        if (client_fd < 0) {
            if (running) {
                perror("[Server] accept failed");
            }
            continue;
        }
        
        // Create connection info
        connection_info_t* conn_info = malloc(sizeof(connection_info_t));
        conn_info->client_fd = client_fd;
        conn_info->server_fd = server_fd;
        memcpy(&conn_info->client_addr, &client_addr, sizeof(client_addr));
        
        // Create thread to handle client
        if (pthread_create(&threads[thread_count], NULL, (void*)handle_client, conn_info) != 0) {
            perror("[Server] pthread_create failed");
            free(conn_info);
            close(client_fd);
            continue;
        }
        
        thread_count++;
    }
    
    // Wait for all threads to finish
    for (int i = 0; i < thread_count; i++) {
        pthread_join(threads[i], NULL);
    }
    
    printf[Server] Server shutting down\n");
    close(server_fd);
    return 0;
}

int run_client(int port) {
    int client_fd;
    struct sockaddr_in server_addr;
    char buffer[BUFFER_SIZE];
    ssize_t bytes_sent, bytes_received;
    long total_bytes = 0;
    int iterations = 0;
    
    printf("[Client] Connecting to server 127.0.0.1:%d\n", port);
    
    // Create socket
    client_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (client_fd < 0) {
        perror("[Client] socket creation failed");
        return -1;
    }
    
    // Setup address
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    server_addr.sin_port = htons(port);
    
    // Connect
    if (connect(client_fd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("[Client] connect failed");
        close(client_fd);
        return -1;
    }
    
    printf("[Client] Connected to server\n");
    printf("[Client] Starting echo test (10 iterations, 64KB per iteration)\n");
    
    // Run echo test
    for (int i = 0; i < 10; i++) {
        // Prepare data
        int data_size = 64 * 1024;  // 64KB
        for (int j = 0; j < data_size; j++) {
            buffer[j] = 'A' + (j % 26);
        }
        
        // Send data
        bytes_sent = send(client_fd, buffer, data_size, 0);
        if (bytes_sent < 0) {
            perror("[Client] send failed");
            break;
        }
        
        // Receive echo
        bytes_received = recv(client_fd, buffer, sizeof(buffer), 0);
        if (bytes_received < 0) {
            perror("[Client] recv failed");
            break;
        }
        
        total_bytes += bytes_received;
        iterations++;
        
        if (i % 2 == 0) {
            printf("[Client] Progress: %d/10 iterations, %ld KB transferred\n", 
                   i + 1, total_bytes / 1024);
        }
        
        usleep(100000);  // 100ms delay
    }
    
    printf("[Client] Test completed\n");
    printf("[Client] Total iterations: %d\n", iterations);
    printf("[Client] Total bytes transferred: %ld KB\n", total_bytes / 1024);
    
    close(client_fd);
    return 0;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        printf("Shmipc Adapter Example Application\n");
        printf("=================================\n");
        printf("Usage: %s [server|client] [port]\n\n", argv[0]);
        printf("Arguments:\n");
        printf("  server  - Run echo server\n");
        printf("  client  - Run echo client\n");
        printf("  port    - Port number (default: %d)\n\n", DEFAULT_PORT);
        printf("Environment variables:\n");
        printf("  SHMIPC_ENABLED  - Enable shmipc adapter (1/true/yes)\n");
        printf("  SHMIPC_CONFIG   - Configuration for shmipc\n\n");
        printf("Examples:\n");
        printf("  # Terminal 1: Start server\n");
        printf("  export SHMIPC_ENABLED=1\n");
        printf("  export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so\n");
        printf("  %s server %d\n\n", argv[0], DEFAULT_PORT);
        printf("  # Terminal 2: Start client\n");
        printf("  export SHMIPC_ENABLED=1\n");
        printf("  export LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so\n");
        printf("  %s client %d\n", argv[0], DEFAULT_PORT);
        printf("\n");
        printf("Performance comparison:\n");
        printf("  # Without shmipc (baseline)\n");
        printf("  %s server %d &\n", argv[0], DEFAULT_PORT);
        printf("  %s client %d\n\n", argv[0], DEFAULT_PORT);
        printf("  # With shmipc (high performance)\n");
        printf("  SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so \\\n");
        printf("    %s server %d &\n", argv[0], DEFAULT_PORT);
        printf("  SHMIPC_ENABLED=1 LD_PRELOAD=./lib/libshmipc_adapter.so:./lib/libshmipc_go.so \\\n");
        printf("    %s client %d\n", argv[0], DEFAULT_PORT);
        printf("\n");
        return 1;
    }
    
    const char* mode = argv[1];
    int port = (argc >= 3) ? atoi(argv[2]) : DEFAULT_PORT;
    
    printf("========================================\n");
    printf("Shmipc Adapter Example Application\n");
    printf("========================================\n");
    printf("Mode: %s\n", mode);
    printf("Port: %d\n", port);
    printf("Shmipc enabled: %s\n", getenv("SHMIPC_ENABLED") ? "yes" : "no");
    printf("========================================\n\n");
    
    int result = 0;
    
    if (strcmp(mode, "server") == 0) {
        result = run_server(port);
    } else if (strcmp(mode, "client") == 0) {
        result = run_client(port);
    } else {
        printf("Error: Invalid mode '%s'. Use 'server' or 'client'.\n", mode);
        result = 1;
    }
    
    return result;
}