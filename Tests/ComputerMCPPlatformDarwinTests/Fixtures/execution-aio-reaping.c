#include <CommonCrypto/CommonDigest.h>
#include <aio.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <sandbox.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}
static int digest(unsigned char result[CC_SHA256_DIGEST_LENGTH], off_t *size) {
  int fd = open("objects", O_RDONLY | O_NOFOLLOW);
  if (fd < 0) return -1;
  struct stat info;
  if (fstat(fd, &info)) { close(fd); return -1; }
  *size = info.st_size;
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  unsigned char bytes[65536];
  ssize_t count;
  while ((count = read(fd, bytes, sizeof(bytes))) > 0)
    CC_SHA256_Update(&context, bytes, (CC_LONG)count);
  close(fd);
  if (count < 0) return -1;
  CC_SHA256_Final(result, &context);
  return 0;
}
int main(int argc, char **argv) {
  if (argc != 3 || chdir(argv[1])) return 2;
  int stopped = !strcmp(argv[2], "stopped");
  alarm(15);
  int handshake[2];
  if (pipe(handshake)) return 3;
  pid_t child = fork();
  if (child < 0) return 4;
  if (!child) {
    close(handshake[0]);
    char profile[8192];
    snprintf(profile, sizeof(profile),
      "(version 1)(deny default)(allow process-fork)(allow process-exec)"
      "(allow process-info* (target same-sandbox))(allow signal (target same-sandbox))"
      "(allow file-read*)(allow file-write* (subpath \"%s\"))", argv[1]);
    char *error = NULL;
    if (sandbox_init(profile, 0, &error)) { fprintf(stderr, "%s\n", error); _exit(5); }
    int fd = open("objects", O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0 || fcntl(fd, F_NOCACHE, 1)) _exit(6);
    const size_t size = 32 * 1024 * 1024;
    void *data = malloc(size);
    if (!data) _exit(7);
    memset(data, 0x5a, size);
    struct aiocb writes[8] = {0};
    int receipt[2] = {0};
    for (int i = 0; i < 8; i++) {
      writes[i].aio_fildes = fd;
      writes[i].aio_offset = (off_t)(i * size);
      writes[i].aio_buf = data;
      writes[i].aio_nbytes = size;
      writes[i].aio_sigevent.sigev_notify = SIGEV_NONE;
      if (aio_write(&writes[i])) break;
      receipt[0]++;
    }
    for (int i = 0; i < receipt[0]; i++)
      if (aio_error(&writes[i]) == EINPROGRESS) receipt[1]++;
    if (write(handshake[1], receipt, sizeof(receipt)) != sizeof(receipt)) _exit(8);
    if (stopped) raise(SIGSTOP);
    for (;;) pause();
  }
  close(handshake[1]);
  int receipt[2] = {0}, status = 0;
  ssize_t received = read(handshake[0], receipt, sizeof(receipt));
  if (received != sizeof(receipt) || receipt[0] != 8 || receipt[1] == 0) {
    kill(child, SIGKILL); waitpid(child, &status, 0); return 9;
  }
  if (stopped) {
    pid_t waited;
    do { waited = waitpid(child, &status, WUNTRACED); } while (waited < 0 && errno == EINTR);
    if (waited != child || !WIFSTOPPED(status)) {
      kill(child, SIGKILL); waitpid(child, NULL, 0); return 10;
    }
  }
  struct proc_bsdshortinfo before = {0};
  proc_pidinfo(child, PROC_PIDT_SHORTBSDINFO, 1, &before, sizeof(before));
  double killed = now();
  if (kill(child, SIGKILL)) return 11;
  pid_t waited;
  do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
  if (waited != child || !WIFSIGNALED(status) || WTERMSIG(status) != SIGKILL) return 12;
  double reaped = now();
  unsigned char first[CC_SHA256_DIGEST_LENGTH], next[CC_SHA256_DIGEST_LENGTH];
  off_t initial_size = 0, next_size = 0;
  if (digest(first, &initial_size)) return 13;
  int changed = 0, samples = 1;
  do {
    usleep(10000);
    if (digest(next, &next_size)) return 14;
    samples++;
    if (next_size != initial_size || memcmp(first, next, sizeof(first))) { changed = 1; break; }
  } while (now() - reaped < 1.0);
  printf("mode=%s pid=%d submitted=%d pending_at_handshake=%d before_state=%u "
         "reaped=1 kill_to_reap_ms=%.3f observation_ms=%.3f samples=%d "
         "size_after_reap=%lld size_final=%lld changed=%d sha256=",
         argv[2], child, receipt[0], receipt[1], before.pbsi_status,
         (reaped-killed)*1000, (now()-reaped)*1000, samples, initial_size, next_size, changed);
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) printf("%02x", first[i]);
  printf("\n");
  return changed ? 20 : 0;
}
