// agterm-session-host <socket> -- <argv...>: attach to the pane daemon at <socket>, starting one that runs argv when none
// answers. The daemon owns the pane's pty and outlives the app, so a later launch reattaches to the same shell (live
// restore mode, master's zmx). On attach it replays the recent output plus the DEC modes in force, then makes the
// foreground program redraw. agterm-session-host --kill <socket> ends that daemon and its shell.
//
// Client -> daemon frames: a type byte, a little-endian u32 length, the payload. 'd' input, 'w' rows+cols (u16 each), 'k' kill.
// Daemon -> client: the pty's raw output.
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <poll.h>
#include <pty.h>
#include <string>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <utility>

static bool writeAll(int fd, const char *p, size_t n)
{
    while (n > 0) {
        const ssize_t w = ::write(fd, p, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0)
            return false;
        p += w, n -= size_t(w);
    }
    return true;
}

static bool frame(int fd, char type, const void *data, uint32_t n)
{
    char head[5] = {type, char(n), char(n >> 8), char(n >> 16), char(n >> 24)};
    return writeAll(fd, head, 5) && writeAll(fd, static_cast<const char *>(data), n);
}

static sockaddr_un address(const char *path)
{
    sockaddr_un a{};
    a.sun_family = AF_UNIX;
    std::strncpy(a.sun_path, path, sizeof a.sun_path - 1);
    return a;
}

static int connectTo(const char *path)
{
    const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    const sockaddr_un a = address(path);
    if (fd >= 0 && ::connect(fd, reinterpret_cast<const sockaddr *>(&a), sizeof a) == 0)
        return fd;
    if (fd >= 0)
        ::close(fd);
    return -1;
}

// The DEC private modes a program sets once at start (alt screen, mouse, focus, bracketed paste, cursor keys); the
// replay window may have dropped the bytes that set them, so the summary follows the replay.
struct Modes {
    std::map<int, bool> set;
    int state = 0; // 0 text, 1 ESC, 2 CSI, 3 CSI ?
    std::string params;
    void scan(const char *p, size_t n)
    {
        static const int tracked[] = {1, 25, 47, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1047, 1049, 2004};
        for (size_t i = 0; i < n; ++i) {
            const char c = p[i];
            if (state == 0) {
                state = c == '\x1b' ? 1 : 0;
            } else if (state == 1) {
                if (c == 'c')
                    set.clear(); // RIS
                state = c == '[' ? 2 : c == '\x1b' ? 1 : 0;
            } else if (state == 2) {
                state = c == '?' ? 3 : 0, params.clear();
            } else if ((c >= '0' && c <= '9') || c == ';') {
                params += c;
            } else {
                if (c == 'h' || c == 'l')
                    for (size_t at = 0; at <= params.size();) {
                        const size_t end = params.find(';', at);
                        const int mode = std::atoi(params.substr(at, end - at).c_str());
                        for (int t : tracked)
                            if (t == mode)
                                set[mode] = c == 'h';
                        at = end == std::string::npos ? params.size() + 1 : end + 1;
                    }
                state = c == '\x1b' ? 1 : 0;
            }
        }
    }
    std::string restore() const
    {
        std::string out;
        for (const auto &[mode, on] : set)
            out += "\x1b[?" + std::to_string(mode) + (on ? "h" : "l");
        return out;
    }
};

[[noreturn]] static void daemon(int listener, const std::string &path, char **argv)
{
    ::setsid();
    std::signal(SIGHUP, SIG_IGN);
    std::signal(SIGPIPE, SIG_IGN);
    const int null = ::open("/dev/null", O_RDWR | O_CLOEXEC);
    for (int fd : {0, 1, 2})
        ::dup2(null, fd); // let go of the attaching terminal's pty
    winsize ws{24, 80, 0, 0};
    int master = -1;
    const pid_t child = ::forkpty(&master, nullptr, nullptr, &ws);
    if (child == 0) {
        std::signal(SIGHUP, SIG_DFL);
        std::signal(SIGPIPE, SIG_DFL);
        ::execvp(argv[0], argv);
        _exit(127);
    }
    if (child > 0)
        if (FILE *f = std::fopen((path + ".pid").c_str(), "w"))
            std::fprintf(f, "%d\n", child), std::fclose(f);
    std::string replay, input;
    Modes modes;
    constexpr size_t cap = 4 << 20;
    int client = -1;
    bool redraw = false;
    char buf[65536];
    while (child > 0) {
        pollfd fds[3] = {{listener, POLLIN, 0}, {master, POLLIN, 0}, {client, POLLIN, 0}};
        if (::poll(fds, client >= 0 ? 3 : 2, -1) < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (fds[1].revents) {
            const ssize_t n = ::read(master, buf, sizeof buf);
            if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN))
                break; // EIO: the shell is gone
            if (n > 0) {
                replay.append(buf, size_t(n));
                modes.scan(buf, size_t(n));
                if (replay.size() > cap) { // drop the oldest half, cut at a line so the replay starts clean
                    const size_t nl = replay.find('\n', replay.size() - cap / 2);
                    replay.erase(0, nl == std::string::npos ? replay.size() - cap / 2 : nl + 1);
                }
                if (client >= 0 && !writeAll(client, buf, size_t(n)))
                    ::close(client), client = -1;
            }
        }
        if (fds[0].revents & POLLIN) {
            const int c = ::accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
            if (c >= 0) {
                if (client >= 0)
                    ::close(client); // one view per pane: the newest attach wins
                client = c, input.clear(), redraw = true;
                const std::string out = replay + modes.restore();
                if (!writeAll(client, out.data(), out.size()))
                    ::close(client), client = -1;
            }
        }
        if (client >= 0 && fds[2].revents) {
            const ssize_t n = ::read(client, buf, sizeof buf);
            if (n <= 0) {
                ::close(client), client = -1;
                continue;
            }
            input.append(buf, size_t(n));
            bool kill = false;
            while (input.size() >= 5) {
                const uint32_t len = uint8_t(input[1]) | uint8_t(input[2]) << 8 | uint8_t(input[3]) << 16 | uint32_t(uint8_t(input[4])) << 24;
                if (input.size() < 5 + size_t(len))
                    break;
                const char *p = input.data() + 5;
                if (input[0] == 'd') {
                    writeAll(master, p, len);
                } else if (input[0] == 'w' && len == 4) {
                    ws.ws_row = uint16_t(uint8_t(p[0]) | uint8_t(p[1]) << 8);
                    ws.ws_col = uint16_t(uint8_t(p[2]) | uint8_t(p[3]) << 8);
                    ::ioctl(master, TIOCSWINSZ, &ws);
                    if (std::exchange(redraw, false)) // the same size raises no SIGWINCH of its own
                        if (const pid_t fg = ::tcgetpgrp(master); fg > 0)
                            ::kill(-fg, SIGWINCH);
                } else if (input[0] == 'k') {
                    kill = true;
                }
                input.erase(0, 5 + size_t(len));
            }
            if (kill)
                break;
        }
    }
    ::unlink(path.c_str());
    ::unlink((path + ".pid").c_str());
    ::unlink((path + ".id").c_str()); // the pane id the app wrote beside it
    if (client >= 0)
        ::close(client);
    if (child > 0)
        ::kill(-child, SIGHUP); // the shell leads its own session; closing the master hangs up the rest
    ::close(master);
    for (int i = 0; child > 0 && i < 20 && ::waitpid(child, nullptr, WNOHANG) == 0; ++i)
        ::usleep(50000);
    if (child > 0 && ::waitpid(child, nullptr, WNOHANG) == 0) { // a shell ignoring SIGHUP must not keep the daemon
        ::kill(-child, SIGKILL);
        ::waitpid(child, nullptr, 0);
    }
    _exit(0);
}

