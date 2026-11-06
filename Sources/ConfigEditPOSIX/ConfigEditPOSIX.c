#include "ConfigEditPOSIX.h"
#include <unistd.h>
#include <sys/resource.h>
#include <grp.h>
#include <errno.h>
#include <limits.h>

pid_t wg_edit_spawn(const char *executable, char *const arguments[], uid_t uid, gid_t gid,
                    const gid_t *groups, size_t group_count, int input, int output, int lease) {
    if (!executable || !arguments || uid == 0 || gid == (gid_t)-1 || group_count > NGROUPS_MAX || (group_count > 0 && !groups)) {
        errno = EINVAL;
        return -1;
    }
    long maximum = sysconf(_SC_OPEN_MAX);
    if (maximum < 3 || maximum > INT_MAX) { errno = EINVAL; return -1; }
    pid_t child = fork();
    if (child != 0) return child;
    /* No Swift/Objective-C, allocation, lookup or logging between fork and exec. */
    if (dup2(input, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0 || dup2(lease, STDERR_FILENO) < 0) _exit(126);
    for (int fd = 3; fd < maximum; ++fd) close(fd);
    if (geteuid() == 0) {
        if (setgroups((int)group_count, groups) != 0 || setgid(gid) != 0 || setuid(uid) != 0) _exit(126);
    } else if (getuid() != uid || geteuid() != uid || getgid() != gid || getegid() != gid) _exit(126);
    if (getuid() != uid || geteuid() != uid || getgid() != gid || getegid() != gid) _exit(126);
    char *environment[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
    execve(executable, arguments, environment);
    _exit(127);
}
