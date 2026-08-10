#if !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif

#include "PTYBridge.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

pid_t selectiveremote_spawn_pty(
    const char *executable,
    char *const argv[],
    char *const envp[],
    uint16_t columns,
    uint16_t rows,
    int *master_fd
) {
    if (executable == NULL || argv == NULL || master_fd == NULL) {
        errno = EINVAL;
        return -1;
    }

    struct winsize size = {
        .ws_row = rows > 0 ? rows : 24,
        .ws_col = columns > 0 ? columns : 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0
    };
    int primary = -1;
    const pid_t child = forkpty(&primary, NULL, NULL, &size);
    if (child < 0) {
        return -1;
    }
    if (child == 0) {
        if (envp != NULL) {
            execve(executable, argv, envp);
        } else {
            execv(executable, argv);
        }
        _exit(127);
    }

    (void)fcntl(primary, F_SETFD, FD_CLOEXEC);
    const int flags = fcntl(primary, F_GETFL);
    if (flags >= 0) {
        (void)fcntl(primary, F_SETFL, flags | O_NONBLOCK);
    }
    *master_fd = primary;
    return child;
}

int selectiveremote_resize_pty(int master_fd, uint16_t columns, uint16_t rows) {
    if (master_fd < 0 || columns == 0 || rows == 0) {
        errno = EINVAL;
        return -1;
    }
    const struct winsize size = {
        .ws_row = rows,
        .ws_col = columns,
        .ws_xpixel = 0,
        .ws_ypixel = 0
    };
    return ioctl(master_fd, TIOCSWINSZ, &size);
}

int selectiveremote_signal_pty(pid_t process_id, int signal_number) {
    if (process_id <= 0) {
        errno = EINVAL;
        return -1;
    }
    if (kill(-process_id, signal_number) == 0) {
        return 0;
    }
    if (errno != ESRCH) {
        return -1;
    }
    return kill(process_id, signal_number);
}

int selectiveremote_wait_pty(pid_t process_id, int *exit_code) {
    if (process_id <= 0 || exit_code == NULL) {
        errno = EINVAL;
        return -1;
    }

    int status = 0;
    pid_t result;
    do {
        result = waitpid(process_id, &status, 0);
    } while (result < 0 && errno == EINTR);
    if (result < 0) {
        return -1;
    }

    if (WIFEXITED(status)) {
        *exit_code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        *exit_code = 128 + WTERMSIG(status);
    } else {
        *exit_code = status;
    }
    return 0;
}
