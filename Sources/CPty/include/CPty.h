#ifndef CANOPY_CPTY_H
#define CANOPY_CPTY_H

#include <sys/types.h>

/// Starts `path` as the session leader of a new pseudo-terminal, which becomes its controlling terminal.
/// The child starts in `directory` with default signal handling, an empty signal mask, and no open
/// descriptors besides 0, 1, and 2. Returns the child's pid and stores the master descriptor, which is
/// non-blocking and close-on-exec, in `master`. Returns -1 with errno set on failure.
pid_t canopy_pty_spawn(
    const char *path, char *const argv[], char *const envp[], const char *directory,
    unsigned short columns, unsigned short rows, int *master);

/// Sets the terminal size the child sees. Returns 0, or -1 with errno set.
int canopy_pty_resize(int master, unsigned short columns, unsigned short rows);

#endif
