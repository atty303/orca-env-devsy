import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, realpath, writeFile, readFile, symlink } from "node:fs/promises";
import { resolve } from "node:path";
import { run as cleanupRun, processScope, children, stop, terminate, quote, type Environment } from "../../scripts/process.ts";
import { Orca, latestOrca, type Provision, type Runtime } from "./orca.ts";
import { interruptibleRun, cleanupDeadline } from "./control.ts";
import { fixture, recipes } from "./fixture.ts";
import { services, auth, access } from "./services.ts";
import { workspace, firstUse, firstUseFailures, sshConnectionFailures, gitFailures } from "./scenarios.ts";
import { targets, bufferMs, budgets, timings, measure } from "./timing.ts";
import { installMicrosandboxDiagnostics } from "./microsandbox.ts";
import { installPodmanDiagnostics } from "./podman.ts";
import { type GitServerStats } from "./git-server.ts";
import { failureCategory, provisionFailure, adapterDiagnostics } from "./diagnostics.ts";

const index = process.argv.indexOf("--provider");
const provider = index < 0 ? undefined : process.argv[index + 1];
if (!provider || !["docker", "podman", "microsandbox", "apple"].includes(provider)) throw new Error("Usage: mise run test:e2e -- --provider docker|podman|microsandbox|apple");
const root = await realpath(await mkdtemp("/tmp/oe-e2e-"));
const env: Environment = { PATH: process.env.PATH, HOME: root + "/home", XDG_STATE_HOME: root + "/state", XDG_CONFIG_HOME: root + "/config", XDG_DATA_HOME: root + "/data", XDG_CACHE_HOME: root + "/cache", XDG_RUNTIME_DIR: root + "/run", CODEX_HOME: root + "/codex", ORCA_ENV_DEVSY_RECORDING: process.env.ORCA_ENV_DEVSY_RECORDING === "0" ? "0" : "1", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: root + "/home/.gitconfig", GIT_TERMINAL_PROMPT: "0", GIT_AUTHOR_NAME: "E2E", GIT_AUTHOR_EMAIL: "e2e@example.invalid", GIT_COMMITTER_NAME: "E2E", GIT_COMMITTER_EMAIL: "e2e@example.invalid", SHELL: "/bin/sh" };
const devsy = Bun.which("devsy") ?? "";
const dhome = root + "/devsy";
if (provider === "podman") env.DBUS_SESSION_BUS_ADDRESS = process.env.DBUS_SESSION_BUS_ADDRESS ?? `unix:path=/run/user/${process.getuid!()}/bus`;
if (provider === "microsandbox") env.LD_LIBRARY_PATH = resolve(".tools/e2e/microsandbox");
const phase = interruptibleRun();
const { run } = processScope(phase.signal);
const d = (args: string[]) => run([devsy, "--home", dhome, ...args], { env, timeout: budgets.provision });
// OpenSSH resolves its default config through passwd, independently of HOME.
const sshWrapper = root + "/ssh";
env.ORCA_SYSTEM_SSH_PATH = sshWrapper;
let orca: Orca | undefined, source: Awaited<ReturnType<typeof fixture>> | undefined;
const runtimes: Runtime[] = [];
const workspaces: Awaited<ReturnType<typeof workspace>>[] = [];
let shared: Awaited<ReturnType<typeof services>> | undefined;
let failure: unknown;
let podmanStoreOwned = false;
const cleanupErrors: string[] = [];
let gitStats: GitServerStats | undefined;
let gitServerDiagnostics: Awaited<ReturnType<NonNullable<typeof shared>["diagnostics"]>> | undefined;
let cloneAudit: { recipe: string; pinned: boolean; strategies: string[] }[] = [];
const report = resolve(`.e2e/${Date.now()}-${provider}/result.json`);
const versions: Record<string, string> = {};
const pending = new Set<string>();
const provisionFailures: ({ workspace: number } & ReturnType<typeof provisionFailure>)[] = [];

const phases: { phase: string; elapsedMs: number; ok: boolean }[] = [];
let activePhase: { name: string; started: number } | undefined;
function finishPhase(ok = true) {
  if (!activePhase) return;
  const entry = { phase: activePhase.name, elapsedMs: Math.round(performance.now() - activePhase.started), ok };
  phases.push(entry);
  console.log("E2E phase:", JSON.stringify(entry));
  activePhase = undefined;
}
function beginPhase(name: string) {
  finishPhase();
  activePhase = { name, started: performance.now() };
}

