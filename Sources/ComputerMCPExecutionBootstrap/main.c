#if defined(__linux__)
#include <errno.h>
#include <signal.h>
#include <sys/prctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2 || argv[1][0] != '/') return 126;
  pid_t parent = getppid();
  if (parent == 1 || prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) return 126;
  /* The host persists ownership before continuing this process into exec. */
  if (raise(SIGSTOP) != 0) return 126;
  execv(argv[1], argv + 1);
  return errno == ENOENT ? 127 : 126;
}
#else
#include <errno.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
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
  if (argc < 2 || argv[1][0] != '/') return 126;
  struct timeval timeout = {.tv_sec = 5};
  int enabled = 1;
  if (setsockopt(STDIN_FILENO, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
      setsockopt(STDIN_FILENO, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0 ||
      setsockopt(STDIN_FILENO, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) return 126;

  /* Foundation may create a process group in the host's session. Leave it before setsid. */
  if (getsid(0) != getpid()) {
    if (getpgrp() == getpid() && setpgid(0, getpgid(getppid())) != 0) return 126;
    if (setsid() < 0) return 126;
  }
  struct process_identity_info info = {0};
  if (proc_pidinfo(getpid(), 17, 0, &info, sizeof(info)) != sizeof(info) || info.unique_id == 0) return 126;
  struct bootstrap_identity identity = {info.unique_id, (uint32_t)getpid(), (uint32_t)info.version};
  const uint8_t *cursor = (const uint8_t *)&identity;
  size_t remaining = sizeof(identity);
  while (remaining != 0) {
    ssize_t count = write(STDIN_FILENO, cursor, remaining);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return 126;
    cursor += count;
    remaining -= (size_t)count;
  }

  /* The command cannot run until the host has bound this exact launch identity. */
  uint8_t acknowledgement = 0;
  struct iovec payload = {&acknowledgement, sizeof(acknowledgement)};
  union {
    struct cmsghdr alignment;
    uint8_t bytes[CMSG_SPACE(sizeof(int))];
  } control = {0};
  struct msghdr message = {0};
  message.msg_iov = &payload;
  message.msg_iovlen = 1;
  message.msg_control = control.bytes;
  message.msg_controllen = sizeof(control.bytes);
  ssize_t received;
  do { received = recvmsg(STDIN_FILENO, &message, 0); } while (received < 0 && errno == EINTR);
  if (received < 0) {
    perror("Execution input handoff failed");
    return 126;
  }
  struct cmsghdr *header = CMSG_FIRSTHDR(&message);
  if (received != 1 || acknowledgement != 1 || (message.msg_flags & MSG_CTRUNC) ||
      header == NULL || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
      header->cmsg_len != CMSG_LEN(sizeof(int))) {
    fputs("Execution input handoff invalid\n", stderr);
    return 126;
  }
  int original_input = *(int *)CMSG_DATA(header);
  /* Keep the sender's pipe alive until the received descriptor owns its reference. */
  acknowledgement = 2;
  ssize_t confirmed;
  do { confirmed = write(STDIN_FILENO, &acknowledgement, 1); } while (confirmed < 0 && errno == EINTR);
  if (confirmed != 1) {
    perror("Execution input confirmation failed");
    return 126;
  }
  if (dup2(original_input, STDIN_FILENO) < 0) {
    perror("Execution input descriptor failed");
    return 126;
  }
  close(original_input);
  execv(argv[1], argv + 1);
  int status = errno == ENOENT ? 127 : 126;
  perror("Execution target exec failed");
  return status;
}
#endif
