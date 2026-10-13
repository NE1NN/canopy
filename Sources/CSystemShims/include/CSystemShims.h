#ifndef CSYSTEMSHIMS_H
#define CSYSTEMSHIMS_H

// Calls that make a descriptor close-on-exec as it is created. On Linux they need _GNU_SOURCE, which Swift's Glibc
// import leaves out, so they live here. Elsewhere they are the plain calls, since Darwin's spawns close every
// descriptor anyway.

/// accept(2), with the new descriptor close-on-exec on Linux.
int canopy_accept_closing_on_exec(int fd);

/// mkstemp(3), with the file close-on-exec on Linux.
int canopy_mkstemp_closing_on_exec(char *path_template);

#endif
