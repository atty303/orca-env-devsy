import { spawn, type ChildProcess } from "node:child_process";

export type Environment = Record<string, string | undefined>;
export const children = new Set<ChildProcess>();

export function start(argv: string[], options: { cwd?: string; env?: Environment; input?: string; inherit?: boolean; signal?: AbortSignal } = {}) {
  options.signal?.throwIfAborted();
  const child = spawn(argv[0], argv.slice(1), {
    cwd: options.cwd,
    env: options.env ?? process.env,
    detached: true,
    stdio: ["pipe", options.inherit ? "inherit" : "pipe", options.inherit ? "inherit" : "pipe"],
  });
  children.add(child);
  const abort = () => { try { stop(child); } catch { /* Termination is checked during owned cleanup. */ } };
  options.signal?.addEventListener("abort", abort, { once: true });
  const retire = () => { children.delete(child); options.signal?.removeEventListener("abort", abort); };
  const retainGroup = () => {
    if (!groupExists(child)) { retire(); return; }
    const watcher = setInterval(() => {
      if (!children.has(child) || !groupExists(child)) {
        retire();
        clearInterval(watcher);
      }
    }, 20);
    watcher.unref();
  };
  child.once("close", retainGroup);
  child.on("error", () => { if (!child.pid) retire(); });
  child.stdin?.on("error", () => {
    try { stop(child, "SIGKILL"); } catch { /* Owned cleanup checks termination. */ }
    child.emit("error", new Error("Child input stream failed"));
  });
  if (options.input !== undefined) child.stdin?.end(options.input);
  else child.stdin?.end();
  return child;
}

function groupExists(child: ChildProcess) {
  if (!child.pid || child.pid <= 1) return false;
  try { process.kill(-child.pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code !== "ESRCH"; }
}

export function stop(child: ChildProcess, signal: NodeJS.Signals = "SIGTERM") {
  if (!child.pid || child.pid <= 1 || !children.has(child)) return;
  try { process.kill(-child.pid!, signal); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EPERM") child.kill(signal);
    else if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
  }
}

export async function waitForExit(child: ChildProcess, timeout = 5000) {
  if (!child.pid || child.pid <= 1 || child.exitCode !== null || child.signalCode !== null) return;
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Child exit deadline exceeded")), timeout);
    child.once("close", () => { clearTimeout(timer); resolve(); });
    child.once("error", error => { clearTimeout(timer); reject(error); });
  });
}

function abandonStreams(child: ChildProcess) {
  child.stdin?.destroy();
  child.stdout?.destroy();
  child.stderr?.destroy();
  child.unref();
}

export async function terminate(child: ChildProcess) {
  if (!child.pid || child.pid <= 1 || !children.has(child)) return;
  // Retain this owned group through termination even if its leader closes first.
  const group = child.pid;
  const started = performance.now();
  let killed = false;
  try {
    stop(child);
    for (;;) {
      try { process.kill(-group, 0); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ESRCH") {
          children.delete(child);
          return;
        }
        // macOS can report EPERM while the group's leader is an unreaped zombie.
        if ((error as NodeJS.ErrnoException).code !== "EPERM") throw error;
      }
      const elapsed = performance.now() - started;
      if (elapsed >= 5000) throw new Error("Child termination deadline exceeded");
      if (!killed && elapsed >= 3000) {
        try { process.kill(-group, "SIGKILL"); }
        catch (error) {
          if ((error as NodeJS.ErrnoException).code === "EPERM") child.kill("SIGKILL");
          else if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
        }
        killed = true;
      }
      await Bun.sleep(20);
    }
  } finally { abandonStreams(child); }
}

export function processFailureCategory(output: string) {
  const text = output.toLowerCase();
  for (const [category, phrases] of Object.entries({
    memory: ["out of memory", "cannot allocate memory", "memory allocation"],
    disk: ["no space left on device"],
    git_credentials: ["could not read username", "could not read password", "authentication failed", "invalid credentials", "terminal prompts disabled"],
    git_objects: ["bad object", "bad tree", "not a valid object", "invalid object", "unable to read sha1 file", "nonexistent object"],
    ssh_host_key: ["host key verification failed", "remote host identification has changed", "no matching host key type found"],
    ssh_auth: ["permission denied (publickey"],
    ssh_mux: ["control socket", "controlsocket", "master is not running", "mux_client"],
    ssh_channel: ["administratively prohibited", "open failed", "connect failed"],
    resource_exists: ["already exists", "file exists"],
    runtime: ["libkrun", "kvm_create_vm", "runtime error"],
    killed: ["sigkill", "signal: 9"],
    panic: ["panicked", "panic", "exit status: 101"],
    aborted: ["sigabrt"],
    config: ["invalid config", "invalid argument"],
    vm_start: ["start microsandbox vm", "failed to start vm"],
    vm_boot: ["failed to start", "process exited before"],
    network: ["network builder"],
    image: ["image error"],
    database: ["sqlite", "database"],
    vm_image: ["ensure microsandbox final image", "prepare microsandbox final image"],
    vm_create: ["create microsandbox vm"],
    connection: ["connection refused", "connection closed", "connection reset", "broken pipe"],
    timeout: ["timed out", "timeout"],
    permission: ["permission denied"],
    cli_option: ["unknown flag", "unknown option", "unrecognized option"],
  })) if (phrases.some(phrase => text.includes(phrase))) return category;
  return "process_exit";
}

