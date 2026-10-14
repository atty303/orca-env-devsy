// Temporary CI diagnosis: reproduce VM startup without Devsy or adapter state.
import { mkdtemp, rm, mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { run, processFailureCategory, type Environment } from "../../scripts/process.ts";

if (process.platform !== "linux" || process.env.GITHUB_ACTIONS !== "true") throw new Error("Disposable Linux CI only");
const root = await mkdtemp("/tmp/msb-probe-");
const binary = resolve(".tools/e2e/microsandbox/msb");
const env: Environment = { PATH: process.env.PATH, HOME: root, MSB_HOME: root + "/msb", LD_LIBRARY_PATH: resolve(".tools/e2e/microsandbox") };
const names = [0, 1, 2, 3].map(index => "probe-" + root.split("/").at(-1)!.toLowerCase() + "-" + index);
const outcomes: { ready: boolean; exitCode: number | null; sites: string[]; category: string; signals: string[] }[] = [];
const processes: ReturnType<typeof Bun.spawn>[] = [];
try {
  for (const name of names) {
    const state = { ready: false, exitCode: null as number | null, sites: [] as string[], category: "pending", signals: [] as string[] };
    outcomes.push(state);
    const child = Bun.spawn([binary, "run", "--name", name, "--memory", "2048M", "--cpus", "1", "--no-stdin", "--no-tty", "ubuntu:24.04", "--", "/bin/sh", "-c", "printf MSB_PROBE_READY; sleep 120"], { env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    processes.push(child);
    const read = async (stream: ReadableStream<Uint8Array>) => {
      let tail = "";
      for await (const chunk of stream) {
        tail = (tail + Buffer.from(chunk).toString()).slice(-65536);
        if (tail.includes("MSB_PROBE_READY")) state.ready = true;
        state.category = processFailureCategory(tail);
        state.signals = [
          ["kvm", /kvm/i], ["memory", /memory|allocation/i], ["directory", /no such file|not found/i],
          ["permission", /permission|denied/i], ["database", /database|sqlite/i], ["image", /manifest|image|registry/i],
          ["download", /download|pull/i], ["configuration", /config|invalid/i], ["argument", /argument|usage:/i],
          ["thread-limit", /resource temporarily unavailable|thread.*spawn/i], ["runtime", /runtime|libkrunfw/i],
          ["abort", /abort|panic/i], ["address", /address already in use/i], ["tls", /certificate|tls/i],
        ].filter(([, expression]) => (expression as RegExp).test(tail)).map(([category]) => category as string);
        state.sites = [...new Set([...tail.matchAll(/([A-Za-z0-9_]+\.(?:c|cc|rs)):(\d+)(?::\d+)?/g)].map(match => match[1] + ":" + match[2]))].slice(-16);
      }
    };
    void Promise.all([read(child.stdout), read(child.stderr), child.exited.then(code => { state.exitCode = code; })]).catch(() => {});
  }
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline && outcomes.some(outcome => !outcome.ready && outcome.exitCode === null)) await Bun.sleep(200);
  await mkdir(".e2e/runtime-probe", { recursive: true });
  await writeFile(".e2e/runtime-probe/diagnostic.json", JSON.stringify({ kind: "native-microsandbox-startup", outcomes }, null, 2), { mode: 0o600 });
  if (outcomes.some(outcome => !outcome.ready || outcome.exitCode !== null)) process.exitCode = 1;
} finally {
  for (const child of processes) child.kill("SIGTERM");
  for (const name of names) {
    await run([binary, "stop", name], { env, timeout: 10_000 }).catch(() => {});
    await run([binary, "remove", name], { env, timeout: 10_000 }).catch(() => {});
  }
  for (const child of processes) { child.kill("SIGKILL"); await child.exited; }
  await rm(root, { recursive: true, force: true });
}
