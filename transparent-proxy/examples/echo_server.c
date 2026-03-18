/*
 * Simple echo server using Unix Domain Socket
 * This program will be transparently intercepted by shmipc
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>

#define SOCKET_PATH "/tmp/shmipc_echo.sock"
#define BUFFER_SIZE 4096

static int running = 1;

void signal_handler(int sig) {
    (void)sig;
    running = 0;
}

int main(int argc, char *argv[]) {
    int server_fd, client_fd;
    struct sockaddr_un addr;
    char buffer[BUFFER_SIZE];
    ssize_t bytes_read;
    
    printf("[Echo Server] Starting...\n");
    
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Create socket
    if ((server_fd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
        perror("socket");
        exit(1);
    }
    
    // Remove existing socket file
    unlink(SOCKET_PATH);
    
    // Bind
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);
    
    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) == -1) {
        perror("bind");
        close(server_fd);
        exit(1);
    }
    
    // Listen
    if (listen(server_fd, 5) == -1) {
        perror("listen");
        close(server_fd);
        unlink(SOCKET_PATH);
        exit(1);
    }
    
    printf("[Echo Server] Listening on %s\n", SOCKET_PATH);
    printf("[Echo Server] Waiting for connections...\n");
    
    while (running) {
        struct sockaddr_un client_addr;
        socklen_t client_len = sizeof(client_addr);
        
        // Accept
        if ((client_fd = accept(server_fd, (struct sockaddr*)&client_addr, &client_len)) == -1) {
            if (running) perror("accept");
            continue;
        }
        
        printf("[Echo Server] Client connected\n");
        
        // Echo loop
        while (running) {
            bytes_read = read(client_fd, buffer, BUFFER_SIZE - 1);
            if (bytes_read <= 0) {
                break;
            }
            
            buffer[bytes_read] = '\0';
            printf("[Echo Server] Received: %s", buffer);
            
            // Echo back
            if (write(client_fd, buffer, bytes_read) != bytes_read) {
                perror("write");
                break;
            }
        }
        
        close(client_fd);
        printf("[Echo Server] Client disconnected\n");
    }
    
    close(server_fd);
    unlink(SOCKET_PATH);
    printf("[Echo Server] Shutting down\n");
    
    return 0;
}