export async function run(argv: string[], options: { cwd?: string; env?: Environment; input?: string; timeout?: number; output?: "stdout" | "stderr"; inherit?: boolean; signal?: AbortSignal; onFailure?: (result: { outcome: "exit" | "timeout" | "aborted"; exitCode: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string }) => void } = {}) {
  const child = start(argv, options);
  let stdout = "", stderr = "";
  let failureObserved = false;
  const observeFailure = (outcome: "exit" | "timeout" | "aborted", exitCode: number | null, signal: NodeJS.Signals | null) => {
    if (failureObserved) return;
    failureObserved = true;
    try { options.onFailure?.({ outcome, exitCode, signal, stdout, stderr }); } catch { /* Diagnostics must not replace the process result. */ }
  };
  const limit = 8 * 1024 * 1024;
  const collect = (which: "stdout" | "stderr", data: Buffer) => {
    if (which === "stdout") stdout += data.toString(); else stderr += data.toString();
    if (stdout.length + stderr.length > limit) stop(child, "SIGKILL");
  };
  child.stdout?.on("data", (data) => collect("stdout", data));
  child.stderr?.on("data", (data) => collect("stderr", data));
  let timer: ReturnType<typeof setTimeout>;
  let abort: (() => void) | undefined;
  try {
    const code = await new Promise<number | null>((resolve, reject) => {
      abort = () => {
        try { stop(child); } catch { /* Cleanup retains ownership if signaling fails. */ }
        observeFailure("aborted", child.exitCode, child.signalCode);
        abandonStreams(child);
        reject(options.signal!.reason);
      };
      options.signal?.addEventListener("abort", abort, { once: true });
      timer = setTimeout(() => {
        try { stop(child, "SIGKILL"); } catch { /* Report the deadline failure below. */ }
        observeFailure("timeout", child.exitCode, child.signalCode);
        abandonStreams(child);
        reject(new Error("Child command deadline exceeded (timeout)"));
      }, options.timeout ?? 120_000);
      child.once("error", reject);
      child.once("close", resolve);
    });
    if (code !== 0) {
      observeFailure("exit", code, child.signalCode);
      // Subprocess streams can contain pairing/authentication data. Callers
      // consume successful results; failures expose only a fixed category and code.
      throw new Error(`${argv[0].split("/").at(-1)} failed (${code ?? child.signalCode}, ${processFailureCategory(stdout + "\n" + stderr)})`);
    }
    return options.output === "stderr" ? stderr : stdout;
  } finally {
    clearTimeout(timer!);
    if (abort) options.signal?.removeEventListener("abort", abort);
  }
}

export async function withAbort<T>(signal: AbortSignal | undefined, action: () => Promise<T>): Promise<T> {
  signal?.throwIfAborted();
  if (!signal) return action();
  let abort: () => void;
  try {
    return await Promise.race([
      new Promise<never>((_, reject) => {
        abort = () => reject(signal.reason);
        signal.addEventListener("abort", abort, { once: true });
      }),
      action(),
    ]);
  } finally { signal.removeEventListener("abort", abort!); }
}

export function processScope(signal?: AbortSignal) {
  return {
    run: (argv: string[], options: Parameters<typeof run>[1] = {}) => run(argv, { ...options, signal }),
    start: (argv: string[], options: Parameters<typeof start>[1] = {}) => start(argv, { ...options, signal }),
    until: (check: () => Promise<boolean>, timeout?: number) => until(check, timeout, signal),
  };
}

export async function until(check: () => Promise<boolean>, timeout = 30_000, signal?: AbortSignal) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    signal?.throwIfAborted();
    if (await withAbort(signal, check)) {
      if (Date.now() > deadline) throw new Error("Readiness deadline exceeded");
      return;
    }
    await Bun.sleep(200);
  }
  throw new Error("Readiness deadline exceeded");
}

export function quote(value: string) { return "'" + value.replaceAll("'", "'\"'\"'") + "'"; }
