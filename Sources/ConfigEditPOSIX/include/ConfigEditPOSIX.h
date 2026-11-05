#ifndef CONFIG_EDIT_POSIX_H
#define CONFIG_EDIT_POSIX_H
#include <sys/types.h>
#include <stddef.h>
pid_t wg_edit_spawn(const char *executable, char *const arguments[], uid_t uid, gid_t gid,
                    const gid_t *groups, size_t group_count, int input, int output, int lease);
#endif
