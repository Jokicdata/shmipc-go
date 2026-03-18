/*
 * Simple echo client using Unix Domain Socket
 * This program will be transparently intercepted by shmipc
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCKET_PATH "/tmp/shmipc_echo.sock"
#define BUFFER_SIZE 4096

int main(int argc, char *argv[]) {
    int client_fd;
    struct sockaddr_un addr;
    char buffer[BUFFER_SIZE];
    ssize_t bytes_read;
    int count = 10;
    
    if (argc > 1) {
        count = atoi(argv[1]);
    }
    
    printf("[Echo Client] Starting...\n");
    
    // Create socket
    if ((client_fd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
        perror("socket");
        exit(1);
    }
    
    // Connect
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);
    
    if (connect(client_fd, (struct sockaddr*)&addr, sizeof(addr)) == -1) {
        perror("connect");
        close(client_fd);
        exit(1);
    }
    
    printf("[Echo Client] Connected to %s\n", SOCKET_PATH);
    
    // Send and receive messages
    for (int i = 0; i < count; i++) {
        snprintf(buffer, BUFFER_SIZE, "Hello from client, message %d\n", i + 1);
        size_t len = strlen(buffer);
        
        // Send
        if (write(client_fd, buffer, len) != (ssize_t)len) {
            perror("write");
            break;
        }
        
        printf("[Echo Client] Sent: %s", buffer);
        
        // Receive
        bytes_read = read(client_fd, buffer, BUFFER_SIZE - 1);
        if (bytes_read <= 0) {
            perror("read");
            break;
        }
        
        buffer[bytes_read] = '\0';
        printf("[Echo Client] Received: %s", buffer);
    }
    
    close(client_fd);
    printf("[Echo Client] Done\n");
    
    return 0;
}
