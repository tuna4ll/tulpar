// Loads the driver for a device that appears after boot, as udev would: the kernel
// announces each device over netlink with its MODALIAS, and modprobe finds the module
// whose alias matches. Devices present at boot are handled by /etc/runit/1.

#include <linux/netlink.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
    int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_KOBJECT_UEVENT);
    struct sockaddr_nl address = {.nl_family = AF_NETLINK, .nl_groups = 1};
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        perror("tulpar-hotplug: uevent socket");
        return 1;
    }
    signal(SIGCHLD, SIG_IGN);  // children are reaped by the kernel

    static char buffer[8192];
    for (;;) {
        ssize_t got = recv(fd, buffer, sizeof(buffer) - 1, 0);
        if (got <= 0) continue;
        buffer[got] = '\0';
        const char *action = NULL, *modalias = NULL;
        for (char *at = buffer; at < buffer + got; at += strlen(at) + 1) {
            if (strncmp(at, "ACTION=", 7) == 0) action = at + 7;
            else if (strncmp(at, "MODALIAS=", 9) == 0) modalias = at + 9;
        }
        if (!action || !modalias || strcmp(action, "add") != 0) continue;
        if (fork() == 0) {
            execl("/usr/bin/modprobe", "modprobe", "-q", "-b", modalias, (char *)NULL);
            _exit(127);
        }
    }
}
