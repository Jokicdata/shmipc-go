/*
 * Simple socket test program for shmipc adapter testing
 * 
 * This program tests basic socket functionality with shmipc adapter.
 * 
 * Usage: ./test_socket_basic [server|client]
 */

#include#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>

#define TEST_MESSAGE "Hello from shmipc adapter!"
#define TEST_PORT 12345
#define UNIX_SOCKET_PATH "/tmp/shmipc_test.sock"

int test_unix_socket_server(void) {
    int server_fd, client_fd;
    struct sockaddr_un addr;
    char buffer[256];
    ssize_t bytes_read;

    printf("[Server] Creating Unix domain socket...\n");
    
    /* Create socket */
    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return -1;
    }

    /* Setup address */
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, UNIX_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    /* Remove existing socket file */
    unlink(UNIX_SOCKET_PATH);

    /* Bind */
    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        return -1;
    }

    /* Listen */
    if (listen(server_fd, 5) < 0) {
        perror("listen");
        close(server_fd);
        return -1;
    }

    printf("[Server] Listening on %s\n", UNIX_SOCKET_PATH);
    printf("[Server] Waiting for connection...\n");

    /* Accept connection */
    client_fd = accept(server_fd, NULL, NULL);
    if (client_fd < 0) {
        perror("accept");
        close(server_fd);
        return -1;
    }

    printf("[Server] Client connected!\n");

    /* Receive message */
    bytes_read = recv(client_fd, buffer, sizeof(buffer) - 1, 0);
    if (bytes_read < 0) {
        perror("recv");
        close(client_fd);
        close(server_fd);
        return -1;
    }

    buffer[bytes_read] = '\0';
    printf("[Server] Received: %s (%zd bytes)\n", buffer, bytes_read);

    /* Send response */
    const char* response = "Hello from server!";
    ssize_t bytes_sent = send(client_fd, response, strlen(response), 0);
    if (bytes_sent < 0) {
        perror("send");
    } else {
        printf("[Server] Sent: %s (%zd bytes)\n", response, bytes_sent);
    }

    /* Cleanup */
    close(client_fd);
    close(server_fd);
    unlink(UNIX_SOCKET_PATH);

    printf("[Server] Test completed successfully!\n");
    return 0;
}

int test_unix_socket_client(void) {
    int client_fd;
    struct sockaddr_un addr;
    char buffer[256];
    ssize_t bytes_sent, bytes_read;

    printf("[Client] Connecting to Unix domain socket...\n");
    sleep(1);  /* Give server time to start */

    /* Create socket */
    client_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (client_fd < 0) {
        perror("socket");
        return -1;
    }

    /* Setup address */
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, UNIX_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    /* Connect */
    if (connect(client_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(client_fd);
        return -1;
    }

    printf("[Client] Connected to server!\n");

    /* Send message */
    bytes_sent = send(client_fd, TEST_MESSAGE, strlen(TEST_MESSAGE), 0);
    if (bytes_sent < 0) {
        perror("send");
        close(client_fd);
        return -1;
    }

    printf("[Client] Sent: %s (%zd bytes)\n", TEST_MESSAGE, bytes_sent);

    /* Receive response */
    bytes_read = recv(client_fd, buffer, sizeof(buffer) - 1, 0);
    if (bytes_read < 0) {
        perror("recv");
        close(client_fd);
        return -1;
    }

    buffer[bytes_read] = '\0';
    printf("[Client] Received: %s (%zd bytes)\n", buffer, bytes_read);

    /* Cleanup */
    close(client_fd);

    printf("[Client] Test completed successfully!\n");
    return 0;
}

int test_tcp_socket_server(void) {
    int server_fd, client_fd;
    struct sockaddr_in addr;
    char buffer[256];
    ssize_t bytes_read;

    printf("[Server] Creating TCP socket...\n");
    
    /* Create socket */
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return -1;
    }

    /* Setup address */
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(TEST_PORT);

    /* Set reuse address */
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    /* Bind */
    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        return -1;
    }

    /* Listen */
    if (listen(server_fd, 5) < 0) {
        perror("listen");
        close(server_fd);
        return -1;
    }

    printf("[Server] Listening on 127.0.0.1:%d\n", TEST_PORT);
    printf("[Server] Waiting for connection...\n");

    /* Accept connection */
    client_fd = accept(server_fd, NULL, NULL);
    if (client_fd < 0) {
        perror("accept");
        close(server_fd);
        return -1;
    }

    printf("[Server] Client connected!\n");

    /* Receive message */
    bytes_read = recv(client_fd, buffer, sizeof(buffer) - 1, 0);
    if (bytes_read < 0) {
        perror("recv");
        close(client_fd);
        close(server_fd);
        return -1;
    }

    buffer[bytes_read] = '\0';
    printf("[Server] Received: %s (%zd bytes)\n", buffer, bytes_read);

    /* Send response */
    const char* response = "Hello from TCP server!";
    ssize_t bytes_sent = send(client_fd, response, strlen(response), 0);
    if (bytes_sent < 0) {
        perror("send");
    } else {
        printf("[Server] Sent: %s (%zd bytes)\n", response, bytes_sent);
    }

    /* Cleanup */
    close(client_fd);
    close(server_fd);

    printf("[Server] Test completed successfully!\\n");
    return 0;
}

