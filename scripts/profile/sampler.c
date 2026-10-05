/* SIGPROF sampler for profiling the emulator without perf/ptrace (scripts/profile.sh).
 * LD_PRELOAD it with SAMPLER_OUT=prefix: every 0.5 ms of CPU time it records a
 * backtrace() into prefix.<pid> and copies /proc/self/maps to prefix.<pid>.maps. */
#define _GNU_SOURCE
#include <execinfo.h>
#include <signal.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define DEPTH 64
#define BUF 32
/* record: count, then DEPTH slots */
static void *buf[BUF][DEPTH + 1];
static int n, fd = -1;
static void flush(void) { if (n && fd >= 0) write(fd, buf, sizeof(buf[0]) * n); n = 0; }
static void on_prof(int sig) {
  int e = errno;
  int d = backtrace(&buf[n][1], DEPTH);
  buf[n][0] = (void *)(long)d;
  if (++n == BUF) flush();
  errno = e;
}
__attribute__((constructor)) static void init(void) {
  const char *out = getenv("SAMPLER_OUT");
  if (!out) return;
  char path[4096];
  snprintf(path, sizeof path, "%s.%d", out, getpid());
  fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  snprintf(path, sizeof path, "%s.%d.maps", out, getpid());
  int mfd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600), in = open("/proc/self/maps", O_RDONLY);
  char tmp[65536]; ssize_t r;
  while ((r = read(in, tmp, sizeof tmp)) > 0) write(mfd, tmp, r);
  close(in); close(mfd);
  void *warm[4]; backtrace(warm, 4);
  struct sigaction sa; memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_prof; sa.sa_flags = SA_RESTART;
  sigaction(SIGPROF, &sa, 0);
  struct itimerval it = {{0, 500}, {0, 500}}; /* 2 kHz of CPU time */
  setitimer(ITIMER_PROF, &it, 0);
  atexit(flush);
}
