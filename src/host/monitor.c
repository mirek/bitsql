#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <sys/resource.h>
int64_t bitsql_clock_ticks(void) {
  struct timespec t;
  clock_gettime(CLOCK_REALTIME, &t);
  return (int64_t)t.tv_sec * 10000000 + t.tv_nsec / 100 + INT64_C(621355968000000000);
}
int64_t bitsql_cpu_us(void) {
  struct timespec t;
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
  return (int64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}
int32_t bitsql_cpu_count(void) { return (int32_t)sysconf(_SC_NPROCESSORS_ONLN); }
int64_t bitsql_memory_kb(void) { return (int64_t)sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGESIZE) / 1024; }

#include <stdio.h>
#include <glob.h>
static int bitsql_sockets, bitsql_cores;
static void bitsql_topology(void) {
  if (bitsql_sockets) return;
  int packages[8192], cores[8192], n=0;
  long cpus = sysconf(_SC_NPROCESSORS_CONF);
  for (int cpu=0; cpu<cpus && n<8192; cpu++) {
    char path[160]; int package, core;
    snprintf(path,sizeof(path),"/sys/devices/system/cpu/cpu%d/topology/physical_package_id",cpu);
    FILE *f=fopen(path,"r"); if (!f) continue;
    int ok=fscanf(f,"%d",&package); fclose(f); if(ok!=1) continue;
    snprintf(path,sizeof(path),"/sys/devices/system/cpu/cpu%d/topology/core_id",cpu);
    f=fopen(path,"r"); if (!f) continue;
    ok=fscanf(f,"%d",&core); fclose(f); if(ok!=1) continue;
    int seen_package=0,seen_core=0;
    for(int j=0;j<n;j++) {
      if(packages[j]==package) {seen_package=1;if(cores[j]==core)seen_core=1;}
    }
    if(!seen_package)bitsql_sockets++;
    if(!seen_core){packages[n]=package;cores[n++]=core;bitsql_cores++;}
  }
}
int32_t bitsql_socket_count(void) { bitsql_topology(); return bitsql_sockets; }
int32_t bitsql_cores_per_socket(void) { bitsql_topology(); return bitsql_sockets ? bitsql_cores/bitsql_sockets : 0; }
int32_t bitsql_numa_count(void) {
  glob_t paths={0}; int count=0;
  if(glob("/sys/devices/system/node/node[0-9]*",0,NULL,&paths)==0)count=(int)paths.gl_pathc;
  globfree(&paths);return count;
}
int32_t bitsql_container_type(void) {
  return access("/.dockerenv",F_OK)==0 || access("/run/.containerenv",F_OK)==0 ? 1 : 0;
}
int64_t bitsql_boot_ms(void) {
  struct timespec t;clock_gettime(CLOCK_BOOTTIME,&t);
  return (int64_t)t.tv_sec*1000+t.tv_nsec/1000000;
}
