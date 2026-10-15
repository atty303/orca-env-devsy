import assert from "node:assert/strict";
import { mkdtemp, rm, readFile, lstat } from "node:fs/promises";
import { run as cleanupRun, start, processScope, withAbort, terminate, quote, type Environment, processFailureCategory } from "../../scripts/process.ts";
import { type Orca, type Runtime } from "./orca.ts";
import { type services } from "./services.ts";
import { budgets, measure } from "./timing.ts";
import { diagnosticRun, sshStartupPhases } from "./diagnostics.ts";

type Services = Awaited<ReturnType<typeof services>>;
export const sshConnectionFailures: { workspace: number; restarting: boolean; sessions: { exitCode: number | null; signal: NodeJS.Signals | null; category: string; socketReady: boolean; truncated: boolean; phases: string[] }[] }[] = [];
export const firstUseFailures: { workspace: number; run?: number; helper?: boolean; endpoint?: boolean; unavailable?: boolean }[] = [];
export async function firstUse(runtime: Runtime, index: number, env: Environment, service: Services, signal?: AbortSignal) {
  const { run } = processScope(signal);
  const state = runtime.recipeResult.userData;
  const saved = JSON.parse(await readFile(state.tunnelDirectory + "/state.json", "utf8"));
  assert.equal(saved.workspaceUid, state.workspaceUid);
  const base = ["ssh", "-F", env.HOME + "/.ssh/config", "-o", "ProxyCommand=false", "-S", saved.socketDirectory + "/socket"];
  const target = `${state.user}@${state.workspaceId}.devsy`;
  const forwarding = `18080:127.0.0.1:${service.port}`;
  const accepted = service.requests.get("w-" + index) ?? 0;
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
    assert((service.requests.get("w-" + index) ?? 0) > accepted, "First use must authenticate to the Git server");
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
    assert.equal((await exec(0, "cat " + quote(path + "/identity.txt"))).trim(), index === 1 ? "fixture-task" : "fixture-build");
    if (!restarting) {
    await exec(0, `set -eu; cd ${quote(path)}; test -w .; test -w "$HOME"; git config --global credential.useHttpPath true; printf %s ${quote("workspace-" + index)} > isolation.txt; cp isolation.txt isolation-${index}.txt; mkdir -p "$HOME/e2e"; printf '%s\\n' ${quote(service.publicKey)} > "$HOME/e2e/authorized_keys"; printf '%s\\n' ${quote("e2e " + service.publicKey)} > "$HOME/e2e/allowed_signers"; ssh-keygen -q -t ed25519 -N '' -f "$HOME/e2e/hostkey"; printf '%s\\n' 'Port 2222' 'ListenAddress 127.0.0.1' 'PasswordAuthentication no' 'UsePAM yes' 'StrictModes no' "HostKey $HOME/e2e/hostkey" "AuthorizedKeysFile $HOME/e2e/authorized_keys" "PidFile $HOME/e2e/sshd.pid" > "$HOME/e2e/sshd_config"; sudo mkdir -p /run/sshd; sudo /usr/sbin/sshd -f "$HOME/e2e/sshd_config"`);
    const operations = await Promise.allSettled([0, 1, 2].map(async session => {
      const directory = `dev-${session}`;
      assert.equal(await exec(session, `cat ${quote(path + "/isolation.txt")}`), "workspace-" + index);
      assert((await exec(session, "ssh-add -L")).split("\n").includes(service.publicKey));
      assert.equal((await exec(session, "ssh -F /dev/null -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost id -un")).trim(), "developer");
      const cwd = path + "/" + directory;
      const command = (args: string[]) => exec(session, "cd " + quote(cwd) + " && " + args.map(quote).join(" "));
      const git = (...args: string[]) => measure("git-" + (args[0] === "-C" ? args[2] : args[0]), budgets.operation, () => command(["git", ...args]), index);
      await exec(session, "mkdir " + quote(cwd));
      await exec(session, `cd ${quote(cwd)} && printf edit > first && mv first renamed && ln -s renamed link`);
      assert.equal(await command(["cat", "link"]), "edit");
      await exec(session, `cd ${quote(cwd)} && printf '#!/bin/sh\\nprintf executable' > executable && chmod +x executable`);
      assert.equal(await command(["./executable"]), "executable");
      await command(["rm", "link", "renamed"]);
      assert(!(await command(["ls"])).split("\n").includes("renamed"));
      await git("init", "-q", "-b", "task-" + session);
      for (const [key, value] of Object.entries({ "user.name": "E2E", "user.email": "e2e@example.invalid", "gpg.format": "ssh", "user.signingkey": service.publicKey, "gpg.ssh.allowedSignersFile": "/home/developer/e2e/allowed_signers" })) await git("config", key, value);
      await exec(session, `printf %s ${quote(`w-${index}-s-${session}`)} > ${quote(cwd + "/identity")}`);
      await git("add", "identity", "executable");
      await git("commit", "-qm", "initial", "-S");
      await git("verify-commit", "HEAD");
      const url = `http://127.0.0.1:18080/w-${index}.git`;
      await git("remote", "add", "origin", url);
      await git("push", "-q", "-u", "origin", "HEAD");
      await git("clone", "-q", "--branch", "task-" + session, url, "../clone-" + session);
      assert.equal(await command(["cat", "../clone-" + session + "/identity"]), `w-${index}-s-${session}`);
      await exec(session, `printf update >> ${quote(cwd + "/identity")}`);
      await git("commit", "-qam", "update", "-S");
      await git("push", "-q");
      await git("-C", "../clone-" + session, "fetch", "-q");
      await git("-C", "../clone-" + session, "reset", "-q", "--hard", "origin/task-" + session);
      assert.equal(await command(["cat", "../clone-" + session + "/identity"]), `w-${index}-s-${session}update`);
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
      assert(runtime.runtimeEnvironmentId, "Orca must register a managed environment for each recipe");
      if (runtime.sshTargetId) {
        const connected = await orca.call<{ status: string; managedServer?: { kind: string; environmentId?: string } }>("ssh", "getState", { targetId: runtime.sshTargetId });
        assert.equal(connected.status, "connected");
        assert.equal(connected.managedServer?.kind, "managed");
        assert.equal(connected.managedServer.environmentId, runtime.runtimeEnvironmentId);
      }
      const browsing = await orca.call<{ ok: boolean; result: { resolvedPath: string; entries: { name: string }[] } }>("runtimeEnvironments", "call", { selector: runtime.runtimeEnvironmentId, method: "files.browseServerDir", params: { path }, timeoutMs: budgets.operation });
      assert(browsing.ok);
      assert.equal(browsing.result.resolvedPath, path);
      for (let peer = 0; peer < 4; peer++) assert.equal(browsing.result.entries.some(entry => entry.name === `isolation-${peer}.txt`), peer === index, "Orca must route to the workspace's unique marker");
    };
    const check = () => measure("workspace-check", budgets.operation, async () => {
      assert.equal(await (await fetch(`http://127.0.0.1:${port}/isolation.txt`, { signal: AbortSignal.any([AbortSignal.timeout(budgets.operation), ...signal ? [signal] : []]) })).text(), "workspace-" + index);
      await Promise.all([0, 1, 2].map(async session => {
        assert.equal(await exec(session, "cat " + quote(path + "/isolation.txt")), "workspace-" + index);
        assert(/^[a-f0-9]{40}\s+refs\/heads\/task-0/.test(await exec(session, `git ls-remote http://127.0.0.1:18080/w-${index}.git refs/heads/task-0`)));
        assert.equal((await exec(session, "ssh -F /dev/null -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost id -un")).trim(), "developer");
      }));
      await checkClient();
    }, index);
    const crashWorker = async () => {
      const expected = env.XDG_STATE_HOME + "/orca-env-devsy/ssh-proxy-adapter --tunnel-worker " + state.tunnelDirectory;
      const processes = await run(["ps", "-ww", "-axo", "pid=,command="], { env, timeout: budgets.operation });
      const matches = processes.split("\n").map(line => /^\s*(\d+)\s+(.*)$/.exec(line)).filter(match => match?.[2] === expected);
      assert.equal(matches.length, 1, "Crash only the worker with this exact executable and owned directory");
      const pid = Number(matches[0]![1]);
      process.kill(pid, "SIGKILL");
      await until(async () => {
        try { process.kill(pid, 0); return false; }
        catch (error) { if ((error as NodeJS.ErrnoException).code === "ESRCH") return true; throw error; }
      }, budgets.recovery);
    };
    const recoverRelay = async () => {
      const saved = JSON.parse(await readFile(state.tunnelDirectory + "/state.json", "utf8"));
      const master = ["ssh", "-F", env.HOME + "/.ssh/config", "-o", "ProxyCommand=false", "-S", saved.socketDirectory + "/socket", "-O", "check", target];
      const pid = async () => {
        const output = await run(master, { env, timeout: budgets.operation, output: "stderr" });
        const value = /pid=(\d+)/.exec(output)?.[1];
        assert(value);
        return value;
      };
      const before = await pid();
      const server = (await exec(0, "pgrep -o -f '[d]evsy internal agent container credentials-server --user " + user + "'")).trim();
      assert(/^\d+$/.test(server));
      await measure("credential-relay-recovery", budgets.recovery, async () => {
        await exec(0, "sudo kill -TERM " + server);
        await Promise.all([checkClient(), until(async () => {
          try {
            const refs = await exec(1, `git ls-remote http://127.0.0.1:18080/w-${index}.git refs/heads/task-0`);
            return /^[a-f0-9]{40}\s+refs\/heads\/task-0/.test(refs);
          } catch { return false; }
        }, budgets.recovery)]);
      }, index);
      assert.equal(await pid(), before, "Credential recovery must preserve the primary SSH master");
      await check();
    };
    await check();
    let serverVersion: string | undefined;
    if (runtime.recipeResult.connection.type === "orca-server") {
      const version = await exec(0, 'ELECTRON_RUN_AS_NODE=1 "$HOME/.local/share/orca-env-devsy/orca/current/orca-ide" "$HOME/.local/share/orca-env-devsy/orca/current/resources/app.asar/out/cli/index.js" --version');
      serverVersion = /\d+\.\d+\.\d+/.exec(version)?.[0];
      assert(serverVersion, "Installed Orca server must report its version");
    }
    const connected = await orca.call<{ ok: boolean }>("runtimeEnvironments", "getStatus", { selector: runtime.runtimeEnvironmentId, timeoutMs: budgets.operation });
    assert(connected.ok);
    console.log(`PASS workspace ${index}: three SSH sessions, signed Git push/fetch, agent, auth, files and HTTP isolation`);
    return { runtime, index, exec, check, checkClient, serve, close, recoverRelay, crashWorker, path, id, serverVersion };
  } catch (error) {
    await close(); throw error;
  }
}
