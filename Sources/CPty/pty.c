#include "CPty.h"

#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/ttydefaults.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t canopy_pty_spawn(
    const char *path, char *const argv[], char *const envp[], const char *directory,
    unsigned short columns, unsigned short rows, int *master)
{
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    // The system defaults plus IUTF8, as Terminal sets, so the kernel's own line editing erases whole
    // characters, as in `read` or a password prompt.
    struct termios attributes = {0};
    attributes.c_iflag = TTYDEF_IFLAG | IUTF8;
    attributes.c_oflag = TTYDEF_OFLAG;
    attributes.c_lflag = TTYDEF_LFLAG;
    attributes.c_cflag = TTYDEF_CFLAG;
    attributes.c_cc[VEOF] = CEOF;
    attributes.c_cc[VEOL] = CEOL;
    attributes.c_cc[VEOL2] = CEOL;
    attributes.c_cc[VERASE] = CERASE;
    attributes.c_cc[VWERASE] = CWERASE;
    attributes.c_cc[VKILL] = CKILL;
    attributes.c_cc[VREPRINT] = CREPRINT;
    attributes.c_cc[VINTR] = CINTR;
    attributes.c_cc[VQUIT] = CQUIT;
    attributes.c_cc[VSUSP] = CSUSP;
    attributes.c_cc[VDSUSP] = CDSUSP;
    attributes.c_cc[VSTART] = CSTART;
    attributes.c_cc[VSTOP] = CSTOP;
    attributes.c_cc[VLNEXT] = CLNEXT;
    attributes.c_cc[VDISCARD] = CDISCARD;
    attributes.c_cc[VMIN] = CMIN;
    attributes.c_cc[VTIME] = CTIME;
    attributes.c_cc[VSTATUS] = CSTATUS;
    cfsetispeed(&attributes, TTYDEF_SPEED);
    cfsetospeed(&attributes, TTYDEF_SPEED);
    struct rlimit limit;
    int highest = 10240;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY && limit.rlim_cur < 1048576) {
        highest = (int)limit.rlim_cur;
    }
    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, &attributes, &size);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // The parent has other threads, so only async-signal-safe calls from here on.
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int signal_number = 1; signal_number < NSIG; signal_number++) {
            signal(signal_number, SIG_DFL);
        }
        for (int descriptor = 3; descriptor < highest; descriptor++) {
            close(descriptor);
        }
        if (chdir(directory) != 0) {
            _exit(126);
        }
        execve(path, argv, envp);
        _exit(127);
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    *master = fd;
    return pid;
}

int canopy_pty_resize(int master, unsigned short columns, unsigned short rows)
{
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    return ioctl(master, TIOCSWINSZ, &size);
}
