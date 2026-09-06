/*
 * vpnrun — launch a program under a given VPN group so PF can steer its
 * traffic. Must be started as root; drops to the target user before exec.
 *
 * usage: vpnrun <user> <group> <absolute-path-to-binary> [args...]
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <grp.h>
#include <pwd.h>
#include <ctype.h>
#include <stdlib.h>
#include <spawn.h>
#include <errno.h>

extern char **environ;
/* Exported by libSystem since macOS 10.14; declared in a private header, so
   declare it here. Weak: if a future macOS removes it, the launch still
   works and only the responsibility attribution falls back to the old way. */
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim)
    __attribute__((weak_import));

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <user> <group> <program> [args...]\n", argv[0]);
        return 1;
    }
    /* only ever operate on our own groups */
    if (strlen(argv[2]) != 16 || strncmp(argv[2], "vpn_", 4) != 0) {
        fprintf(stderr, "refusing invalid VPNonly group\n");
        return 1;
    }
    for (size_t i = 4; i < 16; ++i) {
        if (!isdigit((unsigned char)argv[2][i]) &&
            !(argv[2][i] >= 'a' && argv[2][i] <= 'f')) {
            fprintf(stderr, "refusing invalid VPNonly group\n");
            return 1;
        }
    }
    struct group *g = getgrnam(argv[2]);
    if (!g) { fprintf(stderr, "group '%s' not found\n", argv[2]); return 1; }
    if (g->gr_gid < 7100 || g->gr_gid >= 7900) {
        fprintf(stderr, "refusing VPNonly group outside private gid range\n");
        return 1;
    }

    struct passwd *p = getpwnam(argv[1]);
    if (!p) { fprintf(stderr, "user '%s' not found\n", argv[1]); return 1; }
    if (p->pw_uid == 0) { fprintf(stderr, "refusing to launch as root\n"); return 1; }

    /* sudo prepared this process for root. setuid() changes credentials, not
       HOME/USER/TMPDIR, so carrying that environment into a GUI app makes it
       look in /var/root and use a root-only temporary directory. */
    const char *shell = (p->pw_shell && p->pw_shell[0]) ? p->pw_shell : "/bin/zsh";
    if (setenv("HOME", p->pw_dir, 1) != 0 ||
        setenv("USER", p->pw_name, 1) != 0 ||
        setenv("LOGNAME", p->pw_name, 1) != 0 ||
        setenv("SHELL", shell, 1) != 0 ||
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1) != 0) {
        perror("setenv");
        return 1;
    }
    unsetenv("SUDO_COMMAND");
    unsetenv("SUDO_USER");
    unsetenv("SUDO_UID");
    unsetenv("SUDO_GID");

    gid_t only[1] = { g->gr_gid };
    if (setgroups(1, only) != 0) { perror("setgroups"); return 1; }
    if (setgid(g->gr_gid) != 0)  { perror("setgid");    return 1; }
    if (setuid(p->pw_uid) != 0)  { perror("setuid");    return 1; }

#ifdef _CS_DARWIN_USER_TEMP_DIR
    size_t tmp_len = confstr(_CS_DARWIN_USER_TEMP_DIR, NULL, 0);
    if (tmp_len > 1) {
        char *tmp = malloc(tmp_len);
        if (!tmp) { perror("malloc"); return 1; }
        if (confstr(_CS_DARWIN_USER_TEMP_DIR, tmp, tmp_len) == 0 ||
            setenv("TMPDIR", tmp, 1) != 0) {
            free(tmp);
            perror("TMPDIR");
            return 1;
        }
        free(tmp);
    } else {
        unsetenv("TMPDIR");
    }
#else
    unsetenv("TMPDIR");
#endif

    /* Exec in place, but make the program responsible for itself. A plain
       execv leaves macOS holding whoever launched vpnrun responsible for the
       app's privacy prompts (microphone, camera, contacts), and TCC's rule for
       a responsible app that lacks the usage description is to kill the
       requester on the spot. That is how WhatsApp died the instant a call
       started. This is what Terminal and open(1) do; nothing else changes. */
    posix_spawnattr_t attrs;
    if (posix_spawnattr_init(&attrs) != 0) { perror("posix_spawnattr_init"); return 1; }
    if (posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETEXEC) != 0) {
        perror("posix_spawnattr_setflags");
        return 1;
    }
    if (responsibility_spawnattrs_setdisclaim != NULL)
        responsibility_spawnattrs_setdisclaim(&attrs, 1);
    int rc = posix_spawn(NULL, argv[3], NULL, &attrs, &argv[3], environ);
    /* only reached on failure: with SETEXEC a success never returns */
    fprintf(stderr, "posix_spawn: %s\n", strerror(rc));
    return 1;
}
