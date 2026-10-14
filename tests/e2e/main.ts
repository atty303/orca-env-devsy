import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, realpath, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { run, children, stop, quote, type Environment } from "../../scripts/process.ts";
import { Orca, latestOrca, type Provision, type Runtime } from "./orca.ts";
import { fixture, recipes } from "./fixture.ts";
import { services, auth, access } from "./services.ts";
import { workspace, firstUse, firstUseFailures } from "./scenarios.ts";
import { budgets, timings, measure } from "./timing.ts";
import { installMicrosandboxDiagnostics } from "./microsandbox.ts";
import { failureCategory, adapterDiagnostics } from "./diagnostics.ts";

const index = process.argv.indexOf("--provider");
const provider = index < 0 ? undefined : process.argv[index + 1];
if (!provider || !["docker", "podman", "microsandbox", "apple"].includes(provider)) throw new Error("Usage: mise run test:e2e -- --provider docker|podman|microsandbox|apple");
const root = await realpath(await mkdtemp("/tmp/oe-e2e-"));
const env: Environment = { PATH: process.env.PATH, HOME: root + "/home", XDG_STATE_HOME: root + "/state", XDG_CONFIG_HOME: root + "/config", XDG_DATA_HOME: root + "/data", XDG_CACHE_HOME: root + "/cache", XDG_RUNTIME_DIR: root + "/run", CODEX_HOME: root + "/codex", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: root + "/home/.gitconfig", GIT_TERMINAL_PROMPT: "0", GIT_AUTHOR_NAME: "E2E", GIT_AUTHOR_EMAIL: "e2e@example.invalid", GIT_COMMITTER_NAME: "E2E", GIT_COMMITTER_EMAIL: "e2e@example.invalid", SHELL: "/bin/sh" };
const devsy = Bun.which("devsy") ?? "";
const dhome = root + "/devsy";
if (provider === "podman") env.CONTAINER_HOST = `unix:///run/user/${process.getuid!()}/podman/podman.sock`;
if (provider === "microsandbox") env.LD_LIBRARY_PATH = resolve(".tools/e2e/microsandbox");
const d = (args: string[]) => run([devsy, "--home", dhome, ...args], { env, timeout: 600_000 });
// OpenSSH resolves its default config through passwd, independently of HOME.
const sshWrapper = root + "/ssh";
env.ORCA_SYSTEM_SSH_PATH = sshWrapper;
let orca: Orca | undefined, source: Awaited<ReturnType<typeof fixture>> | undefined;
const runtimes: Runtime[] = [];
const workspaces: Awaited<ReturnType<typeof workspace>>[] = [];
let shared: Awaited<ReturnType<typeof services>> | undefined;
let failure: unknown;
const cleanupErrors: string[] = [];
const report = resolve(`.e2e/${Date.now()}-${provider}/result.json`);
const versions: Record<string, string> = {};
const pending = new Set<string>();
const provisionFailures: { workspace: number; category: string }[] = [];
let interrupted = false;
const interrupt = () => {
  interrupted = true;
  for (const provisionId of pending) void orca?.call("ephemeralVm", "cancelProvision", { provisionId }).catch(() => {});
  for (const child of children) stop(child, "SIGTERM");
};
process.once("SIGINT", interrupt);
process.once("SIGTERM", interrupt);
try {
  assert(devsy, "Devsy must be provided by the mise task");
  for (const path of ["home", "run", "config", "state"]) await mkdir(root + "/" + path, { recursive: true, mode: 0o700 });
  await mkdir(env.HOME + "/.ssh", { recursive: true, mode: 0o700 });
  await writeFile(env.HOME + "/.ssh/config", "", { mode: 0o600 });
  await writeFile(sshWrapper, '#!/bin/sh\nexec /usr/bin/ssh -F "$HOME/.ssh/config" "$@"\n', { mode: 0o700 });
  const latest = await latestOrca();
  versions.orca = latest.version;
  console.log(`E2E ${provider} ${process.platform}/${process.arch} Orca ${latest.version}`);
  const version = async (argv: string[]) => {
    const output = await run(argv, { env, timeout: budgets.operation });
    const result = /\d+\.\d+\.\d+/.exec(output)?.[0];
    assert(result, "Runtime must report a semantic version");
    return result;
  };
  versions.devsy = await version([devsy, "--version"]);
  versions[provider] = await version(provider === "docker" ? ["docker", "version", "--format", "{{.Server.Version}}"] : [provider === "apple" ? "container" : provider === "microsandbox" ? "msb" : "podman", "--version"]);
  if (provider === "podman") assert.equal((await run(["podman", "info", "--format", "{{.Host.Security.Rootless}}"], { env, timeout: budgets.operation })).trim(), "true");
  shared = await services(root, env);
  if (provider === "microsandbox") await installMicrosandboxDiagnostics(root, env);
  await writeFile(root + "/bin/ssh", '#!/bin/sh\nexec /usr/bin/ssh -F "$HOME/.ssh/config" "$@"\n', { mode: 0o700 });
  await d(["context", "set", "-o", "TELEMETRY=false", "-o", "SSH_INJECT_DOCKER_CREDENTIALS=false"]);
  const options = provider === "apple" ? ["-o", "CONTAINER_PATH=" + Bun.which("container")!] : provider === "docker" ? ["-o", "DOCKER_PATH=" + Bun.which("docker")!] : provider === "podman" ? ["-o", "PODMAN_PATH=" + Bun.which("podman")!, "-o", `PODMAN_HOST=unix:///run/user/${process.getuid!()}/podman/podman.sock`] : [];
  await d(["provider", "add", provider, ...options]);
  source = await fixture(root, env);
  const definitions = await recipes(source.source, devsy, dhome, provider, resolve("_build/native/release/build/cmd/main/main.exe"), source.build);
  orca = await Orca.launch(latest.executable, root + "/profile", env);
  const hostEnv = await orca.app.evaluate(() => ({ home: process.env.HOME, git: process.env.GIT_CONFIG_GLOBAL, agent: process.env.SSH_AUTH_SOCK, path: process.env.PATH }));
  assert.equal(hostEnv.home, env.HOME);
  assert.equal(hostEnv.git, env.GIT_CONFIG_GLOBAL);
  assert.equal(hostEnv.agent, env.SSH_AUTH_SOCK);
  assert(hostEnv.path?.split(":").includes(root + "/bin"), "Orca must preserve fixture tool PATH");
  const added = await orca.call<{ repo?: { id: string }; error?: string }>("repos", "add", { path: source.source });
  assert(added.repo, "Orca must register the fixture repository");
  const connected = Promise.withResolvers<void>();
  void connected.promise.catch(() => {});
  let readyCount = 0;
  const allConnectionsReady = async () => {
    if (++readyCount === definitions.length) connected.resolve();
    await connected.promise;
  };
  const provisioned = await Promise.allSettled(definitions.map(async (definition, index) => {
    const provisionId = "provision-" + index;
    pending.add(provisionId);
    const result = await measure("provision", budgets.provision, async () => {
      const result = await orca!.call<Provision>("ephemeralVm", "provision", { provisionId, repoId: added.repo!.id, recipeId: definition.id, workspaceName: "e2e-" + index, workspaceId: "e2e-" + index, branch: "task", ref: source!.task }).catch(error => {
        const category = failureCategory(error);
        provisionFailures.push({ workspace: index, category });
        throw new Error(`Orca recipe IPC failed (${definition.id}, ${category})`);
      });
      if (!result.ok) {
        const category = failureCategory(result.error);
        provisionFailures.push({ workspace: index, category });
        throw new Error(`Orca recipe provisioning failed (${definition.id}, ${category})`);
      }
      return result;
    }, index);
    pending.delete(provisionId);
    runtimes.push(result.runtime);
    assert.equal(result.runtime.workspaceId, "e2e-" + index);
    assert.equal(result.runtime.status, "running");
    if (definition.connection === "ssh") assert(result.sshTargetId);
    else assert(result.environment?.id);
    await firstUse(result.runtime, index, env, shared!);
    // Connect as each provision completes, then synchronize the Git workload.
    const active = await workspace(orca!, result.runtime, index, env, shared!, source!, false, allConnectionsReady);
    workspaces.push(active);
    if (active.serverVersion) assert.equal(active.serverVersion, latest.version);
    return { runtime: result.runtime, index };
  }).map(operation => operation.catch(error => { connected.reject(error); throw error; })));
  for (const result of provisioned) if (result.status === "rejected") throw result.reason;
  assert.equal(new Set(runtimes.map(r => r.recipeResult.userData.workspaceId)).size, 4);
  if (interrupted) throw new Error("E2E interrupted");
  const saved = await orca.call<Runtime[]>("ephemeralVm", "listRuntimes");
  for (const runtime of runtimes) assert(saved.some(r => r.id === runtime.id && r.workspaceId === runtime.workspaceId && r.sshTargetId === runtime.sshTargetId && r.runtimeEnvironmentId === runtime.runtimeEnvironmentId));
  assert.equal(await Bun.file(env.CODEX_HOME + "/refresh-count").text(), "refresh\n", "Concurrent creates must refresh shared host auth once");
  for (let i = 0; i < 4; i++) {
    assert((shared.requests.get("w-" + i) ?? 0) > 0);
    const refs = (await run(["git", "-C", root + `/git/w-${i}.git`, "for-each-ref", "--format=%(refname)", "refs/heads"], { env })).trim().split("\n");
    assert.deepEqual(refs, ["refs/heads/task-0", "refs/heads/task-1", "refs/heads/task-2"]);
  }
  for (const current of workspaces) {
    await Promise.all([current.recoverRelay(), ...workspaces.filter(w => w !== current).map(w => w.check())]);
  }
  const crashed = workspaces.find(w => w.runtime.runtimeEnvironmentId)!;
  await measure("worker-recovery", budgets.recovery, async () => {
    await crashed.crashWorker();
    await run([resolve("_build/native/release/build/cmd/main/main.exe"), "reconnect"], { env, timeout: budgets.recovery });
    await Promise.all([crashed.checkClient(), (async () => {
      assert(/^[a-f0-9]{40}\s+refs\/heads\/task-0/.test(await crashed.exec(1, `git ls-remote http://127.0.0.1:18080/w-${crashed.index}.git refs/heads/task-0`)));
    })()]);
  }, crashed.index);
  await Promise.all(workspaces.map(w => w.check()));
  await measure("receipt-reconnect", budgets.recovery, async () => { await run([resolve("_build/native/release/build/cmd/main/main.exe"), "reconnect", "--receipt"], { env, timeout: budgets.recovery, input: JSON.stringify({ schemaVersion: 1, recipeResult: crashed.runtime.recipeResult }) }); await crashed.checkClient(); }, crashed.index);
  await writeFile(env.CODEX_HOME + "/auth.json", auth(access(2)), { mode: 0o600 });
  // Interleave each workspace lifecycle with live operations in all peers.
  for (const current of workspaces) {
    if (current.index === 0) await current.exec(1, 'printf manual-change > "$HOME/.codex/auth.json"');
    await current.close();
    const suspended: Runtime = await orca.call<Runtime>("ephemeralVm", "suspendWorkspace", { workspaceId: current.runtime.workspaceId });
    assert.equal(suspended.status, "suspended");
    await Promise.all(workspaces.filter(w => w !== current).map(w => w.check()));
    const resumed: Runtime = await orca.call<Runtime>("ephemeralVm", "resumeWorkspace", { workspaceId: current.runtime.workspaceId });
    assert.equal(resumed.status, "running");
    await firstUse(resumed, current.index, env, shared);
    // Receipt-based resume must preserve guest modifications to auth.
    const state = resumed.recipeResult.userData;
    const proxy = [...state.command as string[], "--home", state.home as string, "workspace", "ssh", state.workspaceId as string, "--stdio", "--start-services=false", "--user", state.user as string].map(quote).join(" ");
    const output = await run(["ssh", "-o", "ProxyCommand=" + proxy, `${state.user}@${state.workspaceId}.devsy`, 'cat "$HOME/.codex/auth.json"'], { env });
    if (current.index === 0) assert.equal(output, "manual-change");
    else assert.equal(JSON.parse(output).tokens.access_token, JSON.parse(await Bun.file(env.CODEX_HOME + "/auth.json").text()).tokens.access_token);
    // Reopen transport and verify persisted data without recreating the fixture.
    const reopened = await workspace(orca, resumed, current.index, env, shared, source, true);
    workspaces[workspaces.indexOf(current)] = reopened;
  }
  for (const [key, count] of shared.rejected) assert(!key.endsWith(":invalid") || count === 0, "Shared credentials must not cross workspace repositories");
  assert.equal(await Bun.file(env.CODEX_HOME + "/refresh-count").text(), "refresh\n", "Lifecycle operations must reuse the valid shared auth");
  const live = [...workspaces];
  for (const current of workspaces) {
    await current.close();
    const cleaned: Runtime = await orca.call<Runtime>("ephemeralVm", "cleanup", { runtimeId: current.runtime.id });
    assert.equal(cleaned.status, "cleaned");
    live.splice(live.indexOf(current), 1);
    assert.equal(await orca.call("ephemeralVm", "resumeWorkspace", { workspaceId: current.runtime.workspaceId }), null, "Deleted workspace must not resume through stale Orca mapping");
    await measure("stale-receipt-rejected", budgets.operation, () => assert.rejects(() => run([resolve("_build/native/release/build/cmd/main/main.exe"), "reconnect", "--receipt"], { env, timeout: budgets.operation, input: JSON.stringify({ schemaVersion: 1, recipeResult: current.runtime.recipeResult }) })), current.index);
    await Promise.all(live.map(w => w.check()));
  }
  if (interrupted) throw new Error("E2E interrupted");
  console.log("PASS concurrent Orca receipts, shared credentials/agent, persistence and interleaved lifecycle");

} catch (error) {
  failure = error;
} finally {
  const diagnostics = await adapterDiagnostics(env.XDG_STATE_HOME!).catch(() => ({ available: false, readFailed: true, events: [] }));
  for (const provisionId of pending) await orca?.call("ephemeralVm", "cancelProvision", { provisionId }).catch(() => cleanupErrors.push("cancel-provision"));
  if (shared) console.log("Authenticated Git requests:", JSON.stringify({ accepted: Object.fromEntries(shared.requests), rejected: Object.fromEntries(shared.rejected) }));
  for (const active of workspaces) await active.close().catch(() => cleanupErrors.push("ssh-sessions"));
  const cleanup = orca ? await orca.call<Runtime[]>("ephemeralVm", "listRuntimes").catch(() => runtimes) : [];
  for (const runtime of cleanup) {
    try {
      const cleaned = await orca!.call<Runtime>("ephemeralVm", "cleanup", { runtimeId: runtime.id });
      assert.equal(cleaned.status, "cleaned");
    } catch { cleanupErrors.push("orca-runtime"); }
  }
  await orca?.close().catch(() => cleanupErrors.push("orca-client"));
  // This Devsy home was created for this run and contained no user workspaces.
  // Reap creations that failed before Orca could persist their receipts as well.
  try {
    const remaining = source ? JSON.parse(await d(["--result-format", "json", "workspace", "list", "--skip-pro"])) as { id: string }[] : [];
    for (const item of remaining) {
      assert(/^orca-[a-f0-9-]+$/.test(item.id));
      await d(["workspace", "delete", item.id, "--force", "--ignore-not-found"]);
      cleanupErrors.push("unreleased-workspace");
    }
  } catch { cleanupErrors.push("devsy-cleanup"); }
  source?.close();
  shared?.close();
  for (const child of children) stop(child, "SIGKILL");
  await mkdir(resolve(report, ".."), { recursive: true, mode: 0o700 });
  await writeFile(report, JSON.stringify({ schemaVersion: 1, provider, platform: process.platform, arch: process.arch, versions, budgets, timings, firstUseFailures, provisionFailures, adapterDiagnostics: diagnostics, microsandboxFailures: await Bun.file(root + "/msb-failures.jsonl").text().then(text => text.split("\n").filter(Boolean).slice(-16).map(line => JSON.parse(line)), () => []), gitServer: shared && { accepted: Object.fromEntries(shared.requests), rejected: Object.fromEntries(shared.rejected), backendFailures: shared.backendFailures }, status: failure || cleanupErrors.length ? "failed" : "passed", cleanupErrors, workspaces: workspaces.map(w => ({ index: w.index, runtimeId: w.runtime.id, serverVersion: w.serverVersion })) }, null, 2), { mode: 0o600 });
  if (!cleanupErrors.length) await rm(root, { recursive: true, force: true });
  else console.error(`Cleanup diagnostics retained in ${root}`);
  process.removeListener("SIGINT", interrupt);
  process.removeListener("SIGTERM", interrupt);
}
if (failure) throw failure;
assert.deepEqual(cleanupErrors, [], "E2E resources must be released");
