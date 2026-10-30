#include <errno.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/un.h>
#ifdef __APPLE__
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <libproc.h>
#define ORCA_PIPE_EOF 0x080
#else
#include <dirent.h>
#endif

int orca_socket_directory(char *buffer, int capacity, const char *runtime, const char *temp) {
#ifndef __APPLE__
  temp = NULL;
#endif
  const char *bases[] = {runtime, temp, "/tmp"};
  for (int i = 0; i < 3; i++) {
    const char *base = bases[i];
    struct stat info;
    if (!base || base[0] != '/' || stat(base, &info) != 0 || !S_ISDIR(info.st_mode)) continue;
    if (i != 2 && (info.st_uid != geteuid() || (info.st_mode & 0777) != 0700)) continue;
    int length = snprintf(buffer, (size_t)capacity, "%s/orca-env-devsy.XXXXXX", base);
    if (length < 0 || length >= capacity || (size_t)length + 25 >= sizeof(((struct sockaddr_un *)0)->sun_path)) continue;
    if (mkdtemp(buffer)) return length;
  }
  return -1;
}

int orca_validate_socket_directory(const char *path) {
  struct stat info;
  return lstat(path, &info) == 0 && S_ISDIR(info.st_mode) &&
    info.st_uid == geteuid() && (info.st_mode & 0777) == 0700 ? 0 : -1;
}

int orca_process_executable(int pid, char *buffer, int capacity) {
#ifdef __APPLE__
  int length = proc_pidpath(pid, buffer, (uint32_t)capacity);
  return length > 0 ? (int)strlen(buffer) : -1;
#else
  return -1;
#endif
}

int64_t orca_process_start(int pid) {
#ifdef __APPLE__
  struct kinfo_proc info;
  size_t size = sizeof(info);
  int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return -1;
  if (size == 0 || info.kp_proc.p_stat == SZOMB) return 0;
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
  if (*field == 'Z') return 0;
  for (int index = 3; index < 22; index++) {
    field = strchr(field, ' ');
    if (!field) return -1;
    field++;
  }
  return (int64_t)strtoull(field, NULL, 10);
#endif
}

int orca_process_is_zombie(int pid) {
#ifdef __APPLE__
  struct kinfo_proc info;
  size_t size = sizeof(info);
  int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return -errno;
  if (size == 0) return 0;
  return info.kp_proc.p_stat == SZOMB ? 1 : 0;
#else
  char path[64], buffer[4096];
  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  FILE *file = fopen(path, "r");
  if (!file) return errno == ENOENT ? 0 : -errno;
  char *read = fgets(buffer, sizeof(buffer), file);
  fclose(file);
  if (!read) return -EIO;
  char *field = strrchr(buffer, ')');
  if (!field) return -EINVAL;
  return field[2] == 'Z' ? 1 : 0;
#endif
}

int orca_group_exists(int pid) {
  if (kill(-pid, 0) != 0) {
    int error = errno;
    return error == ESRCH ? 0 : -error;
  }
#ifdef __APPLE__
  return 1;
#else
  DIR *proc = opendir("/proc");
  if (!proc) return -errno;
  int unknown = 0;
  struct dirent *entry;
  while ((entry = readdir(proc))) {
    char *end;
    long member = strtol(entry->d_name, &end, 10);
    if (*end || member <= 0) continue;
    char path[64], buffer[4096];
    snprintf(path, sizeof(path), "/proc/%ld/stat", member);
    FILE *file = fopen(path, "r");
    if (!file) {
      if (errno != ENOENT && errno != ESRCH) unknown = errno;
      continue;
    }
    char *read = fgets(buffer, sizeof(buffer), file);
    int read_error = errno;
    fclose(file);
    if (!read) {
      unknown = read_error != 0 ? read_error : EIO;
      continue;
    }
    char *field = strrchr(buffer, ')');
    char state;
    long parent, group;
    if (!field || sscanf(field + 2, "%c %ld %ld", &state, &parent, &group) != 3) {
      unknown = EIO;
      continue;
    }
    if (group == pid && state != 'Z' && state != 'X' && state != 'x') {
      closedir(proc);
      return 1;
    }
  }
  closedir(proc);
  return unknown ? -unknown : 0;
#endif
}

static sigset_t proxy_sigmask;
static struct sigaction proxy_sigpipe;

int orca_prepare_proxy(void) {
  if (sigprocmask(SIG_SETMASK, NULL, &proxy_sigmask) != 0) return -1;
  return sigaction(SIGPIPE, NULL, &proxy_sigpipe);
}

int orca_transport_exec(const char *command, char *const args[]) {
  if (sigaction(SIGPIPE, &proxy_sigpipe, NULL) != 0) return -1;
  if (sigprocmask(SIG_SETMASK, &proxy_sigmask, NULL) != 0) return -1;
  return execvp(command, args);
}

int orca_transport_input_closed(int pid) {
#ifdef __APPLE__
  struct pipe_fdinfo info;
  errno = 0;
  int size = proc_pidfdinfo(pid, STDIN_FILENO, PROC_PIDFDPIPEINFO, &info, sizeof(info));
  if (size <= 0) return -(65536 + errno);
  if (size != sizeof(info)) return -131072;
  return (info.pipeinfo.pipe_status & ORCA_PIPE_EOF) != 0;
#else
  char path[64];
  snprintf(path, sizeof(path), "/proc/%d/fd/0", pid);
  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return -(196608 + errno);
  struct stat info;
  int result;
  if (fstat(fd, &info) != 0) result = -(262144 + errno);
  else if (!S_ISFIFO(info.st_mode)) result = -327680;
  else {
    struct pollfd watch = { .fd = fd, .events = 0 };
    if (poll(&watch, 1, 0) < 0) result = -(393216 + errno);
    else if (watch.revents & (POLLERR | POLLNVAL)) result = -458752;
    else result = (watch.revents & POLLHUP) != 0;
  }
  close(fd);
  return result;
#endif
}
