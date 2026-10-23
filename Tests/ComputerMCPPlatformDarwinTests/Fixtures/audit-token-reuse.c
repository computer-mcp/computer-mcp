#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

struct identity {
  uint8_t uuid[16];
  uint64_t uniqueid, parent;
  uint32_t version, parent_version;
  uint64_t reserved[2];
};

int main(void) {
  // A standalone, single-threaded process can fork repeatedly without inheriting Swift locks.
  // Only one child exists at a time; the pipe keeps it alive across identity checks/signals.
  alarm(540);
  int gate[2];
  if (pipe(gate)) return 1;
  const unsigned capacity = 1000000;
  struct identity *seen = calloc(capacity, sizeof(*seen));
  if (!seen) return 13;
  for (unsigned count = 0; count < 300000; count++) {
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
      close(gate[1]);
      char byte;
      ssize_t size;
      do { size = read(gate[0], &byte, 1); } while (size < 0 && errno == EINTR);
      _exit(size == 1 ? 0 : 3);
    }
    struct identity current = {0};
    if (proc_pidinfo(child, 17, 1, &current, sizeof(current)) != sizeof(current)) return 4;
    if (child <= 0 || (unsigned)child >= capacity) return 14;
    struct identity first = seen[child];
    int reused = first.uniqueid != 0;
    if (reused) {
      audit_token_t token = {{0}};
      token.val[5] = (uint32_t)child;
      token.val[7] = first.version;
      if (current.uniqueid == first.uniqueid || current.version == first.version) return 5;
      if (proc_signal_with_audittoken(&token, SIGTERM) != ESRCH) return 6;
      if (proc_signal_with_audittoken(&token, SIGKILL) != ESRCH) return 7;
      struct identity surviving = {0};
      if (proc_pidinfo(child, 17, 0, &surviving, sizeof(surviving)) != sizeof(surviving)
          || surviving.uniqueid != current.uniqueid) return 8;
    }
    seen[child] = current;
    if (count % 10000 == 0) fprintf(stderr, "PID reuse probe: %u forks, current PID %d\n", count, child);
    if (write(gate[1], "x", 1) != 1) return 9;
    int status;
    while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 10; }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return 11;
    if (reused) {
      printf("Reused PID %d after %u forks: TERM/KILL stale tokens ESRCH; replacement exited normally\n", child, count);
      return 0;
    }
  }
  return 12;
}
