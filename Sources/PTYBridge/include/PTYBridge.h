#ifndef SELECTIVEREMOTE_PTY_BRIDGE_H
#define SELECTIVEREMOTE_PTY_BRIDGE_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

pid_t selectiveremote_spawn_pty(
    const char *executable,
    char *const argv[],
    char *const envp[],
    uint16_t columns,
    uint16_t rows,
    int *master_fd
);

int selectiveremote_resize_pty(int master_fd, uint16_t columns, uint16_t rows);
int selectiveremote_signal_pty(pid_t process_id, int signal_number);
int selectiveremote_wait_pty(pid_t process_id, int *exit_code);

#ifdef __cplusplus
}
#endif

#endif
