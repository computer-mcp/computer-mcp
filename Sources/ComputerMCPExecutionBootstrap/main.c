#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>

static int target_arguments(int argc, char **argv) {
  int target = 1;
  if (argc > 1 && strcmp(argv[1], "--file-size-limit") == 0) {
    target = 3;
    if (argc <= target || !argv[2][0]) {
      errno = EINVAL;
      return -1;
    }
    for (const char *digit = argv[2]; *digit; ++digit) {
      if (*digit < '0' || *digit > '9') {
        errno = EINVAL;
        return -1;
      }
    }
    errno = 0;
    uintmax_t bytes = strtoumax(argv[2], NULL, 10);
    rlim_t limit = (rlim_t)bytes;
    if (errno || !bytes || (uintmax_t)limit != bytes || limit == RLIM_INFINITY) {
      errno = ERANGE;
      return -1;
    }
    struct rlimit requested = {limit, limit};
    if (setrlimit(RLIMIT_FSIZE, &requested) != 0) return -1;
    struct rlimit actual;
    if (getrlimit(RLIMIT_FSIZE, &actual) != 0) return -1;
    if (actual.rlim_cur != limit || actual.rlim_max != limit) {
      errno = EINVAL;
      return -1;
    }
  }
  if (argc <= target || argv[target][0] != '/') {
    errno = EINVAL;
    return -1;
  }
  return target;
}

#if defined(__linux__)
#include <signal.h>
#include <sys/prctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int target = target_arguments(argc, argv);
  if (target < 0) {
    perror("Execution bootstrap target or file-size limit");
    return 126;
  }
  pid_t parent = getppid();
  if (parent == 1 || prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) return 126;
  /* The host persists ownership before continuing this process into exec. */
  if (raise(SIGSTOP) != 0) return 126;
  execv(argv[target], argv + target);
  return errno == ENOENT ? 127 : 126;
}
#else
#include <libproc.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

/* PROC_PIDUNIQIDENTIFIERINFO's Darwin ABI includes an identity stable across exec. */
struct process_identity_info {
  uint8_t executable_uuid[16];
  uint64_t unique_id;
  uint64_t parent_unique_id;
  int32_t version;
  uint32_t reserved2;
  uint64_t reserved3;
  uint64_t reserved4;
};

struct bootstrap_identity {
  uint64_t unique_id;
  uint32_t pid;
  uint32_t version;
};

_Static_assert(sizeof(struct process_identity_info) == 56, "Darwin process identity ABI");
_Static_assert(sizeof(struct bootstrap_identity) == 16, "Bootstrap wire identity ABI");

int main(int argc, char **argv) {
  int target = target_arguments(argc, argv);
  if (target < 0) {
    perror("Execution bootstrap target or file-size limit");
    return 126;
  }
  /* Allow scheduling and host ownership admission under heavy machine load. */
  struct timeval timeout = {.tv_sec = 30};
  int enabled = 1;
  if (setsockopt(STDIN_FILENO, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
      setsockopt(STDIN_FILENO, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0 ||
      setsockopt(STDIN_FILENO, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
    perror("Execution identity channel setup failed");
    return 126;
  }

  /* Foundation may create a process group in the host's session. Leave it before setsid. */
  if (getsid(0) != getpid()) {
    if (getpgrp() == getpid() && setpgid(0, getpgid(getppid())) != 0) {
      perror("Execution process group setup failed");
      return 126;
    }
    if (setsid() < 0) {
      perror("Execution session setup failed");
      return 126;
    }
  }
  struct process_identity_info info = {0};
  int identity_size = proc_pidinfo(getpid(), 17, 0, &info, sizeof(info));
  if (identity_size != sizeof(info) || info.unique_id == 0) {
    int status = identity_size <= 0 ? errno : 0;
    fprintf(stderr, "Execution identity query failed: size %d, identity %llu, errno %d\n",
            identity_size, (unsigned long long)info.unique_id, status);
    return 126;
  }
  struct bootstrap_identity identity = {info.unique_id, (uint32_t)getpid(), (uint32_t)info.version};
  const uint8_t *cursor = (const uint8_t *)&identity;
  size_t remaining = sizeof(identity);
  while (remaining != 0) {
    ssize_t count = write(STDIN_FILENO, cursor, remaining);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      perror("Execution identity write failed");
      return 126;
    }
    cursor += count;
    remaining -= (size_t)count;
  }

  /* The command cannot run until the host has bound this exact launch identity. */
  uint8_t acknowledgement = 0;
  struct iovec payload = {&acknowledgement, sizeof(acknowledgement)};
  union {
    struct cmsghdr alignment;
    uint8_t bytes[CMSG_SPACE(2 * sizeof(int))];
  } control = {0};
  struct msghdr message = {0};
  message.msg_iov = &payload;
  message.msg_iovlen = 1;
  message.msg_control = control.bytes;
  message.msg_controllen = sizeof(control.bytes);
  ssize_t received;
  do { received = recvmsg(STDIN_FILENO, &message, 0); } while (received < 0 && errno == EINTR);
  if (received < 0) {
    perror("Execution descriptor handoff failed");
    return 126;
  }
  struct cmsghdr *header = CMSG_FIRSTHDR(&message);
  if (received != 1 || acknowledgement != 1 || (message.msg_flags & MSG_CTRUNC) ||
      header == NULL || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
      header->cmsg_len != CMSG_LEN(2 * sizeof(int))) {
    fputs("Execution descriptor handoff invalid\n", stderr);
    return 126;
  }
  int *descriptors = (int *)CMSG_DATA(header);
  int original_input = descriptors[0];
  int original_error = descriptors[1];
  /* Keep the channel and diagnostics open while installing both target descriptors. */
  int channel = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3);
  int diagnostics = fcntl(STDERR_FILENO, F_DUPFD_CLOEXEC, 3);
  if (channel < 0 || diagnostics < 0 || dup2(original_input, STDIN_FILENO) < 0 ||
      dup2(original_error, STDERR_FILENO) < 0) {
    perror("Execution descriptor installation failed");
    return 126;
  }
  close(original_input);
  close(original_error);
  /* The host may release its descriptors only after both have been installed. */
  acknowledgement = 2;
  ssize_t confirmed;
  do { confirmed = write(channel, &acknowledgement, 1); } while (confirmed < 0 && errno == EINTR);
  if (confirmed != 1) {
    dprintf(diagnostics, "Execution descriptor confirmation failed: errno %d\n", errno);
    return 126;
  }
  close(channel);
  close(diagnostics);
  execv(argv[target], argv + target);
  int status = errno == ENOENT ? 127 : 126;
  perror("Execution target exec failed");
  return status;
}
#endif
