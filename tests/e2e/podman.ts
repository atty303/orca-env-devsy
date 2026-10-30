import { appendFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { processFailureCategory } from "../../scripts/process.ts";
import { providerOperationObservation } from "./diagnostics.ts";

const operations = new Set(["run", "start", "create", "build", "pull", "exec", "inspect", "rm", "stop", "kill", "network", "volume", "info", "version"]);
const markers = ["crun", "runc", "netavark", "aardvark", "slirp4netns", "rootlessport", "conmon", "cgroup", "dbus", "systemd", "overlay", "mount", "network", "namespace", "permission", "not found", "already exists", "invalid", "quota", "lock", "database", "socket", "timeout", "resource", "busy", "setns", "address", "port", "rootfs", "chown", "uid", "gid", "subuid", "iptables", "nftables", "re-exec", "oci runtime", "executable file", "short-name", "manifest", "registry", "unauthorized", "connection refused"];

export function classifyPodman(output: string) {
  const text = output.toLowerCase();
  // Fixed runtime operations and errno phrases distinguish OCI failures without
  // retaining container names, paths, arguments or process output.
  const operations = ["sethostname", "setdomainname", "setresuid", "setresgid", "setgroups", "setns", "unshare", "clone", "execve", "chdir", "pivot_root", "mount_setattr", "mount", "seccomp", "bpf", "sd-bus call", "re-exec", "cgroup.subtree_control", "cpu.max", "memory.max", "pids.max",
    "open executable", "setrlimit", "rlimit_nofile", "rlimit_nproc", "oom_score_adj", "prctl", "capset", "no new privs", "personality", "setsid", "ptsname", "unlockpt", "tcgetattr", "tcsetattr", "ioctl", "terminal", "dup", "close", "fcntl", "readlink", "openat2", "open", "writing file", "write", "read", "stat", "mkdir", "chroot", "mknod", "symlink", "xattr", "fsopen", "fsconfig", "fsmount", "move_mount", "getcwd", "pipe", "sendmsg", "recvmsg", "socketpair", "epoll", "signalfd", "sigprocmask", "sigaction", "fork", "waitpid", "pidfd", "mmap", "munmap", "copy_file_range", "putenv", "clearenv", "unknown version", "invalid internal state", "too many paths", "failed to reset affinity", "sched_setaffinity", "sched_setattr", "setpriority", "memfd", "fexecve", "reexecute"];
  const errors = ["invalid argument", "invalid unit name", "file name too long", "permission denied", "operation not permitted", "no such file or directory", "device or resource busy", "cannot allocate memory", "no space left on device", "resource temporarily unavailable", "function not implemented"];
  const targets = ["cpuset.cpus", "cpuset.mems", "cgroup.procs", "cgroup.subtree_control", "cpu.max", "cpu.weight", "pids.max", "memory.max", "io.max", "io.weight", "oom_score_adj", "timens_offsets", "ping_group_range", "ip_unprivileged_port_start", "/proc/self/attr/", "/proc/thread-self/attr/"];
  return { category: processFailureCategory(text), markers: markers.filter(marker => text.includes(marker)), runtimeOperations: operations.filter(operation => text.includes(operation)), runtimeErrors: errors.filter(error => text.includes(error)), runtimeTargets: targets.filter(target => text.includes(target)), bareWrite: /(?:^|:\s*)write:\s*invalid argument/i.test(text) };
}

export async function installPodmanDiagnostics(root: string) {
  const binary = Bun.which("podman");
  if (!binary) throw new Error("Podman binary missing");
  const wrapper = root + "/bin/podman";
  await writeFile(root + "/podman-operations.jsonl", "", { mode: 0o600 });
  await writeFile(wrapper, `#!${process.execPath}\nimport { launch } from ${JSON.stringify(resolve("tests/e2e/podman.ts"))};\nawait launch(${JSON.stringify(binary)}, ${JSON.stringify(root + "/podman-failures.jsonl")}, ${JSON.stringify(root + "/podman-operations.jsonl")});\n`, { mode: 0o700 });
  return wrapper;
}

export async function launch(binary: string, report: string, operationsReport: string) {
  const args = process.argv.slice(2);
  const startedAt = new Date().toISOString();
  const started = performance.now();
  const child = Bun.spawn([binary, ...args], { stdin: "inherit", stdout: "inherit", stderr: "pipe" });
  process.once("SIGTERM", () => child.kill("SIGTERM"));
  process.once("SIGINT", () => child.kill("SIGINT"));
  let tail = "";
  const forwarding = (async () => {
    for await (const chunk of child.stderr) {
      tail = (tail + Buffer.from(chunk).toString()).slice(-16_384);
      process.stderr.write(chunk);
    }
  })();
  const [code] = await Promise.all([child.exited, forwarding]);
  const operation = args.find(arg => operations.has(arg)) ?? "other";
  const elapsedMs = Math.ceil(performance.now() - started);
  const observation = providerOperationObservation(operation, elapsedMs, code, tail);
  if (observation) try {
    await appendFile(operationsReport, JSON.stringify({ startedAt, finishedAt: new Date().toISOString(), ...observation, ...(operation === "exec" ? { program: podmanExecProgram(args) } : {}) }) + "\n", { mode: 0o600 });
  } catch {
    process.stderr.write("E2E provider operation recording failed (podman)\n");
  }
  if (code !== 0 && ["run", "start", "create", "build", "pull", "exec", "network"].includes(operation)) try {
    await appendFile(report, JSON.stringify({ operation, exitCode: code, elapsedMs, ...classifyPodman(tail) }) + "\n", { mode: 0o600 });
  } catch { /* Recording must preserve the runtime's result. */ }
  process.exit(code);
}

export function podmanExecProgram(args: string[]) {
  const commandIndex = args.indexOf("exec");
  if (commandIndex < 0) return undefined;
  const valueOptions = new Set(["--detach-keys", "--env", "--env-file", "--preserve-fd", "--user", "--workdir", "-e", "-u", "-w"]);
  const programs = new Set(["ash", "bash", "cat", "chmod", "chown", "cp", "dash", "env", "git", "mkdir", "mv", "node", "python", "python3", "rm", "sh", "sleep", "test", "timeout"]);
  let index = commandIndex + 1;
  let latest = false;
  while (index < args.length && args[index].startsWith("-")) {
    const option = args[index];
    if (option === "--latest") { latest = true; index++; continue; }
    if (valueOptions.has(option) && index + 1 < args.length) index++;
    index++;
  }
  if (!latest) index++;
  const command = args[index];
  if (!command) return undefined;
  const basename = command.split("/").at(-1)!;
  return programs.has(basename) ? basename : "other";
}
