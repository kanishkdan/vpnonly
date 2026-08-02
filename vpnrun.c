/*
 * vpnrun — launch a program under the "vpnonly" group so PF can steer
 * its traffic into the VPN tunnel. Must be started as root (via sudo);
 * drops back to the target user after setting the group.
 *
 * usage: sudo vpnrun <user> <absolute-path-to-binary> [args...]
 */
#include <stdio.h>
#include <unistd.h>
#include <grp.h>
#include <pwd.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <user> <program> [args...]\n", argv[0]);
        return 1;
    }
    struct group *g = getgrnam("vpnonly");
    if (!g) { fprintf(stderr, "group 'vpnonly' not found (run up.sh first)\n"); return 1; }
    struct passwd *p = getpwnam(argv[1]);
    if (!p) { fprintf(stderr, "user '%s' not found\n", argv[1]); return 1; }

    gid_t only[1] = { g->gr_gid };
    if (setgroups(1, only) != 0) { perror("setgroups"); return 1; }
    if (setgid(g->gr_gid) != 0)  { perror("setgid");    return 1; }
    if (setuid(p->pw_uid) != 0)  { perror("setuid");    return 1; }

    execv(argv[2], &argv[2]);
    perror("execv");
    return 1;
}
