#define _POSIX_C_SOURCE 200809L
#include "ffi.h"
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static struct termios original;
static struct sigaction old_winch, old_int, old_term;
static volatile sig_atomic_t quit_requested, resized;
static int opened;

static void on_signal(int signal) {
    if (signal == SIGWINCH) resized = 1;
    else quit_requested = 1;
}

int haunt_terminal_open(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) return -1;
    if (tcgetattr(STDIN_FILENO, &original) != 0) return -1;
    struct termios raw = original;
    raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= ~OPOST;
    raw.c_cflag |= CS8;
    raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) return -1;
    struct sigaction action = {0};
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGWINCH, &action, &old_winch);
    sigaction(SIGINT, &action, &old_int);
    sigaction(SIGTERM, &action, &old_term);
    quit_requested = resized = 0;
    opened = 1;
    return 0;
}

void haunt_terminal_close(void) {
    if (!opened) return;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &original);
    sigaction(SIGWINCH, &old_winch, NULL);
    sigaction(SIGINT, &old_int, NULL);
    sigaction(SIGTERM, &old_term, NULL);
    opened = 0;
}

void haunt_terminal_size(unsigned int *width, unsigned int *height) {
    struct winsize size = {0};
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col && size.ws_row) {
        *width = size.ws_col;
        *height = size.ws_row;
    } else {
        *width = 80;
        *height = 24;
    }
}

int haunt_wait(int timeout_ms) {
    struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
    int result = poll(&input, 1, timeout_ms);
    if (result < 0 && errno != EINTR) return -1;
    if (input.revents & (POLLHUP | POLLERR | POLLNVAL)) quit_requested = 1;
    return result > 0 && (input.revents & POLLIN);
}

int haunt_read(unsigned char *buffer, size_t capacity) {
    ssize_t count = read(STDIN_FILENO, buffer, capacity);
    return count < 0 ? 0 : (int)count;
}

int haunt_should_quit(void) { return quit_requested; }
int haunt_was_resized(void) { int value = resized; resized = 0; return value; }

double haunt_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec * 1000.0 + (double)now.tv_nsec / 1000000.0;
}

int64_t haunt_file_stamp(const char *path) {
    struct stat info;
    if (stat(path, &info) != 0) return -1;
#ifdef __APPLE__
    return (int64_t)info.st_mtimespec.tv_sec * 1000000000LL + info.st_mtimespec.tv_nsec;
#else
    return (int64_t)info.st_mtim.tv_sec * 1000000000LL + info.st_mtim.tv_nsec;
#endif
}

/* Keep Lua's longjmp-based error handling entirely on the C side of the FFI. */
static double call_deadline;
static void instruction_hook(lua_State *L, lua_Debug *debug) {
    (void)debug;
    if (haunt_now() > call_deadline) luaL_error(L, "widget exceeded its execution time budget");
}

int haunt_lua_pcall(lua_State *L, int arguments, int results) {
    lua_Hook previous = lua_gethook(L);
    int mask = lua_gethookmask(L), count = lua_gethookcount(L);
    call_deadline = haunt_now() + 100.0;
    lua_sethook(L, instruction_hook, LUA_MASKCOUNT, 10000);
    int status = lua_pcall(L, arguments, results, 0);
    lua_sethook(L, previous, mask, count);
    return status;
}

int haunt_lua_now(lua_State *L) {
    lua_pushnumber(L, haunt_now());
    return 1;
}
