#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>

static struct termios original_stdin;
static bool stdin_changed = false;

static void restore_stdin(void) {
    if (stdin_changed) {
        tcsetattr(STDIN_FILENO, TCSANOW, &original_stdin);
    }
}

static int make_stdin_raw(void) {
    if (tcgetattr(STDIN_FILENO, &original_stdin) != 0) return -1;
    struct termios raw = original_stdin;
    cfmakeraw(&raw);
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) return -1;
    stdin_changed = true;
    atexit(restore_stdin);
    return 0;
}

static int write_all(int descriptor, const uint8_t *bytes, size_t count) {
    size_t written = 0;
    while (written < count) {
        ssize_t result = write(descriptor, bytes + written, count - written);
        if (result > 0) {
            written += (size_t)result;
        } else if (result < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return 0;
}

static int connect_tcp(const char *host, const char *port) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    struct addrinfo *addresses = NULL;
    int lookup = getaddrinfo(host, port, &hints, &addresses);
    if (lookup != 0) {
        fprintf(stderr, "Telnet: cannot resolve %s: %s\r\n", host, gai_strerror(lookup));
        return -1;
    }

    int connected = -1;
    for (struct addrinfo *address = addresses; address != NULL; address = address->ai_next) {
        int candidate = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (candidate < 0) continue;
        if (connect(candidate, address->ai_addr, address->ai_addrlen) == 0) {
            connected = candidate;
            break;
        }
        close(candidate);
    }
    freeaddrinfo(addresses);
    if (connected < 0) {
        fprintf(stderr, "Telnet: cannot connect to %s:%s: %s\r\n", host, port, strerror(errno));
    }
    return connected;
}

enum telnet_state { TELNET_DATA, TELNET_IAC, TELNET_OPTION, TELNET_SUBNEGOTIATION, TELNET_SUB_IAC };

static int telnet_output(int socket_fd, const uint8_t *input, size_t count) {
    static enum telnet_state state = TELNET_DATA;
    static uint8_t command = 0;
    uint8_t output[8192];
    size_t output_count = 0;

    for (size_t index = 0; index < count; index++) {
        uint8_t byte = input[index];
        switch (state) {
            case TELNET_DATA:
                if (byte == 255) state = TELNET_IAC;
                else output[output_count++] = byte;
                break;
            case TELNET_IAC:
                if (byte == 255) {
                    output[output_count++] = 255;
                    state = TELNET_DATA;
                } else if (byte == 251 || byte == 252 || byte == 253 || byte == 254) {
                    command = byte;
                    state = TELNET_OPTION;
                } else if (byte == 250) {
                    state = TELNET_SUBNEGOTIATION;
                } else {
                    state = TELNET_DATA;
                }
                break;
            case TELNET_OPTION: {
                uint8_t response[3] = {255, 0, byte};
                if (command == 251) {
                    response[1] = (byte == 1 || byte == 3) ? 253 : 254;
                } else if (command == 253) {
                    response[1] = (byte == 3) ? 251 : 252;
                } else if (command == 252) {
                    response[1] = 254;
                } else {
                    response[1] = 252;
                }
                if (write_all(socket_fd, response, sizeof(response)) != 0) return -1;
                state = TELNET_DATA;
                break;
            }
            case TELNET_SUBNEGOTIATION:
                if (byte == 255) state = TELNET_SUB_IAC;
                break;
            case TELNET_SUB_IAC:
                state = byte == 240 ? TELNET_DATA : TELNET_SUBNEGOTIATION;
                break;
        }
        if (output_count == sizeof(output)) {
            if (write_all(STDOUT_FILENO, output, output_count) != 0) return -1;
            output_count = 0;
        }
    }
    return output_count == 0 ? 0 : write_all(STDOUT_FILENO, output, output_count);
}

static int bridge_descriptors(int remote_fd, bool telnet) {
    uint8_t buffer[8192];
    while (true) {
        fd_set readers;
        FD_ZERO(&readers);
        FD_SET(STDIN_FILENO, &readers);
        FD_SET(remote_fd, &readers);
        int maximum = remote_fd > STDIN_FILENO ? remote_fd : STDIN_FILENO;
        int ready = select(maximum + 1, &readers, NULL, NULL, NULL);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return 1;
        }
        if (FD_ISSET(STDIN_FILENO, &readers)) {
            ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
            if (count <= 0) return 0;
            if (write_all(remote_fd, buffer, (size_t)count) != 0) return 1;
        }
        if (FD_ISSET(remote_fd, &readers)) {
            ssize_t count = read(remote_fd, buffer, sizeof(buffer));
            if (count == 0) return 0;
            if (count < 0) {
                if (errno == EINTR) continue;
                return 1;
            }
            int result = telnet
                ? telnet_output(remote_fd, buffer, (size_t)count)
                : write_all(STDOUT_FILENO, buffer, (size_t)count);
            if (result != 0) return 1;
        }
    }
}

