// Linked into the PGO-instrumented host only (scripts/docker-publish.sh):
// the harness stops servers with SIGTERM, which would skip the atexit
// handler that writes the profile; exit normally instead.
#include <signal.h>
#include <stdlib.h>
static void bitsql_pgo_exit(int sig) { (void)sig; exit(0); }
__attribute__((constructor)) static void bitsql_pgo_init(void) {
  signal(SIGTERM, bitsql_pgo_exit);
  signal(SIGINT, bitsql_pgo_exit);
}
