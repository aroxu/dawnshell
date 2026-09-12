/* Runs a command with the slow-close_range guard installed.

   Shell scripts cannot install a seccomp filter, so this wrapper does it and
   then executes the requested command. The filter is inherited, so wrapping
   one chroot(8) invocation protects every Debian process started inside it. */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "dawnshell_close_range_guard.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        dprintf(STDERR_FILENO,
                "usage: dawnshell-fdguard COMMAND [ARGUMENT...]\n");
        return 2;
    }
    int guarded = dawnshell_install_close_range_guard();
    if (guarded > 0) {
        dprintf(STDERR_FILENO,
                "dawnshell-fdguard: this kernel walks the whole close_range(2) "
                "range; reporting ENOSYS so closefrom(3) uses /proc/self/fd\n");
    } else if (guarded < 0) {
        dprintf(STDERR_FILENO,
                "dawnshell-fdguard: WARNING could not install the close_range "
                "filter: %s\n", strerror(errno));
    }
    execvp(argv[1], argv + 1);
    dprintf(STDERR_FILENO, "dawnshell-fdguard: cannot execute %s: %s\n",
            argv[1], strerror(errno));
    return 127;
}

