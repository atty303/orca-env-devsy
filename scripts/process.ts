import { spawn, type ChildProcess } from "node:child_process";

export type Environment = Record<string, string | undefined>;
export const children = new Set<ChildProcess>();

export function start(argv: string[], options: { cwd?: string; env?: Environment; input?: string; inherit?: boolean } = {}) {
  const child = spawn(argv[0], argv.slice(1), {
    cwd: options.cwd,
    env: options.env ?? process.env,
    detached: true,
    stdio: ["pipe", options.inherit ? "inherit" : "pipe", options.inherit ? "inherit" : "pipe"],
  });
  children.add(child);
  child.once("close", () => children.delete(child));
  child.once("error", () => children.delete(child));
  if (options.input !== undefined) child.stdin?.end(options.input);
  else child.stdin?.end();
  return child;
}

export function stop(child: ChildProcess, signal: NodeJS.Signals = "SIGTERM") {
  if (!child.pid || child.pid <= 1 || child.exitCode !== null || child.signalCode !== null) return;
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

export async function terminate(child: ChildProcess) {
  if (!child.pid || child.pid <= 1 || child.exitCode !== null || child.signalCode !== null) return;
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      try { stop(child, "SIGKILL"); } catch (error) { reject(error); }
    }, 3000);
    child.once("close", () => { clearTimeout(timer); resolve(); });
    child.once("error", error => { clearTimeout(timer); reject(error); });
    try { stop(child); } catch (error) { clearTimeout(timer); reject(error); }
  });
}

export function processFailureCategory(output: string) {
  const text = output.toLowerCase();
  for (const [category, phrases] of Object.entries({
    memory: ["out of memory", "cannot allocate memory", "memory allocation"],
    disk: ["no space left on device"],
    git_credentials: ["could not read username", "could not read password", "authentication failed", "invalid credentials", "terminal prompts disabled"],
    git_objects: ["bad object", "bad tree", "not a valid object", "invalid object"],
    ssh_auth: ["permission denied (publickey", "host key verification failed"],
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

export async function run(argv: string[], options: { cwd?: string; env?: Environment; input?: string; timeout?: number; output?: "stdout" | "stderr"; inherit?: boolean } = {}) {
  const child = start(argv, options);
  let stdout = "", stderr = "";
  const limit = 8 * 1024 * 1024;
  const collect = (which: "stdout" | "stderr", data: Buffer) => {
    if (which === "stdout") stdout += data.toString(); else stderr += data.toString();
    if (stdout.length + stderr.length > limit) stop(child, "SIGKILL");
  };
  child.stdout?.on("data", (data) => collect("stdout", data));
  child.stderr?.on("data", (data) => collect("stderr", data));
  const timer = setTimeout(() => stop(child, "SIGKILL"), options.timeout ?? 120_000);
  try {
    const code = await new Promise<number | null>((resolve, reject) => {
      child.once("error", reject);
      child.once("close", resolve);
    });
    if (code !== 0) {
      // Subprocess streams can contain pairing/authentication data. Callers
      // consume successful results; failures expose only a fixed category and code.
      throw new Error(`${argv[0].split("/").at(-1)} failed (${code ?? child.signalCode}, ${processFailureCategory(stdout + "\n" + stderr)})`);
    }
    return options.output === "stderr" ? stderr : stdout;
  } finally { clearTimeout(timer); }
}

export async function until(check: () => Promise<boolean>, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) {
      if (Date.now() > deadline) throw new Error("Readiness deadline exceeded");
      return;
    }
    await Bun.sleep(200);
  }
  throw new Error("Readiness deadline exceeded");
}

export function quote(value: string) { return "'" + value.replaceAll("'", "'\"'\"'") + "'"; }
