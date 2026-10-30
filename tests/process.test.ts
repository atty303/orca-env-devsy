import { expect, test } from "bun:test";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { children, processScope, run, start, terminate, until, waitForExit } from "../scripts/process.ts";
import { Orca, ensureOrcaInstallation } from "./e2e/orca.ts";
import { OrcaObservations } from "./e2e/observations.ts";
import { DiagnosticError } from "./e2e/diagnostics.ts";
import { cleanupDeadline } from "./e2e/control.ts";
import { budgets } from "./e2e/timing.ts";
import { services } from "./e2e/services.ts";

test("command deadlines reject even when an exited parent leaves inherited pipes open", async () => {
  const before = new Set(children);
  const started = performance.now();
  const operation = run(["sh", "-c", "sleep 30 & printf private-pipe-fixture; exit 0"], { timeout: 50 });
  try {
    const result = await Promise.race([
      operation.then(() => "success", error => (error as Error).message),
      Bun.sleep(1000).then(() => "still-pending"),
    ]);
    expect(result).toBe("Child command deadline exceeded (timeout)");
    expect(performance.now() - started).toBeLessThan(1000);
  } finally {
    for (const child of children) if (!before.has(child)) {
      try { process.kill(-child.pid!, "SIGKILL"); } catch { /* Owned process group may already be gone. */ }
    }
    await operation.catch(() => {});
  }
});

test("termination reaps owned descendants after their parent exits", async () => {
  const child = start(["sh", "-c", "sleep 30 & exit 0"]);
  try {
    await once(child, "exit");
    await terminate(child);
    expect(children.has(child)).toBe(false);
  } finally {
    try { process.kill(-child.pid!, "SIGKILL"); } catch { /* Owned process group may already be gone. */ }
  }
});

test("termination escalates for a descendant that ignores TERM and closes its pipes", async () => {
  const child = start(["sh", "-c", `sh -c 'trap "" TERM; echo $$; exec sleep 30 >/dev/null 2>&1' </dev/null & wait`]);
  const [output] = await once(child.stdout!, "data");
  const descendant = Number(output.toString().trim());
  expect(Number.isSafeInteger(descendant) && descendant > 1).toBe(true);
  try {
    await terminate(child);
    let gone = false;
    try { process.kill(descendant, 0); }
    catch (error) { gone = (error as NodeJS.ErrnoException).code === "ESRCH"; }
    expect(gone).toBe(true);
  } finally {
    try { process.kill(-child.pid!, "SIGKILL"); } catch { /* Owned process group may already be gone. */ }
  }
});

test("termination retains ownership after the leader and all its pipes close", async () => {
  const child = start(["sh", "-c", `sh -c 'echo $$; exec sleep 30 >/dev/null 2>&1' </dev/null & exit 0`]);
  const [output] = await once(child.stdout!, "data");
  const descendant = Number(output.toString().trim());
  expect(Number.isSafeInteger(descendant) && descendant > 1).toBe(true);
  await once(child, "close");
  try {
    expect(children.has(child)).toBe(true);
    await terminate(child);
    let gone = false;
    try { process.kill(descendant, 0); }
    catch (error) { gone = (error as NodeJS.ErrnoException).code === "ESRCH"; }
    expect(gone).toBe(true);
    expect(children.has(child)).toBe(false);
  } finally {
    try { process.kill(-child.pid!, "SIGKILL"); } catch { /* Owned process group may already be gone. */ }
  }
});

test("Orca close rejects at its deadline even if killing Electron never settles close", async () => {
  let kills = 0;
  const app = { close: () => new Promise<void>(() => {}), process: () => ({ kill(signal: string) { expect(signal).toBe("SIGKILL"); kills++; return false; } }) };
  const orca = Reflect.construct(Orca, [app, 0, new OrcaObservations()]) as Orca;
  const started = performance.now();
  const result = await Promise.race([
    orca.close(50).then(() => "success", error => (error as Error).message),
    Bun.sleep(1000).then(() => "still-pending"),
  ]);
  expect(result).toBe("Orca close deadline exceeded");
  expect(kills).toBe(1);
  expect(performance.now() - started).toBeLessThan(1000);
});