static volatile sig_atomic_t resized = 1;

static void sendSize(int fd)
{
    winsize ws{};
    if (::ioctl(0, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0 && ws.ws_col > 0) {
        const unsigned char p[4] = {uint8_t(ws.ws_row), uint8_t(ws.ws_row >> 8), uint8_t(ws.ws_col), uint8_t(ws.ws_col >> 8)};
        frame(fd, 'w', p, 4);
    }
}

static int attach(int fd)
{
    termios saved{};
    const bool tty = ::tcgetattr(0, &saved) == 0;
    if (tty) {
        termios raw = saved;
        ::cfmakeraw(&raw);
        ::tcsetattr(0, TCSANOW, &raw);
    }
    struct sigaction sa{};
    sa.sa_handler = [](int) { resized = 1; };
    ::sigaction(SIGWINCH, &sa, nullptr); // no SA_RESTART: poll returns EINTR and the size goes out
    char buf[65536];
    for (;;) {
        if (resized)
            resized = 0, sendSize(fd);
        pollfd fds[2] = {{0, POLLIN, 0}, {fd, POLLIN, 0}};
        if (::poll(fds, 2, -1) < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (fds[1].revents) {
            const ssize_t n = ::read(fd, buf, sizeof buf);
            if (n <= 0 || !writeAll(1, buf, size_t(n)))
                break; // the shell exited, or a newer attach took the pane
        }
        if (fds[0].revents) {
            const ssize_t n = ::read(0, buf, sizeof buf);
            if (n <= 0 || !frame(fd, 'd', buf, uint32_t(n)))
                break;
        }
    }
    if (tty)
        ::tcsetattr(0, TCSANOW, &saved);
    return 0;
}

int main(int argc, char **argv)
{
    std::signal(SIGPIPE, SIG_IGN);
    if (argc == 3 && std::strcmp(argv[1], "--kill") == 0) {
        const int fd = connectTo(argv[2]);
        if (fd < 0)
            return 1;
        frame(fd, 'k', nullptr, 0);
        char sink[4096];
        while (::read(fd, sink, sizeof sink) > 0) {
        } // EOF once the daemon has finished
        return 0;
    }
    if (argc < 4 || std::strcmp(argv[2], "--") != 0)
        return std::fprintf(stderr, "usage: %s <socket> -- <command...> | --kill <socket>\n", argv[0]), 2;
    const std::string path = argv[1];
    if (path.size() >= sizeof(sockaddr_un::sun_path))
        return std::fprintf(stderr, "socket path too long: %s\n", path.c_str()), 2;
    int fd = connectTo(path.c_str());
    if (fd < 0) {
        ::unlink(path.c_str()); // stale: nothing answers
        const int listener = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        const sockaddr_un a = address(path.c_str());
        const mode_t old = ::umask(077);
        const bool bound = listener >= 0 && ::bind(listener, reinterpret_cast<const sockaddr *>(&a), sizeof a) == 0 && ::listen(listener, 4) == 0;
        ::umask(old);
        if (!bound)
            return std::fprintf(stderr, "cannot listen on %s: %s\n", path.c_str(), std::strerror(errno)), 1;
        const pid_t pid = ::fork();
        if (pid == 0)
            daemon(listener, path, argv + 3);
        ::close(listener);
        fd = pid > 0 ? connectTo(path.c_str()) : -1;
        if (fd < 0)
            return std::fprintf(stderr, "cannot start the session daemon at %s\n", path.c_str()), 1;
    }
    return attach(fd);
}