try {
  beginPhase("setup");
  assert(devsy, "Devsy must be provided by the mise task");
  for (const path of ["home", "run", "config", "state"]) await mkdir(root + "/" + path, { recursive: true, mode: 0o700 });
  await mkdir(env.HOME + "/.ssh", { recursive: true, mode: 0o700 });
  await writeFile(env.HOME + "/.ssh/config", "", { mode: 0o600 });
  await writeFile(sshWrapper, '#!/bin/sh\nexec /usr/bin/ssh -F "$HOME/.ssh/config" "$@"\n', { mode: 0o700 });
  const release = await latestOrca(phase.signal);
  versions.orca = release.version;
  console.log(`E2E ${provider} ${process.platform}/${process.arch} Orca ${release.version}`);
  const version = async (argv: string[], timeout = budgets.operation) => {
    const output = await run(argv, { env, timeout });
    const result = /\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?/.exec(output)?.[0];
    assert(result, "Runtime must report a semantic version");
    return result;
  };
  versions.devsy = await version([devsy, "--version"]);
  assert(/-beta\./.test(versions.devsy), "E2E must use the pinned official upstream beta");
  versions[provider] = await version(provider === "docker" ? ["docker", "version", "--format", "{{.Server.Version}}"] : [provider === "apple" ? "container" : provider === "microsandbox" ? "msb" : "podman", "--version"]);
  if (provider === "podman") versions.crun = await version(["podman", "info", "--format", "{{.Host.OCIRuntime.Version}}"], budgets.lifecycle);
  if (provider === "podman") {
    assert.equal((await run(["podman", "info", "--format", "{{.Host.Security.Rootless}}"], { env, timeout: budgets.operation })).trim(), "true");
    assert.equal((await run(["podman", "info", "--format", "{{.Host.ServiceIsRemote}}"], { env, timeout: budgets.operation })).trim(), "false", "Podman must use its daemonless CLI");
    const stores = (await run(["podman", "info", "--format", "{{.Store.GraphRoot}}\n{{.Store.RunRoot}}"], { env, timeout: budgets.operation })).trim().split("\n");
    assert.equal(stores.length, 2);
    for (const store of stores) assert((await realpath(store)).startsWith(root + "/"), "Podman storage must belong to this run");
    podmanStoreOwned = true;
  }
  await mkdir(root + "/bin", { recursive: true });
  if (process.platform === "linux") {
    const tar = Bun.which("bsdtar");
    assert(tar, "Linux E2E requires bsdtar (libarchive-tools)");
    await symlink(tar, root + "/bin/tar");
    versions.tar = await version([tar, "--version"]);
  }
  if (provider === "microsandbox") await installMicrosandboxDiagnostics(root, env);
  const podman = provider === "podman" ? await installPodmanDiagnostics(root) : undefined;
  await writeFile(root + "/bin/ssh", '#!/bin/sh\nexec /usr/bin/ssh -F "$HOME/.ssh/config" "$@"\n', { mode: 0o700 });
  await d(["context", "set", "-o", "TELEMETRY=false", "-o", "SSH_INJECT_DOCKER_CREDENTIALS=false"]);
  // The API service's libsubid path races on concurrent keep-id creates
  // (containers/podman#29848). Native CLI processes keep that state separate.
  const options = provider === "apple" ? ["-o", "CONTAINER_PATH=" + Bun.which("container")!] : provider === "docker" ? ["-o", "DOCKER_PATH=" + Bun.which("docker")!] : provider === "podman" ? ["-o", "PODMAN_PATH=" + podman!] : [];
  await d(["provider", "add", provider, ...options]);
  source = await fixture(root, env, release.version, phase.signal);
  shared = await services(root, env, { devsy, home: dhome, provider, source: source.bare }, phase.signal);
  await source.connect(shared.localSourceUrl);
  env.GIT_CONFIG_COUNT = "1";
  env.GIT_CONFIG_KEY_0 = `url.${shared.localSourceUrl}.insteadOf`;
  env.GIT_CONFIG_VALUE_0 = shared.sourceUrl;
  const adapter = resolve("_build/native/release/build/cmd/main/main.exe");
  const definitions = await recipes(source.source, devsy, dhome, provider, adapter);
  orca = await Orca.launch(release.executable, root + "/profile", env, phase.signal);
  const added = await orca.call<{ repo?: { id: string }; error?: string }>("repos", "add", { path: source.source });
  assert(added.repo, "Orca must register the fixture repository");
  await source.setOrigin(shared.sourceUrl);
  const connected = Promise.withResolvers<void>();
  void connected.promise.catch(() => {});
  let readyCount = 0;
  let connectionStart = Promise.resolve();
  const acquireConnectionStart = async () => {
    const previous = connectionStart;
    const next = Promise.withResolvers<void>();
    connectionStart = next.promise;
    await previous;
    return () => next.resolve();
  };
  const allConnectionsReady = async () => {
    if (++readyCount === definitions.length) connected.resolve();
    await connected.promise;
  };
  beginPhase("provision-and-first-use");
  const provisioned = await Promise.allSettled(definitions.map(async (definition, index) => {
    const provisionId = "provision-" + index;
    pending.add(provisionId);
    const result = await measure("provision", budgets.provision, async () => {
      const result = await orca!.call<Provision>("ephemeralVm", "provision", { provisionId, repoId: added.repo!.id, recipeId: definition.id, workspaceName: "e2e-" + index, workspaceId: "e2e-" + index, ...(definition.mode === "provisioned-root" ? { branch: "task", ref: "origin/task" } : {}) }).catch(error => {
        const category = failureCategory(error);
        provisionFailures.push({ workspace: index, ...provisionFailure(error) });
        throw new Error(`Orca recipe IPC failed (${definition.id}, ${category})`);
      });
      if (!result.ok) {
        const category = failureCategory(result.error);
        provisionFailures.push({ workspace: index, ...provisionFailure(result.error, result.stderr, result.stdout) });
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
    assert(result.runtime.runtimeEnvironmentId, "Orca must serve every provisioned host through a runtime environment");
    await firstUse(result.runtime, index, env, shared!, phase.signal);
    return { runtime: result.runtime, index };
  }));
  for (const result of provisioned) if (result.status === "rejected") {
    gitServerDiagnostics = await shared!.diagnostics();
    throw result.reason;
  }
  beginPhase("initial-workloads");
  const connectedWorkspaces = await Promise.allSettled(provisioned.map(async result => {
    assert.equal(result.status, "fulfilled");
    const { runtime, index } = (result as PromiseFulfilledResult<{ runtime: Runtime; index: number }>).value;
    const active = await workspace(orca!, runtime, index, env, shared!, { ...source!, build: index === 3 ? source!.customBuild : source!.build }, phase.signal, false, allConnectionsReady, acquireConnectionStart);
    workspaces.push(active);
    assert.equal(active.agentVersion, versions.devsy, "Remote agent must match the official host beta");
    if (active.serverVersion) assert.equal(active.serverVersion, release.version);
  }).map(operation => operation.catch(error => { connected.reject(error); throw error; })));
  for (const result of connectedWorkspaces) if (result.status === "rejected") throw result.reason;
  cloneAudit = (await readFile(dhome + "/clone-audit.jsonl", "utf8")).trim().split("\n").map(line => JSON.parse(line) as { recipe: string; pinned: boolean; strategies: string[] });
  for (const [index, definition] of definitions.entries()) {
    const attempts = cloneAudit.filter(entry => entry.recipe === definition.id);
    assert.equal(attempts.length, 1, "Creation must not retry into a full clone");
    assert.equal(attempts[0].pinned, false, "Devsy must resolve branch builds without an adapter-pinned SHA");
    assert.deepEqual(attempts[0].strategies, [index === 3 ? "" : "shallow"]);
  }
  assert.equal(new Set(runtimes.map(r => r.recipeResult.userData.workspaceId)).size, 4);
  const routeIds = runtimes.map(runtime => runtime.recipeResult.connection.type === "ssh" ? runtime.sshTargetId : runtime.runtimeEnvironmentId);
  assert(routeIds.every(id => typeof id === "string" && id.length > 0));
  assert.equal(new Set(routeIds).size, 4);
  if (phase.signal.aborted) throw new Error("E2E interrupted");
  const saved = await orca.call<Runtime[]>("ephemeralVm", "listRuntimes");
  for (const runtime of runtimes) assert(saved.some(r => r.id === runtime.id && r.workspaceId === runtime.workspaceId && r.sshTargetId === runtime.sshTargetId && r.runtimeEnvironmentId === runtime.runtimeEnvironmentId));
  assert.equal(await Bun.file(env.CODEX_HOME + "/refresh-count").text(), "refresh\n", "Concurrent creates must refresh shared host auth once");
  gitStats = await shared.stats();
  assert.equal(gitStats.backendFailures, 0);
  for (let i = 0; i < 4; i++) {
    assert((gitStats.accepted["w-" + i] ?? 0) > 0);
    assert.deepEqual(gitStats.refs["w-" + i], ["refs/heads/task-0", "refs/heads/task-1", "refs/heads/task-2"]);
  }
  beginPhase("worker-receipt-server-recovery");
  const crashed = workspaces.find(w => w.runtime.recipeResult.connection.type === "orca-server")!;
  await measure("worker-recovery", budgets.recovery, async () => {
    await crashed.crashSupervisor();
    await run([resolve("_build/native/release/build/cmd/main/main.exe"), "recover"], { env, timeout: budgets.recovery });
    await Promise.all([crashed.checkClient(), (async () => {
      assert(/^[a-f0-9]{40}\s+refs\/heads\/task-0/.test(await crashed.exec(1, `git ls-remote http://127.0.0.1:18080/w-${crashed.index}.git refs/heads/task-0`)));
    })()]);
  }, crashed.index);
  await Promise.all(workspaces.map(w => w.check()));
  await measure("receipt-recover", budgets.recovery, async () => { await run([resolve("_build/native/release/build/cmd/main/main.exe"), "recipe", "recover"], { env, timeout: budgets.recovery, input: JSON.stringify({ schemaVersion: 1, recipeResult: crashed.runtime.recipeResult }) }); await crashed.checkClient(); }, crashed.index);
  await measure("server-update", budgets.provision, async () => {
    await crashed.stopServer();
    const state = crashed.runtime.recipeResult.userData;
    const output = JSON.parse(await run([adapter, "update", "--provider", provider!, "--workspace", state.workspaceId as string], { env: { ...env, ORCA_USER_DATA_PATH: root + "/profile" }, timeout: budgets.provision }));
    assert.equal(output.failed, 0);
    assert.equal(output.workspaces[0]?.outcome, "success");
    assert.equal(output.targetVersion, release.version);
    assert.equal(output.workspaces[0]?.reason, undefined);
  }, crashed.index);
  await measure("server-recovery", budgets.lifecycle, async () => {
    await crashed.stopServer();
    await crashed.crashSupervisor();
    await run([resolve("_build/native/release/build/cmd/main/main.exe"), "recover"], { env, timeout: budgets.lifecycle });
    await crashed.checkClient();
  }, crashed.index);
  beginPhase("suspend-resume");
  await writeFile(env.CODEX_HOME + "/auth.json", auth(access(2)), { mode: 0o600 });
  // Interleave each workspace lifecycle with live operations in all peers.
  for (const current of workspaces) {
    if (current.index === 0) await current.exec(1, 'printf manual-change > "$HOME/.codex/auth.json"');
    await current.close();
    const outcomes: { failure?: string; vmSuspendFailure?: string }[] = await orca.call<{ failure?: string; vmSuspendFailure?: string }[]>("worktrees", "sleep", { targets: [{ worktreeId: current.runtime.workspaceId, terminalHost: { kind: "environment", environmentId: current.runtime.runtimeEnvironmentId }, chatHosts: [] }], markChatsAsleep: false });
    assert.equal(outcomes.length, 1);
    assert.equal(outcomes[0]!.failure, undefined);
    assert.equal(outcomes[0]!.vmSuspendFailure, undefined);
    assert.equal((await orca.call<Runtime[]>("ephemeralVm", "listRuntimes")).find(runtime => runtime.id === current.runtime.id)?.status, "suspended");
    await Promise.all(workspaces.filter(w => w !== current).map(w => w.check()));
    const resumed: Runtime = await measure("resume-workspace", budgets.lifecycle, () => orca!.call<Runtime>("ephemeralVm", "resumeWorkspace", { workspaceId: current.runtime.workspaceId }), current.index);
    assert.equal(resumed.status, "running");
    await firstUse(resumed, current.index, env, shared, phase.signal);
    // Receipt-based resume must preserve guest modifications to auth.
    const state = resumed.recipeResult.userData;
    const proxy = [...state.command as string[], "--home", state.home as string, "workspace", "ssh", state.workspaceId as string, "--stdio", "--start-services=false", "--user", state.user as string].map(quote).join(" ");
    const output = await measure("codex-auth-read", budgets.operation, () => run(["ssh", "-o", "ProxyCommand=" + proxy, `${state.user}@${state.workspaceId}.devsy`, 'cat "$HOME/.codex/auth.json"'], { env, timeout: budgets.operation }), current.index);
    if (current.index === 0) assert.equal(output, "manual-change");
    else assert.equal(JSON.parse(output).tokens.access_token, JSON.parse(await Bun.file(env.CODEX_HOME + "/auth.json").text()).tokens.access_token);
    // Reopen transport and verify persisted data without recreating the fixture.
    const reopened = await workspace(orca, resumed, current.index, env, shared, { ...source, build: current.index === 3 ? source.customBuild : source.build }, phase.signal, true);
    workspaces[workspaces.indexOf(current)] = reopened;
  }
  for (const [key, count] of Object.entries((await shared.stats()).rejected)) assert(!key.endsWith(":invalid") || count === 0, "Shared credentials must not cross workspace repositories");
  assert.equal(await Bun.file(env.CODEX_HOME + "/refresh-count").text(), "refresh\n", "Lifecycle operations must reuse the valid shared auth");
  beginPhase("recreate-persistence");
  const persistent = workspaces.find(w => w.runtime.recipeResult.connection.type === "orca-server")!;
  const state = persistent.runtime.recipeResult.userData;
  const volume = state.orcaVolume;
  assert.equal(typeof volume, "string");
  assert.equal((state.workspaceId as string).slice(-8), (state.orcaInstanceId as string).slice(-8));
  const worktreePath = `/worktrees/${persistent.path.split("/").at(-1)}/feature-e2e`;
  await persistent.exec(0, `set -eu; test -f ${quote(worktreePath + "/worktree-usable.txt")}; test -f /worktrees/.orca/orca-profile-index.json; printf preserved > /worktrees/.orca/e2e-marker; printf volatile > "$HOME/e2e-volatile"`);
  await persistent.close();
  const receipt = JSON.stringify({ schemaVersion: 1, recipeResult: persistent.runtime.recipeResult });
  await run([adapter, "recipe", "suspend"], { env, timeout: budgets.lifecycle, input: receipt });
  await measure("recreate-persistent-server", budgets.provision, () => d(["workspace", "up", state.workspaceId as string, "--recreate", "--ide-launch", "skip", "--mount", `type=volume,source=${volume},target=/worktrees`]), persistent.index);
  await run([adapter, "recipe", "recover"], { env, timeout: budgets.lifecycle, input: receipt });
  const checkPersistence = async () => {
    await d(["workspace", "ssh", state.workspaceId as string, "--start-services=false", "--agent-forwarding=false", "--user", state.user as string, "--command", `set -eu; test ! -e "$HOME/e2e-volatile"; test "$(cat /worktrees/.orca/e2e-marker)" = preserved; test "$(cat ${quote(worktreePath + "/worktree-usable.txt")})" = usable; git -C ${quote(worktreePath)} rev-parse --is-inside-work-tree`]);
    await persistent.checkClient();
    const response = await orca!.call<{ ok: boolean; result: { worktrees: { id: string; path: string }[] } }>("runtimeEnvironments", "call", { selector: persistent.runtime.runtimeEnvironmentId, method: "worktree.list", params: { repo: persistent.path }, timeoutMs: budgets.operation });
    assert(response.ok);
    assert(response.result.worktrees.some(w => w.id === persistent.runtime.workspaceId && w.path === worktreePath), "Remote profile must retain the existing worktree registration");
  };
  await checkPersistence();
  workspaces[workspaces.indexOf(persistent)] = { ...persistent, check: checkPersistence, close: async () => {} };
  console.log("PASS devcontainer recreation: checkout, worktree, profile and existing client registration");
  beginPhase("destroy");
  const live = [...workspaces];
  for (const current of workspaces) {
    await current.close();
    const cleaned: Runtime = await orca.call<Runtime>("ephemeralVm", "cleanup", { runtimeId: current.runtime.id });
    assert.equal(cleaned.status, "cleaned");
    if ((provider === "apple" || provider === "docker" || provider === "podman") && typeof current.runtime.recipeResult.userData.orcaVolume === "string") {
      const listed = await run([provider === "apple" ? "container" : provider, "volume", "ls", "--format", "json"], { env, timeout: budgets.operation });
      assert(!volumeNames(listed).includes(current.runtime.recipeResult.userData.orcaVolume), "Adapter destroy must remove its dedicated volume");
    }
    live.splice(live.indexOf(current), 1);
    assert.equal(await orca.call("ephemeralVm", "resumeWorkspace", { workspaceId: current.runtime.workspaceId }), null, "Deleted workspace must not resume through stale Orca mapping");
    await measure("stale-receipt-rejected", budgets.operation, () => assert.rejects(() => run([resolve("_build/native/release/build/cmd/main/main.exe"), "recipe", "recover"], { env, timeout: budgets.operation, input: JSON.stringify({ schemaVersion: 1, recipeResult: current.runtime.recipeResult }) })), current.index);
    await Promise.all(live.map(w => w.check()));
  }
  if (phase.signal.aborted) throw new Error("E2E interrupted");
  console.log("PASS concurrent Orca receipts, shared credentials/agent, persistence and interleaved lifecycle");

} catch (error) {
  failure = error;
} finally {
  finishPhase(failure === undefined);
  beginPhase("cleanup");
  phase.beginCleanup();
  const cleanup = cleanupDeadline(cleanupErrors);
  await Orca.settleLaunches(cleanup.signal).catch(() => cleanupErrors.push("orca-launch"));
  const cleanDevsy = (args: string[], timeout: number) => cleanupRun([devsy, "--home", dhome, ...args], { env, timeout, signal: cleanup.signal });
  const orcaObservations = await orca?.observations.snapshot();
  const diagnostics = await adapterDiagnostics(env.XDG_STATE_HOME!).catch(() => ({ available: false, readFailed: true, events: [] }));
  for (const provisionId of pending) await orca?.call("ephemeralVm", "cancelProvision", { provisionId }, cleanup.signal).catch(() => cleanupErrors.push("cancel-provision"));
  if (shared) {
    gitServerDiagnostics ??= await shared.diagnostics().catch(() => undefined);
    gitStats = await shared.stats(cleanup.signal).catch(() => { cleanupErrors.push("git-server-metrics"); return undefined; });
    console.log("Authenticated Git requests:", JSON.stringify(gitStats && { accepted: gitStats.accepted, rejected: gitStats.rejected }));
  }
  await Promise.all(workspaces.map(active => active.close(cleanup.signal).catch(() => cleanupErrors.push("ssh-sessions"))));
  const remainingRuntimes = orca ? await orca.call<Runtime[]>("ephemeralVm", "listRuntimes", undefined, cleanup.signal).catch(() => runtimes) : [];
  await Promise.all(remainingRuntimes.filter(runtime => runtime.status !== "cleaned").map(async runtime => {
    try {
      const cleaned = await orca!.call<Runtime>("ephemeralVm", "cleanup", { runtimeId: runtime.id }, cleanup.signal);
      assert.equal(cleaned.status, "cleaned");
    } catch { cleanupErrors.push("orca-runtime"); }
  }));
  await orca?.close().catch(() => cleanupErrors.push("orca-client"));
  await shared?.close(cleanup.signal).catch(() => cleanupErrors.push("git-server-cleanup"));
  // This Devsy home was created for this run and contained no user workspaces.
  // Reap creations that failed before Orca could persist their receipts as well.
  try {
    const remaining = source ? JSON.parse(await cleanDevsy(["--result-format", "json", "workspace", "list", "--skip-pro"], budgets.operation)) as { id: string }[] : [];
    for (const item of remaining) assert(/^[a-z0-9-]+-[a-z]+-[a-z0-9]{2}$/.test(item.id));
    await Promise.all(remaining.map(async item => {
      await cleanDevsy(["workspace", "delete", item.id, "--force", "--ignore-not-found"], budgets.lifecycle).catch(() => cleanupErrors.push("devsy-cleanup"));
      cleanupErrors.push("unreleased-workspace");
    }));
  } catch { cleanupErrors.push("devsy-cleanup"); }
  if (provider === "apple" || provider === "docker" || provider === "podman") {
    const volumes = new Set(runtimes.map(runtime => runtime.recipeResult.userData.orcaVolume).filter((value): value is string => typeof value === "string"));
    const rawEvents = await Bun.file(env.XDG_STATE_HOME + "/orca-env-devsy/events.jsonl").text().catch(() => "");
    for (const line of rawEvents.split("\n").filter(Boolean)) {
      try { const event = JSON.parse(line); if (typeof event.source?.volume === "string") volumes.add(event.source.volume); } catch {}
    }
    for (const volume of volumes) {
      if (!/^orca-env-devsy-oe-create-[a-zA-Z0-9.-]+$/.test(volume)) { cleanupErrors.push("orca-volume-ownership"); continue; }
      try {
        const listed = await cleanupRun([provider === "apple" ? "container" : provider, "volume", "ls", "--format", "json"], { env, timeout: budgets.operation, signal: cleanup.signal });
        if (volumeNames(listed).includes(volume)) {
          cleanupErrors.push("unreleased-orca-volume");
          await cleanupRun([provider === "apple" ? "container" : provider, "volume", "rm", volume], { env, timeout: budgets.operation, signal: cleanup.signal });
        }
      } catch { cleanupErrors.push("orca-volume"); }
    }
  }
  if (podmanStoreOwned) {
    // Both stores were verified inside this disposable run before provisioning.
    // Reset also reaps the daemonless runtime's pause process and storage mounts.
    await cleanupRun(["podman", "system", "reset", "--force"], { env, timeout: budgets.lifecycle, signal: cleanup.signal }).catch(() => cleanupErrors.push("podman-runtime"));
  }
  cleanup.close();
  await Promise.all([...children].map(child => terminate(child).catch(() => cleanupErrors.push("child-process"))));
  if (phase.interrupted && failure === undefined) failure = new Error("E2E interrupted");
  await mkdir(resolve(report, ".."), { recursive: true, mode: 0o700 });
  finishPhase(cleanupErrors.length === 0);
  await writeFile(report, JSON.stringify({ schemaVersion: 1, provider, platform: process.platform, arch: process.arch, versions, targets, bufferMs, budgets, phases, timings, cloneAudit, gitFailures, firstUseFailures, sshConnectionFailures, provisionFailures, adapterDiagnostics: diagnostics, orcaDiagnostics: orcaObservations, podmanFailures: await Bun.file(root + "/podman-failures.jsonl").text().then(text => text.split("\n").filter(Boolean).slice(-32).map(line => JSON.parse(line)), () => []), microsandboxFailures: await Bun.file(root + "/msb-failures.jsonl").text().then(text => text.split("\n").filter(Boolean).slice(-16).map(line => JSON.parse(line)), () => []), gitServer: gitStats, gitServerDiagnostics, status: failure || cleanupErrors.length ? "failed" : "passed", ...(failure === undefined ? {} : { failure: { category: failureCategory(failure) } }), cleanupErrors, workspaces: workspaces.map(w => ({ index: w.index, runtimeId: w.runtime.id, serverVersion: w.serverVersion })) }, null, 2), { mode: 0o600 });
  if (!cleanupErrors.length) await rm(root, { recursive: true, force: true });
  else console.error(`Cleanup diagnostics retained in ${root}`);
  phase.close();
}

function volumeNames(output: string): string[] {
  const items = output.trim().startsWith("[") ? JSON.parse(output) : output.split("\n").filter(Boolean).map(line => JSON.parse(line));
  return items.map((item: { configuration?: { name: string }; Name?: string }) => {
    const name = provider === "apple" ? item.configuration?.name : item.Name;
    assert.equal(typeof name, "string");
    return name!;
  });
}
if (failure) throw failure;
assert(!phase.interrupted, "E2E interrupted");
assert.deepEqual(cleanupErrors, [], "E2E resources must be released");