test("closed child input fails safely without an unhandled stream error", async () => {
  const before = new Set(children);
  try {
    await expect(run(["sh", "-c", "exec 0<&-; sleep 30"], { input: "private-input".repeat(131072), timeout: 1000 })).rejects.toThrow("Child input stream failed");
  } finally {
    await Promise.all([...children].filter(child => !before.has(child)).map(child => terminate(child)));
  }
});

test("one cleanup deadline cancels parallel stalled commands and prevents later launches", async () => {
  const before = new Set(children);
  const errors: string[] = [];
  const cleanup = cleanupDeadline(errors, 200);
  const scoped = processScope(cleanup.signal);
  const started = performance.now();
  try {
    const results = await Promise.allSettled([0, 1, 2, 3].map((_, index) => scoped.run([process.execPath, "-e", "setInterval(() => {}, 100)"], { timeout: 1500, input: index === 0 ? "x".repeat(262144) : undefined })));
    expect(results.every(result => result.status === "rejected")).toBe(true);
    expect(errors).toEqual(["cleanup-deadline"]);
    expect(performance.now() - started).toBeLessThan(1000);
    await expect(scoped.run([process.execPath, "-e", "process.exit(0)"])).rejects.toThrow("E2E cleanup deadline exceeded");
  } finally {
    cleanup.close();
    await Promise.all([...children].filter(child => !before.has(child)).map(child => terminate(child)));
  }
});

test("an interrupted Orca call rejects immediately while cleanup uses its own signal", async () => {
  let calls = 0;
  const phase = new AbortController();
  const cleanup = new AbortController();
  const app = { evaluate: () => ++calls === 1 ? new Promise(() => {}) : Promise.resolve({ ok: true, value: { status: "cleaned" } }) };
  const orca = Reflect.construct(Orca, [app, 0, new OrcaObservations(), phase.signal]) as Orca;
  const active = orca.call("ephemeralVm", "resumeWorkspace");
  phase.abort(new Error("E2E interrupted"));
  await expect(active).rejects.toThrow("IPC failed");
  await expect(orca.call("ephemeralVm", "resumeWorkspace")).rejects.toThrow("E2E interrupted");
  expect(await orca.call("ephemeralVm", "cleanup", undefined, cleanup.signal)).toEqual({ status: "cleaned" });
  expect(calls).toBe(2);
});

test("Orca renderer rejection retains classified IPC error without exposing its message", async () => {
  const app = { evaluate: () => Promise.resolve({ ok: false, error: { name: "Error", code: "ECONNRESET", message: "fixture-private-password" } }) };
  const orca = Reflect.construct(Orca, [app, 0, new OrcaObservations()]) as Orca;
  const error = await orca.call("ephemeralVm", "suspendWorkspace").catch(error => error);
  expect(error).toBeInstanceOf(DiagnosticError);
  if (!(error instanceof DiagnosticError)) throw error;
  expect(error.category).toBe("connection_reset");
  expect(JSON.stringify(error)).not.toContain("fixture-private-password");
});

test("SSH agent readiness stops retrying when execution is interrupted", async () => {
  const before = new Set(children);
  const root = await mkdtemp(tmpdir() + "/oe-agent-cancel-");
  const phase = new AbortController();
  try {
    await mkdir(root + "/mock");
    await writeFile(root + "/mock/ssh-add", '#!/bin/sh\ntouch "$HOME/add-attempted"\nexit 1\n', { mode: 0o700 });
    const operation = services(root, { HOME: root, CODEX_HOME: root + "/codex", PATH: root + "/mock:" + process.env.PATH }, { devsy: "devsy", home: root + "/devsy", provider: "apple", source: root + "/source.git" }, phase.signal);
    void operation.catch(() => {});
    await until(() => Bun.file(root + "/add-attempted").exists(), 2000);
    const started = performance.now();
    phase.abort(new Error("E2E interrupted"));
    await expect(operation).rejects.toThrow("E2E interrupted");
    expect(performance.now() - started).toBeLessThan(500);
  } finally {
    phase.abort();
    await Promise.all([...children].filter(child => !before.has(child)).map(child => terminate(child)));
    await rm(root, { recursive: true, force: true });
  }
});

