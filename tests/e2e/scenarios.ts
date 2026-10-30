import assert from "node:assert/strict";
import { mkdtemp, rm, readFile, lstat } from "node:fs/promises";
import { run as cleanupRun, start, processScope, withAbort, terminate, quote, type Environment, processFailureCategory } from "../../scripts/process.ts";
import { resolve } from "node:path";
import { type Orca, type Runtime } from "./orca.ts";
import { type services } from "./services.ts";
import { budgets, measure, timings, bufferMs } from "./timing.ts";
import { DiagnosticError, diagnosticRun, sshStartupPhases } from "./diagnostics.ts";

type Services = Awaited<ReturnType<typeof services>>;
export const sshConnectionFailures: { workspace: number; restarting: boolean; sessions: { exitCode: number | null; signal: NodeJS.Signals | null; category: string; socketReady: boolean; truncated: boolean; phases: string[] }[] }[] = [];
export const gitFailures: { workspace: number; session: number; operation: string; round?: number | null; exitCode?: number; timedOut?: boolean; category?: string; effective?: string; global?: string; unavailable?: boolean }[] = [];
export const firstUseFailures: { workspace: number; run?: number; helper?: boolean; endpoint?: boolean; unavailable?: boolean }[] = [];
export async function firstUse(runtime: Runtime, index: number, env: Environment, service: Services, signal?: AbortSignal) {
  const { run } = processScope(signal);
  const state = runtime.recipeResult.userData;
  const saved = JSON.parse(await readFile(state.tunnelDirectory + "/state.json", "utf8"));
  assert.equal(saved.workspaceUid, state.workspaceUid);
  const base = ["ssh", "-F", env.HOME + "/.ssh/config", "-o", "ProxyCommand=false", "-S", saved.socketDirectory + "/socket"];
  const target = `${state.user}@${state.workspaceId}.devsy`;
  const forwarding = `18080:127.0.0.1:${service.port}`;
  const accepted = (await service.stats()).accepted["w-" + index] ?? 0;
  await run([...base, "-O", "forward", "-R", forwarding, target], { env, timeout: budgets.firstUse });
  try {
    try {
      await measure("first-git-use", budgets.firstUse, () => run([...base, target, `git -c credential.useHttpPath=true ls-remote http://127.0.0.1:18080/w-${index}.git`], { env, timeout: budgets.firstUse }), index);
    } catch (error) {
      // Observe the failed first attempt; never repair or retry it into a pass.
      const script = `helper=false; endpoint=false; git config --global --get credential.helper | grep -Fq 'internal agent git-credentials' && helper=true; test "$(curl --noproxy '*' -fsS --max-time 1 http://localhost:12049/owner)" = ${quote(state.user as string)} && endpoint=true; printf '{"helper":%s,"endpoint":%s}' "$helper" "$endpoint"`;
      const observed = await run([...base, target, script], { env, timeout: 1500 }).then(output => JSON.parse(output) as { helper: boolean; endpoint: boolean }).catch(() => ({ unavailable: true }));
      const runOrdinal = await readFile(state.tunnelDirectory + "/status.json", "utf8").then(text => diagnosticRun(JSON.parse(text).runId)).catch(() => undefined);
      firstUseFailures.push({ workspace: index, ...(runOrdinal === undefined ? {} : { run: runOrdinal }), ...observed });
      throw error;
    }
    assert(((await service.stats()).accepted["w-" + index] ?? 0) > accepted, "First use must authenticate to the Git server");
  } finally { await run([...base, "-O", "cancel", "-R", forwarding, target], { env, timeout: budgets.firstUse }); }
  console.log(`PASS workspace ${index}: first Git use within ${budgets.firstUse} ms`);
}

