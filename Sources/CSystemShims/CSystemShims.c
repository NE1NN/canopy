#ifdef __linux__
#define _GNU_SOURCE
#endif

#include "CSystemShims.h"

#include <fcntl.h>
#include <stdlib.h>
#include <sys/socket.h>

int canopy_accept_closing_on_exec(int fd) {
#ifdef __linux__
    return accept4(fd, NULL, NULL, SOCK_CLOEXEC);
#else
    return accept(fd, NULL, NULL);
#endif
}

int canopy_mkstemp_closing_on_exec(char *path_template) {
#ifdef __linux__
    return mkostemp(path_template, O_CLOEXEC);
#else
    return mkstemp(path_template);
#endif
}