test("interrupted Electron launch and initialization retain late apps until failed-result cleanup", async () => {
  const root = await mkdtemp(tmpdir() + "/oe-launch-");
  try {
    for (const stage of ["launch", "home", "environment", "bridge"] as const) {
      const phase = new AbortController();
      const acquired = Promise.withResolvers<never>();
      let entered = false, closed = 0, evaluations = 0;
      const app = {
        on() {},
        evaluate() {
          evaluations++;
          const target = stage === "home" ? 1 : stage === "environment" ? 2 : 3;
          if (evaluations === target) { entered = true; return new Promise(() => {}); }
          return Promise.resolve(evaluations === 1 ? root + "/home" : { home: root + "/home", path: "/fixture-bin" });
        },
        close: async () => { closed++; },
        process: () => ({ kill() { throw new Error("Graceful fixture close must finish"); } }),
      };
      const launch = Orca.launch("fixture", root + "/profile", { HOME: root + "/home", PATH: "/fixture-bin" }, phase.signal, async () => {
        if (stage === "launch") { entered = true; return acquired.promise; }
        return app as never;
      });
      await until(async () => entered, 1000);
      const started = performance.now();
      phase.abort(new Error("E2E interrupted"));
      await expect(launch).rejects.toThrow("E2E interrupted");
      expect(performance.now() - started).toBeLessThan(500);
      const errors: string[] = [];
      const cleanup = cleanupDeadline(errors, 1000);
      try {
        const settled = Orca.settleLaunches(cleanup.signal);
        if (stage === "launch") acquired.resolve(app as never);
        await settled;
        const report = root + "/" + stage + ".json";
        await writeFile(report, JSON.stringify({ status: "failed", cleanupErrors: errors }));
        expect(JSON.parse(await readFile(report, "utf8"))).toEqual({ status: "failed", cleanupErrors: [] });
        expect(closed).toBe(1);
        expect(evaluations).toBe(stage === "launch" ? 0 : stage === "home" ? 1 : stage === "environment" ? 2 : 3);
      } finally { cleanup.close(); }
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("Electron acquired after its measured deadline is closed before launch cleanup settles", async () => {
  const root = await mkdtemp(tmpdir() + "/oe-launch-");
  const original = budgets.lifecycle;
  let closed = 0, evaluations = 0;
  try {
    budgets.lifecycle = 20;
    const app = {
      evaluate() { evaluations++; },
      close: async () => { closed++; },
      process: () => ({ kill() { throw new Error("Graceful fixture close must finish"); } }),
    };
    const launch = Orca.launch("fixture", root + "/profile", { HOME: root + "/home" }, undefined, async () => {
      await Bun.sleep(40);
      return app as never;
    });
    await expect(launch).rejects.toThrow();
    await Orca.settleLaunches(AbortSignal.timeout(1000));
    expect(closed).toBe(1);
    expect(evaluations).toBe(0);
  } finally {
    budgets.lifecycle = original;
    await rm(root, { recursive: true, force: true });
  }
});

test("interrupted Orca extraction is retried before its executable becomes cache-ready", async () => {
  const root = await mkdtemp(tmpdir() + "/oe-install-");
  const executable = root + "/orca";
  let installs = 0;
  try {
    await expect(ensureOrcaInstallation(root, executable, async () => {
      installs++;
      await writeFile(executable, "partial");
      throw new Error("Extraction interrupted");
    })).rejects.toThrow("Extraction interrupted");
    await ensureOrcaInstallation(root, executable, async () => {
      installs++;
      await writeFile(executable, "complete");
    });
    expect(installs).toBe(2);
    expect(await readFile(executable, "utf8")).toBe("complete");
    await ensureOrcaInstallation(root, executable, async () => { installs++; });
    expect(installs).toBe(2);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("termination signals enter cleanup and repeated signals preserve the failed result", async () => {
  const root = await mkdtemp(tmpdir() + "/oe-control-");
  try {
    for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"] as const) {
      const report = root + "/" + signal + ".json";
      const script = `
import { interruptibleRun, cleanupDeadline } from ${JSON.stringify(resolve("tests/e2e/control.ts"))};
import { processScope, withAbort } from ${JSON.stringify(resolve("scripts/process.ts"))};
import { writeFile } from "node:fs/promises";
const phase = interruptibleRun();
let continued = false;
try {
  const active = processScope(phase.signal).run([process.execPath, "-e", "setInterval(() => {}, 100)"]);
  console.log("active");
  await active;
  continued = true;
} catch {} finally {
  phase.beginCleanup();
  const errors = [];
  const cleanup = cleanupDeadline(errors, 500);
  console.log("cleanup");
  await withAbort(cleanup.signal, () => new Promise(() => {})).catch(() => {});
  cleanup.close();
  await writeFile(${JSON.stringify(report)}, JSON.stringify({ status: "failed", interrupted: phase.interrupted, continued, errors }));
  phase.close();
}
`;
      const child = start([process.execPath, "-e", script]);
      let output = "";
      child.stdout!.on("data", chunk => { output += chunk.toString(); });
      child.stderr!.resume();
      try {
        await until(async () => output.includes("active"), 2000);
        const started = performance.now();
        child.kill(signal);
        await until(async () => output.includes("cleanup"), 1000);
        child.kill(signal);
        await waitForExit(child, 2000);
        expect(child.exitCode).toBe(0);
        expect(JSON.parse(await readFile(report, "utf8"))).toEqual({ status: "failed", interrupted: true, continued: false, errors: ["cleanup-deadline"] });
        expect(performance.now() - started).toBeLessThan(2000);
      } finally { await terminate(child); }
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});


test("Microsandbox lifecycle failures preserve stderr and exit without exporting inspect stdout", async () => {
  const root = await mkdtemp(tmpdir() + "/orca-msb-diagnostic-");
  try {
    const binary = root + "/msb", report = root + "/failures.jsonl", operations = root + "/operations.jsonl", launcher = root + "/launch.ts";
    await writeFile(binary, "#!/bin/sh\nprintf 'fixture configuration must stay private'\nprintf 'remove: permission denied /tmp/owned-sandbox/state.db' >&2\nexit 7\n", { mode: 0o700 });
    await writeFile(operations, "");
    await writeFile(launcher, `import { launch } from ${JSON.stringify(resolve("tests/e2e/microsandbox.ts"))};\nawait launch(${JSON.stringify(binary)}, ${JSON.stringify(root)}, ${JSON.stringify(report)}, ${JSON.stringify(operations)});\n`);
    for (const operation of ["inspect", "start", "stop", "remove", "exec"]) {
      const child = start([process.execPath, launcher, operation, "fixture-sandbox"]);
      let stdout = "", stderr = "";
      child.stdout!.setEncoding("utf8").on("data", chunk => { stdout += chunk; });
      child.stderr!.setEncoding("utf8").on("data", chunk => { stderr += chunk; });
      await waitForExit(child, 5000);
      expect(child.exitCode).toBe(7);
      expect(stdout).toBe("fixture configuration must stay private");
      expect(stderr).toBe("remove: permission denied /tmp/owned-sandbox/state.db");
    }
    const text = await readFile(report, "utf8");
    const records = text.trim().split("\n").map(line => JSON.parse(line));
    expect(records.map(record => record.operation)).toEqual(["inspect", "start", "stop", "remove", "exec"]);
    expect(records.slice(0, 4).every(record => record.message === "remove: permission denied /tmp/owned-sandbox/state.db" && record.exitCode === 7)).toBe(true);
    expect(records[4]).not.toHaveProperty("message");
    expect(records[4].exitCode).toBe(7);
    expect(text).not.toContain("fixture configuration must stay private");
    const operationRecords = (await readFile(operations, "utf8")).trim().split("\n").map(line => JSON.parse(line));
    expect(operationRecords.map(record => record.operation)).toEqual(["inspect", "start", "stop", "remove", "exec"]);
    expect(operationRecords.every(record => record.status === "exit_error" && record.stderrSummary === "remove: permission denied /tmp/owned-sandbox/state.db")).toBe(true);
    expect(JSON.stringify(operationRecords)).not.toContain("fixture configuration must stay private");
  } finally { await rm(root, { recursive: true, force: true }); }
});