int test_tcp_socket_client(void) {
    int client_fd;
    struct sockaddr_in addr;
    char buffer[256];
    ssize_t bytes_sent, bytes_read;

    printf("[Client] Connecting to TCP socket...\n");
    sleep(1);  /* Give server time to start */

    /* Create socket */
    client_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (client_fd < 0) {
        perror("socket");
        return -1;
    }

    /* Setup address */
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(TEST_PORT);

    /* Connect */
    if (connect(client_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(client_fd);
        return -1;
    }

    printf("[Client] Connected to server!\n");

    /* Send message */
    bytes_sent = send(client_fd, TEST_MESSAGE, strlen(TEST_MESSAGE), 0);
    if (bytes_sent < 0) {
        perror("send");
        close(client_fd);
        return -1;
    }

    printf("[Client] Sent: %s (%zd bytes)\n", TEST_MESSAGE, bytes_sent);

    /* Receive response */
    bytes_read = recv(client_fd, buffer, sizeof(buffer) - 1, 0);
    if (bytes_read < 0) {
        perror("recv");
        close(client_fd);
        return -1;
    }

    buffer[bytes_read] = '\0';
    printf("[Client] Received: %sars (%zd bytes)\n", buffer, bytes_read);

    /* Cleanup */
    close(client_fd);

    printf("[Client] Test completed successfully!\n");
    return 0;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        printf("Usage: %s [unix_server|unix_client|tcp_server|tcp_client]\n", argv[0]);
        printf("\n");
        printf("Tests:\n");
        printf("  unix_server  - Test Unix domain socket server\n");
        printf("  unix_client  - Test Unix domain socket client\n");
        printf("  tcp_server   - Test TCP localhost server\n");
        printf("  tcp_client   - Test TCP localhost client\n");
        printf("\n");
        printf("Environment variables:\n");
        printf("  SHMIPC_ENABLED  - Enable shmipc adapter (1/true/yes)\n");
        printf("  SHMIPC_CONFIG   - Configuration for shmipc\n");
        printf("\n");
        printf("Examples:\n");
        printf("  # Terminal 1: Start server\n");
        printf("  SHMIPC_ENABLED=1 LD_PRELOAD=./libshmipc_adapter.so:./libshmipc_go.so %s unix_server\n", argv[0]);
        printf("\n");
        printf("  # Terminal 2: Start client\n");
        printf("  SHMIPC_ENABLED=1 LD_PRELOAD=./libshmipc_adapter.so:./libshmipc_go.so %s unix_client\n", argv[0]);
        printf("\n");
        return 1;
    }

    const char* test_type = argv[1];
    int result = 0;

    printf("========================================\n");
    printf("Shmipc Adapter Test Program\n");
    printf("========================================\n");
    printf("Test type: %s\n", test_type);
    printf("Shmipc enabled: %s\n", getenv("SHMIPC_ENABLED") ? "yes" : "no");
    printf("========================================\n");
    printf("\n");

    if (strcmp(test_type, "unix_server") == 0) {
        result = test_unix_socket_server();
    } else if (strcmp(test_type, "unix_client") == 0) {
        result = test_unix_socket_client();
    } else if (strcmp(test_type, "tcp_server") == 0) {
        result = test_tcp_socket_server();
    } else if (strcmp(test_type, "tcp_client") == 0) {
        result = test_tcp_socket_client();
    } else {
        printf("Unknown test type: %s\n", test_type);
        result = 1;
    }

    return result;
}