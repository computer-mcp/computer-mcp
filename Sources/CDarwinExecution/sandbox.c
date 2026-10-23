#include "CDarwinExecution.h"
#include <dlfcn.h>
#include <pthread.h>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int (*check_path)(pid_t, const char *, int, ...);
static int no_report;

static void resolve(void) {
  void *library = dlopen("/usr/lib/libsandbox.dylib", RTLD_NOW | RTLD_LOCAL);
  if (!library) return;
  int *flag = dlsym(library, "SANDBOX_CHECK_NO_REPORT");
  if (!flag) return;
  no_report = *flag;
  check_path = dlsym(library, "sandbox_check");
}

int execution_sandbox_check(pid_t pid, const char *path) {
  pthread_once(&once, resolve);
  return check_path ? check_path(pid, "file-read-data", 1 | no_report, path) : -1;
}
