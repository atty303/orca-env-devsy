import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile, readFile, rm, lstat } from "node:fs/promises";
import { resolve } from "node:path";
import { tmpdir } from "node:os";
import { run, start, stop, children, waitForExit, until, quote, type Environment } from "./process.ts";

const devsy = Bun.which("devsy");
assert(devsy);
const adapter = resolve("_build/native/release/build/cmd/main/main.exe");
let interrupted = false;
const interrupt = () => {
  if (interrupted) return;
  interrupted = true;
  for (const child of children) stop(child, "SIGTERM");
};
process.on("SIGINT", interrupt);
process.on("SIGTERM", interrupt);
try {
  for (const scenario of [{ port: 12049, disabled: false }, { port: 13449, disabled: false }, { port: 12049, disabled: true }]) {
    if (interrupted) throw new Error("Test interrupted");
    const root = await mkdtemp(tmpdir() + "/cr-");
    const sockets = await mkdtemp("/tmp/cs-");
    const id = "relay-" + root.split("/").at(-1)!.toLowerCase();
    const home = root + "/home", worker = root + "/worker";
    const env: Environment = { PATH: process.env.PATH, HOME: home, XDG_CONFIG_HOME: home + "/config", XDG_STATE_HOME: home + "/state", XDG_DATA_HOME: home + "/data", XDG_CACHE_HOME: home + "/cache", XDG_RUNTIME_DIR: home + "/run", DEVSY_HOME: root + "/devsy", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: home + "/.gitconfig", GIT_TERMINAL_PROMPT: "0" };
    const d = (args: string[]) => run([devsy, "--home", root + "/devsy", ...args], { env, timeout: 600_000 });
    const guest = (command: string) => run(["docker", "exec", id, "sh", "-c", command], { env, timeout: 5000 });
    const restoreOwnership = async () => {
      // A disposable helper also works when the workspace container is stopped.
      if (process.platform === "linux") try { await run(["docker", "run", "--name", id + "-cleanup", "--rm", "--network", "none", "--mount", `type=bind,source=${root}/workspace,target=/owned`, "--entrypoint", "chown", "mcr.microsoft.com/devcontainers/base:ubuntu", "-R", `${process.getuid!()}:${process.getgid!()}`, "/owned"], { env, timeout: 15_000 }); } finally {
        await run(["docker", "rm", "-f", id + "-cleanup"], { env, timeout: 5000 }).catch(() => {});
      }
    };
    const base = ["ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"];
    const ssh = (socket: string, args: string[]) => run([...base, "-S", socket, ...args], { env, timeout: 5000 });
    const proxy = [devsy, "--home", root + "/devsy", "--log-level", "debug", "workspace", "ssh", id, "--stdio", "--user", "root"].map(quote).join(" ");
    const drain = (child: ReturnType<typeof start>) => { child.stdout?.resume(); child.stderr?.resume(); return child; };
    const launchOwner = () => drain(start([...base, "-o", "ProxyCommand=" + proxy, "-M", "-S", sockets + "/a", "-N", "root@devsy-workspace"], { env }));
    const launchWorker = () => drain(start([adapter, "--tunnel-worker", worker], { env }));
    const succeeds = async (operation: () => Promise<unknown>) => { try { await operation(); return true; } catch { return false; } };
    const fill = async () => {
      const output = await guest('printf "protocol=https\\nhost=relay.example.invalid\\n\\n" | GIT_TERMINAL_PROMPT=0 git credential fill');
      assert(output.split("\n").includes("password=relay-test-dummy"));
    };
    const eventually = (check: () => Promise<boolean>, stage = "relay-recovery") => { console.log(`Relay assertion ${stage}: started`); return until(check, 5000).catch(() => { throw new Error(`${stage} exceeded 5000 ms`); }); };
    const ready = () => eventually(() => succeeds(() => guest(`curl --noproxy '*' -fsS --max-time 2 http://localhost:${scenario.port}/`)), "relay-http-ready");
    const filled = () => eventually(() => succeeds(fill), "authenticated-credential-fill");
    const status = async (expected: string) => eventually(async () => (await readFile(worker + "/git-status", "utf8").catch(() => "")).trim() === expected, "relay-status-" + expected);
    const master = () => ssh(sockets + "/orca/socket", ["-O", "check", "root@devsy-workspace"]);
    let owner: ReturnType<typeof start> | undefined, second: ReturnType<typeof start> | undefined;
    try {
      await mkdir(home, { recursive: true });
      await mkdir(root + "/workspace/.devcontainer", { recursive: true });
      await writeFile(root + "/helper", `#!${process.execPath}
  import { appendFile } from "node:fs/promises";
  await Bun.stdin.text();
  if (process.argv[2] === "get") {
    await appendFile(process.env.HOME + "/helper-calls", "get\\n");
    process.stdout.write("username=relay-test\\npassword=relay-test-dummy\\n");
  }
  `, { mode: 0o700 });
      await run(["git", "config", "--global", "credential.helper", root + "/helper"], { env });
      await run(["git", "config", "--global", "user.name", "E2E"], { env });
      await run(["git", "config", "--global", "user.email", "e2e@example.invalid"], { env });
      await writeFile(root + "/workspace/.devcontainer/devcontainer.json", JSON.stringify({ image: "mcr.microsoft.com/devcontainers/base:ubuntu", remoteUser: "root", containerEnv: { DEVSY_CREDENTIALS_SERVER_PORT: String(scenario.port) }, runArgs: ["--name", id] }));
      await d(["context", "set", "-o", "TELEMETRY=false", ...(scenario.disabled ? ["-o", "SSH_INJECT_GIT_CREDENTIALS=false"] : [])]);
      await d(["provider", "add", "docker"]);
      await d(["provider", "use", "docker"]);
      await d(["workspace", "up", root + "/workspace", "--id", id, "--uid", id + "-uid", "--ide-launch", "skip", "--ssh-configure=false"]);
      if (process.platform === "linux") {
        const expected: string = new Bun.CryptoHasher("sha256").update(await Bun.file(devsy).bytes()).digest("hex");
        assert.equal((await guest("sha256sum /usr/local/bin/devsy")).split(" ")[0], expected);
      }
      owner = launchOwner();
      await ready();
      if (!scenario.disabled) await filled();
      await mkdir(worker, { recursive: true });
      await mkdir(sockets + "/orca");
      const state = { adapterVersion: 1, connection: "orca-server", projectRoot: "/workspaces/" + id, workspaceId: id, workspaceUid: id + "-uid", user: "root", home: root + "/devsy", command: [devsy], devsyEnv: env, socketDirectory: sockets + "/orca", tunnelDirectory: worker, localPort: 18943 };
      await writeFile(worker + "/state.json", JSON.stringify(state));
      await writeFile(worker + "/enabled", "");
      second = launchWorker();
      await eventually(() => succeeds(() => ssh(sockets + "/orca/socket", ["-o", "ProxyCommand=false", "root@devsy-workspace", "true"])));
      if (scenario.disabled) {
        await status("disabled");
        assert(!await lstat(sockets + "/orca/credential-socket").then(() => true, () => false));
        assert(!await succeeds(fill));
        console.log("PASS disabled forwarding");
        continue;
      }
      await filled();
      await status("ready");
      const masterPid = async () => {
        const status = await run([...base, "-S", sockets + "/orca/socket", "-O", "check", "root@devsy-workspace"], { env, output: "stderr" });
        const pid = /pid=(\d+)/.exec(status)?.[1];
        assert(pid, "OpenSSH must identify the running master");
        return pid;
      };
      const before = await masterPid();
      const calls = await readFile(home + "/helper-calls", "utf8");
      await Bun.sleep(3000);
      assert.equal(await readFile(home + "/helper-calls", "utf8"), calls);
      await ssh(sockets + "/a", ["-O", "exit", "root@devsy-workspace"]);
      owner = undefined;
      await filled();
      await master();
      assert.equal(await masterPid(), before);
      assert((await lstat(sockets + "/orca/credential-socket")).isSocket());
      for (let round = 0; round < 2; round++) {
        const previous = (await guest("pgrep -o -f '[d]evsy internal agent container credentials-server --user root'")).trim();
        assert(/^\d+$/.test(previous));
        await guest("kill -TERM " + previous);
        await eventually(async () => await succeeds(async () => assert.notEqual((await guest("pgrep -o -f '[d]evsy internal agent container credentials-server --user root'")).trim(), previous)));
        await filled();
        await master();
        assert.equal(await masterPid(), before);
      }
      await ssh(sockets + "/orca/socket", ["-O", "exit", "root@devsy-workspace"]);
      await eventually(async () => await succeeds(async () => { await master(); assert.notEqual(await masterPid(), before); }));
      await filled();
      await d(["workspace", "stop", id]);
      await rm(worker + "/enabled", { force: true });
      await waitForExit(second);
      second = undefined;
      await d(["workspace", "up", id, "--ide-launch", "skip", "--ssh-configure=false"]);
      await writeFile(worker + "/enabled", "");
      second = launchWorker();
      await filled();
      await rm(worker + "/enabled");
      await waitForExit(second);
      second = undefined;
      owner = launchOwner();
      await filled();
      await writeFile(worker + "/enabled", "");
      second = launchWorker();
      await eventually(() => succeeds(master));
      await status("ready");
      await ssh(sockets + "/a", ["-O", "exit", "root@devsy-workspace"]);
      owner = undefined;
      await filled();
      stop(second, "SIGKILL");
      await waitForExit(second);
      second = undefined;
      await run([adapter, "reconnect"], { env });
      await filled();
      await run([adapter, "destroy"], { env, input: JSON.stringify({ schemaVersion: 1, recipeResult: { userData: state } }) });
      assert(!await Bun.file(worker + "/state.json").exists());
      console.log(`PASS relay recovery port=${scenario.port}, reconnect and cleanup`);
    } finally {
      await rm(worker + "/enabled", { force: true });
      if (owner) stop(owner, "SIGKILL");
      if (second) stop(second, "SIGKILL");
      for (const socket of [sockets + "/a", sockets + "/orca/socket", sockets + "/orca/credential-socket"]) await ssh(socket, ["-O", "exit", "root@devsy-workspace"]).catch(() => {});
      const cleanupErrors: string[] = [];
      await restoreOwnership().catch(() => cleanupErrors.push("bind-ownership"));
      await d(["workspace", "delete", id, "--force", "--ignore-not-found"]).catch(() => {});
      await run(["docker", "rm", "-f", id], { env }).catch(() => {});
      await rm(root, { recursive: true, force: true }).catch(() => cleanupErrors.push("fixture-directory"));
      await rm(sockets, { recursive: true, force: true }).catch(() => cleanupErrors.push("socket-directory"));
      assert.deepEqual(cleanupErrors, [], "Fixture cleanup must release owned resources");
    }
  }

  if (interrupted) throw new Error("Test interrupted");
} finally {
  process.removeListener("SIGINT", interrupt);
  process.removeListener("SIGTERM", interrupt);
}
