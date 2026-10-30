import { appendFile, mkdir, writeFile } from "node:fs/promises";
import { totalmem } from "node:os";
import { resolve } from "node:path";
import { processFailureCategory, type Environment } from "../../scripts/process.ts";
import { diagnosticTextSummary, providerOperationObservation } from "./diagnostics.ts";

export async function installMicrosandboxDiagnostics(root: string, env: Environment) {
  const binary = Bun.which("msb");
  if (!binary) throw new Error("Microsandbox binary missing");
  env.MSB_HOME = root + "/microsandbox";
  await writeFile(root + "/msb-operations.jsonl", "", { mode: 0o600 });
  await writeFile(root + "/bin/msb", `#!${process.execPath}\nimport { launch } from ${JSON.stringify(resolve("tests/e2e/microsandbox.ts"))};\nawait launch(${JSON.stringify(binary)}, ${JSON.stringify(env.MSB_HOME)}, ${JSON.stringify(root + "/msb-failures.jsonl")}, ${JSON.stringify(root + "/msb-operations.jsonl")});\n`, { mode: 0o700 });
}

export async function launch(binary: string, home: string, report: string, operationsReport: string) {
  const oomCount = async () => {
    try { return Number(/^oom_kill (\d+)$/m.exec(await Bun.file("/proc/vmstat").text())?.[1]); }
    catch { return NaN; }
  };
  // Lifecycle arguments are generated sandbox names. Keep their failure stderr;
  // inspect stdout contains configuration and must not enter the report.
  const lifecycle = ["inspect", "start", "stop", "remove"].includes(process.argv[2]);
  const tracked = lifecycle || ["run", "load", "exec"].includes(process.argv[2]);
  const operation = process.argv[2] ?? "other";
  const startedAt = new Date().toISOString();
  const started = performance.now();
  const before = tracked ? await oomCount() : NaN;
  const args = process.argv.slice(2);
  if (args[0] === "run") args.splice(1, 0, "--net-rule", "allow@host");
  const child = Bun.spawn([binary, ...args], { stdin: "inherit", stdout: "pipe", stderr: "pipe" });
  const interrupt = () => child.kill("SIGTERM");
  process.once("SIGTERM", interrupt);
  process.once("SIGINT", interrupt);
  let tail = "", stderrTail = "";
  const forward = async (stream: ReadableStream<Uint8Array>, destination: NodeJS.WriteStream, error = false) => {
    for await (const chunk of stream) {
      tail = (tail + Buffer.from(chunk).toString()).slice(-8192);
      if (error) stderrTail = (stderrTail + Buffer.from(chunk).toString()).slice(-8192);
      destination.write(chunk);
    }
  };
  const [code] = await Promise.all([child.exited, forward(child.stdout, process.stdout), forward(child.stderr, process.stderr, true)]);
  const elapsedMs = Math.ceil(performance.now() - started);
  if (tracked) {
    const observation = providerOperationObservation(operation, elapsedMs, code, stderrTail);
    if (observation) try {
      await appendFile(operationsReport, JSON.stringify({ startedAt, finishedAt: new Date().toISOString(), ...observation }) + "\n", { mode: 0o600 });
    } catch {
      process.stderr.write("E2E provider operation recording failed (microsandbox)\n");
    }
  }
  if (code !== 0 && tracked) try {
    const boot: { stage: string; errno?: number }[] = [];
    const stages = new Set(["mount", "build_vm", "config", "network", "image", "other"]);
    const logs = home + "/sandboxes";
    await mkdir(logs, { recursive: true });
    for await (const path of new Bun.Glob("*/logs/boot-error.json").scan({ cwd: logs, absolute: true, followSymlinks: false })) {
      if (boot.length >= 16) break;
      const file = Bun.file(path);
      if (file.size > 16_384) continue;
      const record = await file.json();
      if (stages.has(record.stage)) boot.push({ stage: record.stage, ...(Number.isInteger(record.errno) && Math.abs(record.errno) <= 4096 ? { errno: record.errno } : {}) });
    }
    const after = await oomCount();
    const message = lifecycle && stderrTail !== "" ? diagnosticTextSummary(stderrTail) : undefined;
    await appendFile(report, JSON.stringify({ memoryMiB: Math.floor(totalmem() / 1048576), ...(Number.isFinite(before) && Number.isFinite(after) ? { oomKills: Math.max(0, after - before) } : {}), operation, exitCode: code, elapsedMs, category: processFailureCategory(tail), ...(message === undefined ? {} : { message: message.text, messageTruncated: message.truncated }), boot }) + "\n", { mode: 0o600 });
  } catch { /* Diagnostics must not replace the runtime's result. */ }
  process.exit(code);
}
