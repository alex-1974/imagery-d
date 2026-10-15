#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* Research-only native child supervisor: a Python subprocess fork inherits
 * Python's own RSS high-water mark, polluting the child's wait4 ru_maxrss.
 * This small C helper is run DIRECTLY from the XPS shell script. Record the
 * pre-fork helper maximum so a larger launcher can be detected and rejected.
 * A child exit/exec failure is always a nonzero tool status. */

static int output_path(char* dest, size_t length, const char* base,
                       const char* suffix)
{
    const int n = snprintf(dest, length, "%s%s", base, suffix);
    if (n < 0 || (size_t)n >= length)
    {
        fputs("ERROR: evidence path exceeds fixed C buffer\n", stderr);
        return -1;
    }
    return 0;
}

static void close_fd(int fd)
{
    if (fd >= 0)
        (void)close(fd);
}

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        fputs("usage: m3_capture_native_peak PREFIX INTERPOSER CHILD [ARGS...]\n",
              stderr);
        return 2;
    }
    if (setenv("LD_PRELOAD", argv[2], 1) != 0)
    {
        perror("setenv LD_PRELOAD");
        return 1;
    }
    struct rusage before;
    if (getrusage(RUSAGE_SELF, &before) != 0)
    {
        perror("getrusage launcher baseline");
        return 1;
    }
    enum { path_capacity = 4096 };
    const char* suffixes[4] = {
        "-events.csv", "-stdout.txt", "-stderr.txt", "-wait4.csv"
    };
    char paths[4][path_capacity];
    int descriptors[4] = { -1, -1, -1, -1 };
    for (int i = 0; i < 4; ++i)
    {
        if (output_path(paths[i], sizeof(paths[i]), argv[1], suffixes[i]))
            goto error;
        descriptors[i] = open(paths[i], O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (descriptors[i] < 0)
        {
            perror("open fresh evidence file");
            goto error;
        }
    }
    const pid_t child = fork();
    if (child < 0)
    {
        perror("fork child");
        goto error;
    }
    if (child == 0)
    {
        /* Keep the event recorder's special inherited FD 9 exactly as in
         * the already qualified producer traces; do not run Python here. */
        if (dup2(descriptors[0], 9) != 9 ||
            dup2(descriptors[1], STDOUT_FILENO) != STDOUT_FILENO ||
            dup2(descriptors[2], STDERR_FILENO) != STDERR_FILENO)
        {
            perror("dup2 independent trace outputs");
            _exit(127);
        }
        for (int i = 0; i < 4; ++i)
            if (descriptors[i] != 9 && descriptors[i] != STDOUT_FILENO &&
                descriptors[i] != STDERR_FILENO)
                close_fd(descriptors[i]);
        execv(argv[3], &argv[3]);
        perror("execv research D consumer");
        _exit(127);
    }
    for (int i = 0; i < 3; ++i)
        close_fd(descriptors[i]);
    descriptors[0] = descriptors[1] = descriptors[2] = -1;
    int status = 0;
    struct rusage usage;
    pid_t waited;
    do
    {
        waited = wait4(child, &status, 0, &usage);
    } while (waited < 0 && errno == EINTR);
    if (waited != child)
    {
        perror("wait4 D consumer");
        goto error;
    }
    const int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
    FILE* out = fdopen(descriptors[3], "w");
    if (out == NULL)
    {
        perror("fdopen peak receipt");
        goto error;
    }
    descriptors[3] = -1;
    if (fprintf(out, "exit_code,kernel_peak_rss_kib,minor_faults,major_faults,"
                     "launcher_pre_spawn_peak_rss_kib\n"
                     "%d,%ld,%ld,%ld,%ld\n", code, usage.ru_maxrss,
                usage.ru_minflt, usage.ru_majflt, before.ru_maxrss) < 0 ||
        fclose(out) != 0)
    {
        perror("write peak receipt");
        return 1;
    }
    if (code != 0)
    {
        fprintf(stderr, "ERROR: research D consumer returned %d\n", code);
        return 1;
    }
    return 0;
error:
    for (int i = 0; i < 4; ++i)
        close_fd(descriptors[i]);
    return 1;
}
