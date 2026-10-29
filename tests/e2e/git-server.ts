import { type ChildProcess } from "node:child_process";
import assert from "node:assert/strict";
import { cp } from "node:fs/promises";
import { resolve } from "node:path";
import { processScope, run as cleanupRun, terminate, type Environment } from "../../scripts/process.ts";
import { budgets } from "./timing.ts";

export type GitServerStats = { accepted: Record<string, number>; rejected: Record<string, number>; backendFailures: number; filesystem: string; refs: Record<string, string[]> };
export type GitServerOptions = { devsy: string; home: string; provider: string; source: string };

function sshErrorCategories(text: string) {
  const categories = new Set<string>();
  if (/address already in use/i.test(text)) categories.add("local_port_busy");
  if (/connect failed: connection refused/i.test(text)) categories.add("remote_target_refused");
  if (/could not request local forwarding|cannot listen to port/i.test(text)) categories.add("local_forward_failed");
  if (/connection closed|broken pipe/i.test(text)) categories.add("connection_closed");
  if (/permission denied/i.test(text)) categories.add("authentication_failed");
  if (text && categories.size === 0) categories.add("other");
  return [...categories];
}

export async function gitServer(root: string, env: Environment, options: GitServerOptions, signal?: AbortSignal) {
  const { run, until } = processScope(signal);
  const source = root + "/git-server";
  await cp(resolve("tests/e2e/git-server"), source, { recursive: true });
  await cp(options.source, source + "/source.git", { recursive: true });
  const id = "orca-" + crypto.randomUUID();
  const args = [options.devsy, "--home", options.home];
  const connections: ChildProcess[] = [];
  const connectionErrors: string[] = [];
  let closed = false;
  const close = async (cleanupSignal?: AbortSignal) => {
    if (closed) return;
    closed = true;
    try { await Promise.all(connections.map(connection => terminate(connection))); }
    finally { await cleanupRun([...args, "workspace", "delete", id, "--force", "--ignore-not-found"], { env, signal: cleanupSignal, timeout: budgets.lifecycle }); }
  };
  try {
    await run([...args, "--result-format", "json", "workspace", "up", source, "--id", id, "--provider", options.provider, "--ide-launch", "skip"], { env, timeout: budgets.provision });
    const listener = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } });
    const port = listener.port;
    listener.stop(true);
    // Keep the fixture alive through phase cancellation so cleanup can read its
    // final counters before deleting this owned workspace.
    const ssh = [...args, "workspace", "ssh", id, "--start-services=false", "--agent-forwarding=false", "--user", "root"];
    for (const [index, command] of [
      [...ssh, "--command", "python3 /usr/local/bin/git-fixture.py"],
      [...ssh, "-L", `${port}:127.0.0.1:18081`],
    ].entries()) {
      const connection = processScope().start(command, { env });
      connection.stdout?.resume();
      connection.stderr?.on("data", data => {
        connectionErrors[index] = ((connectionErrors[index] ?? "") + data.toString()).slice(-4096);
      });
      connections.push(connection);
    }
    const stats = async (readSignal = signal): Promise<GitServerStats> => {
      const response = await fetch(`http://127.0.0.1:${port}/__metrics`, { signal: AbortSignal.any([AbortSignal.timeout(budgets.operation), ...readSignal ? [readSignal] : []]) });
      assert(response.ok, "Git fixture metrics must be available");
      return response.json() as Promise<GitServerStats>;
    };
    await until(async () => {
      if (connections.some(connection => connection.exitCode !== null)) throw new Error("Git fixture connection exited");
      try { return (await stats()).filesystem === "tmpfs"; }
      catch { signal?.throwIfAborted(); return false; }
    }, budgets.lifecycle);
    const diagnostics = async () => {
      const metricsReachable = await stats().then(() => true, () => false);
      return {
        metricsReachable,
        connections: connections.map((connection, index) => ({
          exitCode: connection.exitCode,
          signal: connection.signalCode,
          stderrCategories: sshErrorCategories(connectionErrors[index] ?? ""),
        })),
      };
    };
    return { port, sourceUrl: `http://127.0.0.1:${port}/source.git`, stats, diagnostics, close };
  } catch (error) { await close().catch(() => {}); throw error; }
}
