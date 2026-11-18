// c11v step 0 TCC probe. A stand-in for c11d: a native Mach-O that reports
// which process macOS holds responsible for it, then spawns a shell (as c11d
// would) whose children report the same and attempt one Full Disk Access
// protected read. Uses the private responsibility_get_pid_responsible_for_pid
// symbol only to observe attribution; it does not change it.
//
//   respprobe probe                 print pid, ppid, responsible pid and path
//   respprobe spawn <out> <cmd...>  append probe output to <out>, then spawn
//                                   <cmd...> with stdout/stderr on <out>
#include <dlfcn.h>
#include <fcntl.h>
#include <libproc.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static void report(FILE *f, const char *who) {
    typedef int (*resp_fn)(pid_t);
    resp_fn fn = (resp_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    pid_t self = getpid();
    int rp = fn ? fn(self) : -1;
    char self_path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    char resp_path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    proc_pidpath(self, self_path, sizeof self_path);
    if (rp > 0) proc_pidpath(rp, resp_path, sizeof resp_path);
    fprintf(f, "%s pid=%d ppid=%d path=%s responsible_pid=%d responsible_path=%s\n",
            who, self, getppid(), self_path, rp, resp_path[0] ? resp_path : "?");
    fflush(f);
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "probe") == 0) {
        report(stdout, argc >= 3 ? argv[2] : "probe");
        return 0;
    }
    if (argc >= 4 && strcmp(argv[1], "spawn") == 0) {
        int fd = open(argv[2], O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd < 0) return 2;
        FILE *f = fdopen(dup(fd), "a");
        report(f, "stub");
        fclose(f);
        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_adddup2(&fa, fd, 1);
        posix_spawn_file_actions_adddup2(&fa, fd, 2);
        pid_t child;
        int rc = posix_spawn(&child, argv[3], &fa, NULL, &argv[3], environ);
        if (rc != 0) {
            dprintf(fd, "posix_spawn failed rc=%d\n", rc);
            return 3;
        }
        int status = 0;
        waitpid(child, &status, 0);
        dprintf(fd, "stub child exit status=%d\n", WEXITSTATUS(status));
        close(fd);
        return 0;
    }
    fprintf(stderr, "usage: respprobe probe | spawn <out> <cmd...>\n");
    return 1;
}
