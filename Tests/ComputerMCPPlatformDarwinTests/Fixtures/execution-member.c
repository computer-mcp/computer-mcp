#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t cancelled;
static void terminate(int signal) { (void)signal; cancelled = 1; }

static void record(const char *name) {
  uint64_t info[7] = {0};
  if (proc_pidinfo(getpid(), 17, 0, info, sizeof(info)) != sizeof(info)) _exit(90);
  FILE *file = fopen(name, "w");
  if (!file) _exit(91);
  fprintf(file, "%d %llu %d %d %d\n", getpid(), info[2], getppid(), getpgrp(), getsid(0));
  fclose(file);
}

int main(int argc, char **argv) {
  if (argc != 2) return 92;
  if (!strcmp(argv[1], "exec-loop")) {
    record("ready");
    execl(argv[0], argv[0], "exec-loop", NULL);
    return 103;
  }
  alarm(20);
  record("root");
  if (!strcmp(argv[1], "exec-churn")) {
    signal(SIGTERM, SIG_IGN);
    execl(argv[0], argv[0], "exec-loop", NULL);
    return 103;
  }
  if (!strcmp(argv[1], "fork-churn")) {
    signal(SIGTERM, SIG_IGN);
    unsigned long count = 0;
    for (;;) {
      pid_t child = fork();
      if (child < 0) return 104;
      if (child == 0) _exit(0);
      while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
      if (++count == 100) record("ready");
    }
  }
  if (!strcmp(argv[1], "zombie")) {
    pid_t child = fork();
    if (child < 0) return 105;
    if (child == 0) {
      record("leaf");
      _exit(0);
    }
    // Keep the child unreaped while the host classifies its sandbox and identity.
    while (access("finish", F_OK) != 0) usleep(1000);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    return 23;
  }
  if (!strcmp(argv[1], "term-fork")) {
    signal(SIGTERM, terminate);
    record("ready");
    while (!cancelled) pause();
    pid_t child = fork();
    if (child < 0) return 100;
    if (child == 0) {
      alarm(20);
      if (setsid() < 0) _exit(101);
      signal(SIGTERM, SIG_IGN);
      record("leaf");
      execl("/bin/sleep", "sleep", "15", NULL);
      _exit(102);
    }
    return 23;
  }
  int sync[2];
  if (pipe(sync)) return 93;
  pid_t middle = fork();
  if (middle < 0) return 94;
  if (middle == 0) {
    alarm(20);
    close(sync[1]);
    if (!strcmp(argv[1], "observed")) {
      record("observed");
      while (access("detach", F_OK) != 0) usleep(10000);
    }
    if (!strcmp(argv[1], "group")) {
      if (setpgid(0, 0) != 0) _exit(95);
    } else if (!strcmp(argv[1], "observed")) {
      if (setsid() < 0) _exit(96);
    } else {
      if (setsid() < 0) _exit(96);
      pid_t leaf = fork();
      if (leaf < 0) _exit(97);
      if (leaf > 0) _exit(0);
      alarm(20);
      if (setsid() < 0) _exit(98);
    }
    char byte;
    while (read(sync[0], &byte, 1) > 0) {}
    close(sync[0]);
    for (int i = 0; getppid() != 1 && i < 500; i++) usleep(1000);
    signal(SIGTERM, SIG_IGN);
    record("leaf");
    if (!strcmp(argv[1], "natural")) {
      while (access("finish", F_OK) != 0) usleep(10000);
    }
    execl("/bin/sleep", "sleep", !strcmp(argv[1], "natural") ? "0" : "15", NULL);
    _exit(99);
  }
  close(sync[0]);
  if (!strcmp(argv[1], "observed")) {
    while (access("detach", F_OK) != 0) usleep(10000);
  } else if (strcmp(argv[1], "group")) waitpid(middle, NULL, 0);
  close(sync[1]);
  return 23;
}
