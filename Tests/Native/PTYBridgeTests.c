#if !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif

#include "PTYBridge.h"

#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void wait_for_output(int descriptor, const char *needle) {
    char output[4096] = {0};
    size_t total = 0;
    while (strstr(output, needle) == NULL) {
        struct pollfd item = {
            .fd = descriptor,
            .events = POLLIN,
            .revents = 0
        };
        int poll_result;
        do {
            poll_result = poll(&item, 1, 5000);
        } while (poll_result < 0 && errno == EINTR);
        assert(poll_result > 0);
        assert((item.revents & (POLLIN | POLLHUP)) != 0);
        ssize_t count;
        do {
            count = read(
                descriptor,
                output + total,
                sizeof(output) - 1 - total
            );
        } while (count < 0 && errno == EINTR);
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            assert((item.revents & POLLHUP) == 0);
            continue;
        }
        assert(count > 0);
        total += (size_t)count;
        assert(total < sizeof(output) - 1);
        output[total] = '\0';
    }
}

static void write_all(int descriptor, const char *value) {
    const size_t length = strlen(value);
    size_t total = 0;
    while (total < length) {
        struct pollfd item = {
            .fd = descriptor,
            .events = POLLOUT,
            .revents = 0
        };
        int poll_result;
        do {
            poll_result = poll(&item, 1, 5000);
        } while (poll_result < 0 && errno == EINTR);
        assert(poll_result > 0);
        assert((item.revents & POLLOUT) != 0);

        ssize_t count;
        do {
            count = write(descriptor, value + total, length - total);
        } while (count < 0 && errno == EINTR);
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        assert(count > 0);
        total += (size_t)count;
    }
}

static int run_pty_child(void) {
    const int ready_result = fputs("pty-ready\n", stdout);
    assert(ready_result >= 0);
    const int ready_flush_result = fflush(stdout);
    assert(ready_flush_result == 0);

    char input[128] = {0};
    size_t total = 0;
    while (strstr(input, "pty-input") == NULL) {
        ssize_t count;
        do {
            count = read(
                STDIN_FILENO,
                input + total,
                sizeof(input) - 1 - total
            );
        } while (count < 0 && errno == EINTR);
        if (count <= 0) {
            return 1;
        }
        total += (size_t)count;
        if (total >= sizeof(input) - 1) {
            return 1;
        }
        input[total] = '\0';
    }

    const int output_result = fputs("pty-ok\n", stdout);
    assert(output_result >= 0);
    const int output_flush_result = fflush(stdout);
    assert(output_flush_result == 0);
    return 0;
}

static void test_bidirectional_io_and_resize(char *executable_path) {
    char *arguments[] = {executable_path, "--pty-child", NULL};
    char *environment[] = {"TERM=xterm-256color", NULL};
    int primary = -1;
    const pid_t child = selectiveremote_spawn_pty(
        arguments[0],
        arguments,
        environment,
        NULL,
        120,
        40,
        &primary
    );
    assert(child > 0);
    assert(primary >= 0);
    assert(selectiveremote_resize_pty(primary, 100, 30) == 0);
    wait_for_output(primary, "pty-ready");
    write_all(primary, "pty-input\r");
    wait_for_output(primary, "pty-ok");

    int exit_code = -1;
    assert(selectiveremote_wait_pty(child, &exit_code) == 0);
    close(primary);
    assert(exit_code == 0);
}

int main(int argument_count, char *arguments[]) {
    if (
        argument_count == 2
        && strcmp(arguments[1], "--pty-child") == 0
    ) {
        return run_pty_child();
    }

    assert(argument_count > 0);
    alarm(15);
    char executable_path[PATH_MAX];
    char *const resolved_path = realpath(arguments[0], executable_path);
    assert(resolved_path != NULL);
    test_bidirectional_io_and_resize(executable_path);
    alarm(0);
    puts("[SelectiveRemote] PTY bridge test passed");
    return 0;
}
