#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <dlfcn.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "sentinel")) { sleep(30); return 0; }
    if (!strcmp(argv[1], "procargs")) {
        if (argc != 3) return 2;
        int mib[] = {CTL_KERN, KERN_PROCARGS2, !strcmp(argv[2], "self") ? getpid() : atoi(argv[2])};
        char buffer[65536]; size_t count = sizeof(buffer);
        int result = sysctl(mib, 3, buffer, &count, NULL, 0);
        const char *sentinel = "SYNTHETIC_TEST_TOKEN=not-a-real-credential";
        int found = result == 0 && memmem(buffer, count, sentinel, strlen(sentinel)) != NULL;
        fprintf(stderr, "synthetic procargs result=%d errno=%d bytes=%zu sentinel_found=%d\n", result, errno, count, found);
        if (result != 0) return errno == EPERM || errno == EACCES ? 0 : 3;
        return 1;
    }
    if (!strcmp(argv[1], "service")) {
        if (argc != 4) return 2;
        int (*check)(pid_t, const char *, int, ...) = dlsym(RTLD_DEFAULT, "sandbox_check");
        if (!check) return 3;
        const int *no_report = dlsym(RTLD_DEFAULT, "SANDBOX_CHECK_NO_REPORT");
        return check(getpid(), argv[2], 2 | (no_report ? *no_report : 0), argv[3]) == 0 ? 0 : 1;
    }
    if (!strcmp(argv[1], "dns")) {
        struct addrinfo *answer = NULL;
        int result = getaddrinfo("github.com", "443", NULL, &answer);
        if (answer) freeaddrinfo(answer);
        return result == 0 ? 0 : 1;
    }
    if (argc != 4) return 2;
    int datagram = !strcmp(argv[1], "udp");
    int ipv6 = strchr(argv[2], ':') != NULL;
    int fd = socket(ipv6 ? AF_INET6 : AF_INET, datagram ? SOCK_DGRAM : SOCK_STREAM, 0);
    if (fd < 0) return 1;
    struct sockaddr_in v4 = {.sin_len = sizeof(v4), .sin_family = AF_INET, .sin_port = htons(atoi(argv[3]))};
    struct sockaddr_in6 v6 = {.sin6_len = sizeof(v6), .sin6_family = AF_INET6, .sin6_port = htons(atoi(argv[3]))};
    inet_pton(ipv6 ? AF_INET6 : AF_INET, argv[2], ipv6 ? (void *)&v6.sin6_addr : (void *)&v4.sin_addr);
    struct timeval timeout = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int result = connect(fd, ipv6 ? (struct sockaddr *)&v6 : (struct sockaddr *)&v4, ipv6 ? sizeof(v6) : sizeof(v4));
    if (result == 0 && datagram) result = send(fd, "probe", 5, 0) < 0 ? -1 : 0;
    close(fd);
    return result == 0 ? 0 : 1;
}
