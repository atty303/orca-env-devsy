#include <errno.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

int64_t orca_process_start(int pid) {
#ifdef __APPLE__
  struct kinfo_proc info;
  size_t size = sizeof(info);
  int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return -1;
  if (size == 0) return 0;
  return (int64_t)info.kp_proc.p_starttime.tv_sec * 1000000 + info.kp_proc.p_starttime.tv_usec;
#else
  char path[64], buffer[4096];
  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  FILE *file = fopen(path, "r");
  if (!file) return errno == ENOENT ? 0 : -1;
  char *read = fgets(buffer, sizeof(buffer), file);
  fclose(file);
  if (!read) return -1;
  char *field = strrchr(buffer, ')');
  if (!field) return -1;
  field += 2;
  for (int index = 3; index < 22; index++) {
    field = strchr(field, ' ');
    if (!field) return -1;
    field++;
  }
  return (int64_t)strtoull(field, NULL, 10);
#endif
}

int orca_group_exists(int pid) {
  if (kill(-pid, 0) == 0) return 1;
  return errno == ESRCH ? 0 : -1;
}
