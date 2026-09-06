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
#include <spawn.h>
#include <string.h>

extern char **environ;
/* Exported by libSystem since macOS 10.14; declared in a private header, so
   declared here. Weak: if a future macOS drops it, the launch still works and
   only the responsibility attribution falls back to the old way. */
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim)
    __attribute__((weak_import));

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

    /* Exec in place, but make the program responsible for itself. A plain
       execv leaves macOS holding whoever launched vpnrun responsible for the
       app's privacy prompts (microphone, camera, contacts), and TCC's rule for
       a responsible app without the usage description is to kill the requester
       on the spot: a routed WhatsApp died the instant a call started. This is
       what Terminal and open(1) do; the group and privilege drop are unchanged. */
    posix_spawnattr_t attrs;
    if (posix_spawnattr_init(&attrs) != 0) { perror("posix_spawnattr_init"); return 1; }
    if (posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETEXEC) != 0) {
        perror("posix_spawnattr_setflags");
        return 1;
    }
    if (responsibility_spawnattrs_setdisclaim != NULL)
        responsibility_spawnattrs_setdisclaim(&attrs, 1);
    int rc = posix_spawn(NULL, argv[2], NULL, &attrs, &argv[2], environ);
    fprintf(stderr, "posix_spawn: %s\n", strerror(rc));   /* only on failure */
    return 1;
}