static speed_t serial_speed(int value) {
    switch (value) {
        case 300: return B300;
        case 600: return B600;
        case 1200: return B1200;
        case 2400: return B2400;
        case 4800: return B4800;
        case 9600: return B9600;
        case 19200: return B19200;
        case 38400: return B38400;
        case 57600: return B57600;
        case 115200: return B115200;
#ifdef B230400
        case 230400: return B230400;
#endif
        default: return 0;
    }
}

static int run_serial(int argc, char **argv) {
    if (argc != 8) {
        fprintf(stderr, "Usage: bridge serial DEVICE BAUD DATA_BITS PARITY STOP_BITS FLOW\r\n");
        return 64;
    }
    const char *device = argv[2];
    int baud = atoi(argv[3]);
    int data_bits = atoi(argv[4]);
    const char *parity = argv[5];
    int stop_bits = atoi(argv[6]);
    const char *flow = argv[7];
    speed_t speed = serial_speed(baud);
    if (strncmp(device, "/dev/cu.", 8) != 0 || speed == 0 || data_bits < 5 || data_bits > 8
        || (stop_bits != 1 && stop_bits != 2)) {
        fprintf(stderr, "Serial: invalid configuration.\r\n");
        return 64;
    }

    int descriptor = open(device, O_RDWR | O_NOCTTY);
    if (descriptor < 0) {
        fprintf(stderr, "Serial: cannot open %s: %s\r\n", device, strerror(errno));
        return 66;
    }
    if (ioctl(descriptor, TIOCEXCL) != 0) {
        fprintf(stderr, "Serial: device %s is already in use.\r\n", device);
        close(descriptor);
        return 73;
    }

    struct termios options;
    if (tcgetattr(descriptor, &options) != 0) {
        fprintf(stderr, "Serial: cannot read device settings: %s\r\n", strerror(errno));
        close(descriptor);
        return 74;
    }
    cfmakeraw(&options);
    cfsetispeed(&options, speed);
    cfsetospeed(&options, speed);
    options.c_cflag &= ~CSIZE;
    options.c_cflag |= data_bits == 5 ? CS5 : data_bits == 6 ? CS6 : data_bits == 7 ? CS7 : CS8;
    options.c_cflag |= CLOCAL | CREAD;
    if (strcmp(parity, "even") == 0) {
        options.c_cflag |= PARENB;
        options.c_cflag &= ~PARODD;
    } else if (strcmp(parity, "odd") == 0) {
        options.c_cflag |= PARENB | PARODD;
    } else {
        options.c_cflag &= ~(PARENB | PARODD);
    }
    if (stop_bits == 2) options.c_cflag |= CSTOPB;
    else options.c_cflag &= ~CSTOPB;
#if defined(__APPLE__)
    if (strcmp(flow, "hardware") == 0) options.c_cflag |= CCTS_OFLOW | CRTS_IFLOW;
    else options.c_cflag &= ~(CCTS_OFLOW | CRTS_IFLOW);
#elif defined(CRTSCTS)
    if (strcmp(flow, "hardware") == 0) options.c_cflag |= CRTSCTS;
    else options.c_cflag &= ~CRTSCTS;
#endif
    if (strcmp(flow, "software") == 0) options.c_iflag |= IXON | IXOFF;
    else options.c_iflag &= ~(IXON | IXOFF | IXANY);
    options.c_cc[VMIN] = 1;
    options.c_cc[VTIME] = 0;
    if (tcsetattr(descriptor, TCSANOW, &options) != 0) {
        fprintf(stderr, "Serial: cannot apply device settings: %s\r\n", strerror(errno));
        close(descriptor);
        return 74;
    }
    make_stdin_raw();
    int result = bridge_descriptors(descriptor, false);
    close(descriptor);
    return result;
}

static int run_telnet(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "Usage: bridge telnet HOST PORT\r\n");
        return 64;
    }
    int descriptor = connect_tcp(argv[2], argv[3]);
    if (descriptor < 0) return 69;
    make_stdin_raw();
    fprintf(stderr, "Connected to %s:%s via Telnet. Traffic is not encrypted.\r\n", argv[2], argv[3]);
    int result = bridge_descriptors(descriptor, true);
    close(descriptor);
    return result;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    if (argc < 2) return 64;
    if (strcmp(argv[1], "telnet") == 0) return run_telnet(argc, argv);
    if (strcmp(argv[1], "serial") == 0) return run_serial(argc, argv);
    fprintf(stderr, "Unknown transport.\r\n");
    return 64;
}
