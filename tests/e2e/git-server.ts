import { type ChildProcess } from "node:child_process";
import assert from "node:assert/strict";
import { cp } from "node:fs/promises";
import { resolve } from "node:path";
import { processScope, quote, run as cleanupRun, terminate, type Environment } from "../../scripts/process.ts";
import { budgets } from "./timing.ts";

export type GitServerStats = { accepted: Record<string, number>; rejected: Record<string, number>; backendFailures: number; filesystem: string; refs: Record<string, string[]>; hostGateway: string };
type HostProbe = { target: string; result: string };
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

function sshErrorSummary(text: string) {
  return text
    .replace(/https?:\/\/[^\s/@:]+:[^\s/@]+@/gi, "https://[redacted]@")
    .replace(/\b(bearer|basic)\s+\S+/gi, "$1 [redacted]")
    .replace(/\b(token|password|secret|authorization|cookie)(\s*[:=]\s*)\S+/gi, "$1$2[redacted]")
    .replace(/\b[A-Za-z0-9_=-]{24,}\b/g, "[long-value]")
    .trim()
    .slice(-512);
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
      [...ssh, "--forward-ports", `0.0.0.0:${port}:127.0.0.1:18081`],
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
      const exited = connections.flatMap((connection, index) => connection.exitCode !== null ? [{
        name: index === 0 ? "fixture-server" : "source-tunnel",
        exitCode: connection.exitCode,
        signal: connection.signalCode,
        stderrCategories: sshErrorCategories(connectionErrors[index] ?? ""),
        stderrSummary: sshErrorSummary(connectionErrors[index] ?? ""),
      }] : []);
      if (exited.length > 0) throw new Error(`Git fixture connection exited: ${JSON.stringify(exited)}`);
      try { return (await stats()).filesystem === "tmpfs"; }
      catch { signal?.throwIfAborted(); return false; }
    }, budgets.lifecycle);
    const hostGateway = (await stats()).hostGateway;
    const hostProbeScript = [
      "import urllib.request",
      "import urllib.error",
      "import errno",
      "import socket",
      "import json",
      "from concurrent.futures import ThreadPoolExecutor",
      `targets = {"default_gateway": [${JSON.stringify(hostGateway)}], "vm_host_alias": ["10.0.2.2"]}`,
      "for name in ('host.containers.internal', 'host.docker.internal'):",
      "    try:",
      "        targets[name] = sorted({item[4][0] for item in socket.getaddrinfo(name, None, type=socket.SOCK_STREAM)})",
      "    except OSError:",
      "        targets[name] = []",
      "def probe(address):",
      "    authority = '[' + address + ']' if ':' in address else address",
      `    url = 'http://' + authority + ':' + ${JSON.stringify(String(port))} + '/__metrics'`,
      "    try:",
      "        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(url, timeout=1) as response:",
      "            return 'http_' + str(response.status)",
      "    except TimeoutError:",
      "        return 'timeout'",
      "    except urllib.error.URLError as error:",
      "        reason = error.reason",
      "        if isinstance(reason, TimeoutError): return 'timeout'",
      "        if isinstance(reason, OSError):",
      "            categories = {errno.ECONNREFUSED: 'connection_refused', errno.EHOSTUNREACH: 'host_unreachable', errno.ENETUNREACH: 'network_unreachable', errno.ETIMEDOUT: 'timeout'}",
      "            return categories.get(reason.errno, 'os_error')",
      "        return 'url_error'",
      "    except OSError as error:",
      "        categories = {errno.ECONNREFUSED: 'connection_refused', errno.EHOSTUNREACH: 'host_unreachable', errno.ENETUNREACH: 'network_unreachable', errno.ETIMEDOUT: 'timeout'}",
      "        return categories.get(error.errno, 'os_error')",
      "with ThreadPoolExecutor(max_workers=16) as pool:",
      "    pending = {(name, address): pool.submit(probe, address) for name, addresses in targets.items() for address in addresses}",
      "    results = {name: sorted({future.result() for (target, _), future in pending.items() if target == name}) if addresses else ['name_resolution'] for name, addresses in targets.items()}",
      "print(json.dumps(results, sort_keys=True))",
    ].join("\n");
    const hostProbes: HostProbe[] = await run([
      ...ssh,
      "--command",
      `python3 -c ${quote(hostProbeScript)}`,
    ], { env, timeout: budgets.operation }).then(output => JSON.parse(output.trim()) as Record<string, string[]>).then(results => Object.entries(results).map(([target, values]) => ({ target, result: values.join(",") }))).catch(() => {
      signal?.throwIfAborted();
      return [{ target: "probe", result: "unavailable" }];
    });
    const diagnostics = async () => {
      const metricsReachable = await stats().then(() => true, () => false);
      return {
        metricsReachable,
        hostProbes,
        connections: connections.map((connection, index) => ({
          exitCode: connection.exitCode,
          signal: connection.signalCode,
          stderrCategories: sshErrorCategories(connectionErrors[index] ?? ""),
        })),
      };
    };
    return {
      port,
      localSourceUrl: `http://127.0.0.1:${port}/source.git`,
      sourceUrl: `http://${hostGateway}:${port}/source.git`,
      stats,
      diagnostics,
      close,
    };
  } catch (error) { await close().catch(() => {}); throw error; }
}