export async function workspace(orca: Orca, runtime: Runtime, index: number, env: Environment, service: Services, expected: { build: string; task: string }, signal?: AbortSignal, restarting = false, connectionsReady: () => Promise<void> = async () => {}, acquireConnectionStart: () => Promise<() => void> = async () => () => {}) {
  const { run, start, until } = processScope(signal);
  const state = runtime.recipeResult.userData;
  assert.equal(typeof state.workspaceId, "string");
  const id = state.workspaceId as string, user = state.user as string, path = runtime.recipeResult.connection.projectRoot;
  const socketRoot = await mkdtemp("/tmp/oe-ssh-");
  const command = state.command as string[];
  const proxy = [...command, "--home", state.home as string, "--context", state.context as string, "workspace", "ssh", id, "--stdio", "--start-services=false", "--user", user].filter(v => v !== undefined).map(quote).join(" ");
  const base = ["ssh", "-F", env.HOME + "/.ssh/config", "-o", "BatchMode=yes", "-o", "ProxyCommand=" + proxy];
  const target = user + "@" + id + ".devsy";
  const sessions: ReturnType<typeof start>[] = [];
  const sessionErrors: string[] = [];
  const socketReady: boolean[] = [], truncated: boolean[] = [];
  const exec = (session: number, script: string) => measure("ssh-operation", budgets.operation, () => run(["ssh", "-F", env.HOME + "/.ssh/config", "-o", "ProxyCommand=false", "-S", socketRoot + "/" + session, target, script], { env, timeout: budgets.operation }), index);
  const poll = (script: string) => until(async () => { try { await exec(0, script); return true; } catch { return false; } }, budgets.firstUse);
  async function close(cleanupSignal = signal) {
    await Promise.all(sessions.map((_, i) => cleanupRun([...base, "-S", socketRoot + "/" + i, "-O", "exit", target], { env, timeout: budgets.operation, signal: cleanupSignal }).catch(() => {})));
    await Promise.all(sessions.map(process => terminate(process)));
    await rm(socketRoot, { recursive: true, force: true });
  }
  try {
    const release = await acquireConnectionStart();
    try {
    for (let i = 0; i < 3; i++) {
      const child = start([...base, "-v", "-M", "-S", socketRoot + "/" + i, "-o", "ExitOnForwardFailure=yes", ...(i === 0 ? ["-R", `18080:127.0.0.1:${service.port}`] : []), "-N", target], { env });
      child.stdout?.resume();
      child.stderr?.on("data", data => {
        const text = (sessionErrors[i] ?? "") + data.toString();
        truncated[i] ||= text.length > 8192;
        sessionErrors[i] = text.slice(-8192);
      });
      sessions.push(child);
    }
    await measure("parallel-ssh-ready", budgets.sshConnections, () => Promise.all([0, 1, 2].map(async session => {
      await until(() => lstat(socketRoot + "/" + session).then(stat => stat.isSocket(), () => false), budgets.sshConnections);
      socketReady[session] = true;
      await run([...base, "-S", socketRoot + "/" + session, "-O", "check", target], { env, timeout: budgets.operation });
    })), index).catch(error => {
      const observation = { workspace: index, restarting, sessions: sessions.map((child, i) => ({ exitCode: child.exitCode, signal: child.signalCode, category: processFailureCategory(sessionErrors[i] ?? ""), socketReady: socketReady[i] === true, truncated: truncated[i] === true, phases: sshStartupPhases(sessionErrors[i] ?? "") })) };
      if (sshConnectionFailures.length < 8) sshConnectionFailures.push(observation);
      console.error("SSH connection failure:", JSON.stringify(observation));
      throw error;
    });
    } finally { release(); }
    await withAbort(signal, connectionsReady);
    assert.equal((await exec(0, "git -C " + quote(path) + " rev-parse HEAD")).trim(), index === 1 ? expected.task : expected.build);
    assert.equal((await exec(0, "cat " + quote(path + "/identity.txt"))).trim(), index === 1 ? "fixture-task" : index === 3 ? "fixture-devcontainer" : "fixture-build");
    if (["virtiofs", "fuseblk"].includes((await exec(0, "stat -f -c %T " + quote(path))).trim())) {
      for (const session of [0, 1, 2]) assert.equal((await exec(session, "git config --get core.createObject")).trim(), "rename", `Session ${session} must use safe Git object creation`);
    }
    if (!restarting) {
      const buildIdentity = index === 1 ? "fixture-task" : index === 3 ? "fixture-devcontainer" : "fixture-build";
      assert.equal((await exec(0, "cat /tmp/orca-e2e-image-source")).trim(), buildIdentity);
      assert.equal((await exec(0, "cat /tmp/orca-e2e-lifecycle-source")).trim(), buildIdentity);
      assert.equal((await exec(0, "git -C " + quote(path) + " rev-parse --is-shallow-repository")).trim(), index === 3 ? "false" : "true");
      if (index !== 3) {
        const shallowBranches = await exec(0, `for branch in main task devcontainer; do count=$(git -C ${quote(path)} rev-list --count "refs/remotes/origin/$branch" 2>/dev/null) || count=error; printf '%s=%s\n' "$branch" "$count"; done`);
        assert.deepEqual(shallowBranches.trim().split("\n"), ["main=1", "task=1", "devcontainer=1"]);
      }
      assert(runtime.runtimeEnvironmentId);
      const call = async <T>(method: string, params: unknown) => {
        const response = await orca.call<{ ok: true; result: T } | { ok: false; error: unknown }>("runtimeEnvironments", "call", { selector: runtime.runtimeEnvironmentId, method, params, timeoutMs: budgets.operation });
        if (!response.ok) throw new DiagnosticError(response.error);
        return response.result;
      };
      await call("repo.add", { path });
      const created = await call<{ worktree: { id: string; path: string } }>(index === 1 ? "worktree.adoptProvisionedRoot" : "worktree.create", {
        repo: path, name: "feature-e2e", runHooks: false, activate: false, noParent: true, setupDecision: "skip",
        ...(index === 1 ? { branchNameOverride: "task", expectedPath: path, expectedRefHead: expected.task } : { baseBranch: "origin/main" }),
      });
      assert(created.worktree?.path, "Orca must create or adopt the actual workspace");
      assert(created.worktree.id);
      await orca.call("ephemeralVm", "attachWorkspace", { runtimeId: runtime.id, workspaceId: created.worktree.id });
      runtime.workspaceId = created.worktree.id;
      const worktreePath = created.worktree.path;
      const taskHead = index === 1 ? expected.task : await exec(0, "git -C " + quote(path) + " rev-parse refs/remotes/origin/main");
      assert.equal((await exec(0, "git -C " + quote(worktreePath) + " rev-parse HEAD")).trim(), taskHead.trim());
      assert.equal((await exec(0, "cat " + quote(worktreePath + "/identity.txt"))).trim(), index === 1 ? "fixture-task" : "fixture-build");
      await exec(0, "printf usable > " + quote(worktreePath + "/worktree-usable.txt"));
    }
    if (!restarting) {
    await exec(0, `set -eu; cd ${quote(path)}; test -w .; test -w "$HOME"; git config --global credential.useHttpPath true; printf %s ${quote("workspace-" + index)} > isolation.txt; cp isolation.txt isolation-${index}.txt; mkdir -p "$HOME/e2e"; printf '%s\\n' ${quote(service.publicKey)} > "$HOME/e2e/authorized_keys"; printf '%s\\n' ${quote("e2e " + service.publicKey)} > "$HOME/e2e/allowed_signers"; ssh-keygen -q -t ed25519 -N '' -f "$HOME/e2e/hostkey"; printf '%s\\n' 'Port 2222' 'ListenAddress 127.0.0.1' 'PasswordAuthentication no' 'UsePAM yes' 'StrictModes no' "HostKey $HOME/e2e/hostkey" "AuthorizedKeysFile $HOME/e2e/authorized_keys" "PidFile $HOME/e2e/sshd.pid" > "$HOME/e2e/sshd_config"; sudo mkdir -p /run/sshd; sudo /usr/sbin/sshd -f "$HOME/e2e/sshd_config"`);
    const operations = await Promise.allSettled([0, 1, 2].map(async session => {
      const output = await measure("git-session-batch", 605_000, () => run(["ssh", "-F", env.HOME + "/.ssh/config", "-o", "ProxyCommand=false", "-S", socketRoot + "/" + session, target,
        ["timeout", "--kill-after=1s", "600s", "python3", path + "/.devcontainer/git-scenario.py", path, String(index), String(session), service.publicKey, String(budgets.operation)].map(quote).join(" ")], { env, timeout: 605_000 }), index);
      const result = JSON.parse(output) as { timings: { operation: string; elapsedMs: number; ok: boolean }[]; failure?: { operation: string; round: number | null; exitCode?: number; timedOut?: boolean; stderr?: string; effective?: string; global?: string; unavailable?: boolean } };
      for (const timing of result.timings) timings.push({ ...timing, workspace: index, targetMs: budgets.operation - bufferMs, budgetMs: budgets.operation });
      if (result.failure) {
        const { stderr, ...observed } = result.failure;
        const failure = { ...observed, ...(stderr === undefined ? {} : { category: processFailureCategory(stderr) }) };
        if (env.ORCA_ENV_DEVSY_RECORDING !== "0") gitFailures.push({ workspace: index, session, ...failure });
        throw new Error(`Workspace ${index} SSH ${session}: ${JSON.stringify(failure)}`);
      }
      console.log(`PASS workspace ${index} SSH ${session}: signed Git round trip`);
    }));
    for (const operation of operations) if (operation.status === "rejected") throw operation.reason;
    const auth = JSON.parse(await exec(0, 'cat "$HOME/.codex/auth.json"'));
    assert.equal(auth.tokens.refresh_token, "");
    // Fixed token generation is stored by the services fixture; compare exact
    // host contents below because wall-clock expiry is generated once per run.
    const hostAuth = JSON.parse(await readFile(env.CODEX_HOME + "/auth.json", "utf8"));
    assert.equal(auth.tokens.access_token, hostAuth.tokens.access_token);
    assert.equal(auth.tokens.account_id, "e2e-account");
    }
    if (restarting) {
      await exec(0, 'sudo mkdir -p /run/sshd; sudo /usr/sbin/sshd -f "$HOME/e2e/sshd_config"');
      await Promise.all([0, 1, 2].map(async session => {
        assert((await exec(session, "ssh-add -L")).split("\n").includes(service.publicKey));
        assert.equal((await exec(session, "ssh -F /dev/null -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost id -un")).trim(), "developer");
        const git = (args: string[]) => exec(session, "git -C " + quote(path + "/dev-" + session) + " " + args.map(quote).join(" "));
        await git(["verify-commit", "HEAD"]);
        await git(["commit", "--allow-empty", "-qm", "resumed", "-S"]);
        await git(["verify-commit", "HEAD"]);
        await git(["push", "-q"]);
      }));
    }
    const serve = async () => {
      await exec(0, `cd ${quote(path)}; nohup python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 </dev/null &`);
      await poll("curl --noproxy '*' -fsS http://127.0.0.1:8080/isolation.txt >/dev/null");
    };
    await serve();
    // Each local listener is OS-assigned; all guests intentionally use 8080.
    const listener = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } });
    const port = listener.port;
    listener.stop(true);
    await run([...base, "-S", socketRoot + "/0", "-O", "forward", "-L", `${port}:127.0.0.1:8080`, target], { env });
    const checkClient = async () => {
      type Browse = { resolvedPath: string; entries: { name: string }[] };
      let browsing: Browse;
      if (runtime.recipeResult.connection.type === "ssh") {
        assert(runtime.sshTargetId, "Orca must register the SSH target");
        const connected = await orca.call<{ status: string }>("ssh", "getState", { targetId: runtime.sshTargetId });
        assert.equal(connected.status, "connected");
        browsing = await orca.call<Browse>("ssh", "browseDir", { targetId: runtime.sshTargetId, dirPath: path });
      } else {
        assert(runtime.runtimeEnvironmentId, "Orca must register the server environment");
        const response = await orca.call<{ ok: boolean; result: Browse }>("runtimeEnvironments", "call", { selector: runtime.runtimeEnvironmentId, method: "files.browseServerDir", params: { path }, timeoutMs: budgets.operation });
        assert(response.ok);
        browsing = response.result;
      }
      assert.equal(browsing.resolvedPath, path);
      for (let peer = 0; peer < 4; peer++) assert.equal(browsing.entries.some(entry => entry.name === `isolation-${peer}.txt`), peer === index, "Orca must route to the workspace's unique marker");
    };
    const check = () => measure("workspace-check", budgets.operation, async () => {
      assert.equal(await (await fetch(`http://127.0.0.1:${port}/isolation.txt`, { signal: AbortSignal.any([AbortSignal.timeout(budgets.operation), ...signal ? [signal] : []]) })).text(), "workspace-" + index);
      await Promise.all([0, 1, 2].map(async session => {
        const output = await exec(session, `set -eu; cat ${quote(path + "/isolation.txt")}; printf '\n'; git ls-remote http://127.0.0.1:18080/w-${index}.git refs/heads/task-0; ssh -F /dev/null -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost id -un`);
        const [marker, head, user] = output.trim().split("\n");
        assert.equal(marker, "workspace-" + index);
        assert(/^[a-f0-9]{40}\s+refs\/heads\/task-0$/.test(head ?? ""));
        assert.equal(user, "developer");
      }));
      await checkClient();
    }, index);
    const crashSupervisor = async () => {
      const expected = env.XDG_STATE_HOME + "/orca-env-devsy/ssh-proxy-adapter --supervisor " + env.XDG_STATE_HOME + "/orca-env-devsy";
      const processes = await run(["ps", "-ww", "-axo", "pid=,command="], { env, timeout: budgets.operation });
      const matches = processes.split("\n").map(line => /^\s*(\d+)\s+(.*)$/.exec(line)).filter(match => match?.[2] === expected || match?.[2].startsWith(expected + " "));
      assert.equal(matches.length, 1, "Crash only the supervisor with this exact executable and owned state directory");
      const pid = Number(matches[0]![1]);
      process.kill(pid, "SIGKILL");
      await until(async () => {
        try { process.kill(pid, 0); return false; }
        catch (error) { if ((error as NodeJS.ErrnoException).code === "ESRCH") return true; throw error; }
      }, budgets.recovery);
    };
    const stopServer = async () => {
      assert.equal(runtime.recipeResult.connection.type, "orca-server");
      await exec(0, "python3 -c " + quote(`import os, pathlib, signal, socket, time
inodes = set()
for table in ["tcp", "tcp6"]:
    for row in pathlib.Path("/proc/net/" + table).read_text().splitlines()[1:]:
        fields = row.split()
        if int(fields[1].split(":")[1], 16) == 47121 and fields[3] == "0A":
            inodes.add("socket:[" + fields[9] + "]")
owners = set()
for entry in pathlib.Path("/proc").iterdir():
    if not entry.name.isdigit():
        continue
    try:
        if any(os.readlink(fd) in inodes for fd in (entry / "fd").iterdir()):
            assert b"orca" in (entry / "cmdline").read_bytes().lower()
            owners.add(int(entry.name))
    except (FileNotFoundError, PermissionError):
        pass
assert len(owners) == 1
os.kill(owners.pop(), signal.SIGTERM)
for attempt in range(100):
    with socket.socket() as client:
        if client.connect_ex(("127.0.0.1", 47121)) != 0:
            break
    time.sleep(0.05)
else:
    raise RuntimeError("Owned server did not stop")`));
    };
    const agentVersion = /\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?/.exec(await exec(0, "/usr/local/bin/devsy --version"))?.[0];
    assert(agentVersion);
    await check();
    let serverVersion: string | undefined;
    if (runtime.recipeResult.connection.type === "orca-server") {
      const version = await exec(0, 'ELECTRON_RUN_AS_NODE=1 "$HOME/.local/share/orca-env-devsy/orca/current/orca-ide" "$HOME/.local/share/orca-env-devsy/orca/current/resources/app.asar/out/cli/index.js" --version');
      serverVersion = /\d+\.\d+\.\d+/.exec(version)?.[0];
      assert(serverVersion, "Installed Orca server must report its version");
    }
    if (runtime.recipeResult.connection.type === "orca-server") {
      const connected = await orca.call<{ ok: boolean }>("runtimeEnvironments", "getStatus", { selector: runtime.runtimeEnvironmentId, timeoutMs: budgets.operation });
      assert(connected.ok);
    }
    console.log(`PASS workspace ${index}: three SSH sessions, signed Git push/fetch, agent, auth, files and HTTP isolation`);
    return { runtime, index, exec, check, checkClient, serve, close, crashSupervisor, stopServer, path, id, serverVersion, agentVersion };
  } catch (error) {
    await close(); throw error;
  }
}
