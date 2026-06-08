/*
 * awrr_setpolicy.c — Set a process to use SCHED_AWRR scheduling policy
 *
 * Since standard tools like chrt do not know about SCHED_AWRR, this small
 * helper calls sched_setscheduler() directly with the AWRR policy number.
 *
 * Usage:
 *   ./awrr_setpolicy --pid 1234              # Change existing process
 *   ./awrr_setpolicy --run "command args"     # Fork, set policy, exec command
 *   ./awrr_setpolicy --pid 1234 --weight 8    # Set policy (weight is informational)
 *
 * Compile: gcc -o awrr_setpolicy awrr_setpolicy.c
 * Run as root (sched_setscheduler requires CAP_SYS_NICE).
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sched.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>

/* SCHED_AWRR policy number — must match the kernel definition */
#ifndef SCHED_AWRR
#define SCHED_AWRR 7
#endif

static void usage(const char *prog)
{
    fprintf(stderr, "Usage:\n");
    fprintf(stderr, "  %s --pid <PID>              Set existing process to SCHED_AWRR\n", prog);
    fprintf(stderr, "  %s --run \"command args\"      Fork, set SCHED_AWRR, exec command\n", prog);
    fprintf(stderr, "  %s --pid <PID> --weight <W>  Set policy (weight logged only)\n", prog);
    fprintf(stderr, "\n");
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  --pid <PID>       Target process ID\n");
    fprintf(stderr, "  --run \"cmd\"       Command to execute under SCHED_AWRR\n");
    fprintf(stderr, "  --weight <1-10>   Desired initial weight (informational)\n");
    fprintf(stderr, "  --priority <P>    Scheduling priority (default: 0)\n");
    fprintf(stderr, "  --help            Show this message\n");
}

/*
 * Set the scheduling policy of a process to SCHED_AWRR.
 * Returns 0 on success, -1 on failure.
 */
static int set_awrr_policy(pid_t pid, int priority)
{
    struct sched_param param;
    memset(&param, 0, sizeof(param));
    param.sched_priority = priority;

    if (sched_setscheduler(pid, SCHED_AWRR, &param) < 0) {
        fprintf(stderr, "sched_setscheduler(pid=%d, SCHED_AWRR) failed: %s\n",
                pid, strerror(errno));

        if (errno == EINVAL) {
            fprintf(stderr, "\nSCHED_AWRR (policy %d) is not recognized by this kernel.\n",
                    SCHED_AWRR);
            fprintf(stderr, "Make sure you are running a kernel with AWRR support.\n");
            fprintf(stderr, "Check: dmesg | grep -i awrr\n");
        } else if (errno == EPERM) {
            fprintf(stderr, "\nPermission denied. Run as root or with CAP_SYS_NICE.\n");
        }

        return -1;
    }

    return 0;
}

/*
 * Parse a command string into argv array for execvp.
 * Simple whitespace splitting (no quote handling).
 */
static char **parse_command(const char *cmd, int *argc_out)
{
    /* Make a mutable copy */
    char *buf = strdup(cmd);
    if (!buf) {
        perror("strdup");
        return NULL;
    }

    /* Count tokens */
    int capacity = 16;
    char **argv = malloc(capacity * sizeof(char *));
    if (!argv) {
        free(buf);
        perror("malloc");
        return NULL;
    }

    int argc = 0;
    char *token = strtok(buf, " \t");
    while (token) {
        if (argc >= capacity - 1) {
            capacity *= 2;
            argv = realloc(argv, capacity * sizeof(char *));
            if (!argv) {
                free(buf);
                perror("realloc");
                return NULL;
            }
        }
        argv[argc++] = token;
        token = strtok(NULL, " \t");
    }
    argv[argc] = NULL;

    if (argc_out)
        *argc_out = argc;

    return argv;
}

int main(int argc, char *argv[])
{
    pid_t target_pid = 0;
    const char *run_cmd = NULL;
    int weight = 5;     /* informational only */
    int priority = 0;
    int has_pid = 0;
    int has_run = 0;

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--pid") == 0 && i + 1 < argc) {
            target_pid = atoi(argv[++i]);
            has_pid = 1;
        } else if (strcmp(argv[i], "--run") == 0 && i + 1 < argc) {
            run_cmd = argv[++i];
            has_run = 1;
        } else if (strcmp(argv[i], "--weight") == 0 && i + 1 < argc) {
            weight = atoi(argv[++i]);
            if (weight < 1) weight = 1;
            if (weight > 10) weight = 10;
        } else if (strcmp(argv[i], "--priority") == 0 && i + 1 < argc) {
            priority = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    if (!has_pid && !has_run) {
        fprintf(stderr, "Error: specify --pid or --run\n\n");
        usage(argv[0]);
        return 1;
    }

    if (has_pid && has_run) {
        fprintf(stderr, "Error: specify either --pid or --run, not both\n\n");
        usage(argv[0]);
        return 1;
    }

    /* Mode 1: Set policy on existing process */
    if (has_pid) {
        printf("Setting PID %d to SCHED_AWRR (policy %d, priority %d, weight %d)\n",
               target_pid, SCHED_AWRR, priority, weight);

        if (set_awrr_policy(target_pid, priority) < 0)
            return 1;

        printf("Success: PID %d is now using SCHED_AWRR\n", target_pid);

        /* Verify */
        int pol = sched_getscheduler(target_pid);
        if (pol >= 0) {
            printf("Verified: sched_getscheduler(%d) = %d %s\n",
                   target_pid, pol,
                   (pol == SCHED_AWRR) ? "(SCHED_AWRR)" : "(unexpected!)");
        }

        return 0;
    }

    /* Mode 2: Fork, set policy in child, exec command */
    if (has_run) {
        int cmd_argc = 0;
        char **cmd_argv = parse_command(run_cmd, &cmd_argc);
        if (!cmd_argv || cmd_argc == 0) {
            fprintf(stderr, "Error: could not parse command: %s\n", run_cmd);
            return 1;
        }

        printf("Running under SCHED_AWRR: %s\n", run_cmd);

        pid_t child = fork();
        if (child < 0) {
            perror("fork");
            return 1;
        }

        if (child == 0) {
            /* Child: set AWRR policy on ourselves, then exec */
            if (set_awrr_policy(0 /* self */, priority) < 0) {
                fprintf(stderr, "Warning: could not set SCHED_AWRR on child, "
                        "running with inherited policy\n");
                /* Continue anyway so benchmarks still run */
            }

            execvp(cmd_argv[0], cmd_argv);
            /* If we get here, exec failed */
            perror("execvp");
            _exit(127);
        }

        /* Parent: wait for child */
        int status;
        waitpid(child, &status, 0);

        if (WIFEXITED(status)) {
            return WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            fprintf(stderr, "Child killed by signal %d\n", WTERMSIG(status));
            return 128 + WTERMSIG(status);
        }

        return 1;
    }

    return 0;
}
