import { expect, test } from "bun:test";
import { DiagnosticError, failureCategory, provisionFailure } from "./diagnostics.ts";
import { OrcaObservations } from "./observations.ts";
import { classifyPodman } from "./podman.ts";
import { processFailureCategory } from "../../scripts/process.ts";

const privateValue = "private-credential-fixture";
const receipt = JSON.stringify({ schemaVersion: 1, connection: { type: "ssh", pairingCode: privateValue, projectRoot: "/private/path" }, userData: { token: privateValue } });

test("specific VM start failures take precedence over generic boot failures", () => {
  expect(processFailureCategory("failed to start vm")).toBe("vm_start");
  expect(processFailureCategory("start microsandbox vm")).toBe("vm_start");
  expect(processFailureCategory("failed to start the process")).toBe("vm_boot");
});

test("native tar upload failures retain the source-owned stage and exit code", () => {
  const observed = provisionFailure(new Error(`local tar relay upload failed (exit 1): tar: ${privateValue}: file changed as we read it`));
  expect(observed.category).toBe("tar_source_changed");
  expect(observed.signals).toContain("local_tar_upload_failed");
  expect(observed.error.exitCodes).toEqual([1]);
  expect(observed.signals).not.toContain("tar_directory_changed");
  const directory = provisionFailure(new Error("local tar relay upload failed (exit 1): tar: .: file changed as we read it"));
  expect(directory.category).toBe("tar_directory_changed");
  expect(directory.signals).toContain("tar_source_changed");
  expect(JSON.stringify(observed)).not.toContain(privateValue);
  expect(provisionFailure("local tar relay upload failed (exit 999): " + privateValue).error.exitCodes).toEqual([]);
});

test("OCI failure classification retains only fixed operation and errno labels", () => {
  const observed = classifyPodman(`Error: OCI runtime error: crun: sethostname ${privateValue}: Invalid argument`);
  expect(observed.runtimeOperations).toEqual(["sethostname"]);
  expect(observed.runtimeErrors).toEqual(["invalid argument"]);
  expect(JSON.stringify(observed)).not.toContain(privateValue);
  expect(classifyPodman(privateValue).runtimeOperations).toEqual([]);
  expect(classifyPodman("crun: setrlimit `RLIMIT_NOFILE`: Invalid argument").runtimeOperations).toEqual(["setrlimit", "rlimit_nofile"]);
  expect(classifyPodman("crun: open executable: Invalid argument").runtimeOperations).toEqual(["open executable", "open"]);
  const labelWrite = classifyPodman(`crun: write file \`/proc/thread-self/attr/exec\`: Invalid argument ${privateValue}`);
  expect(labelWrite.runtimeTargets).toEqual(["/proc/thread-self/attr/"]);
  expect(labelWrite.bareWrite).toBe(false);
  expect(classifyPodman("crun: write: Invalid argument").bareWrite).toBe(true);
  expect(JSON.stringify(labelWrite)).not.toContain(privateValue);
});

test("causal IPC error codes and post-recipe boundary survive wrapping without raw values", () => {
  const error = { message: privateValue, cause: { name: "OrcadInstanceLockError", code: "orcad_instance_lock_held", message: privateValue, exitCode: 42, signal: "SIGTERM" }, token: privateValue };
  const observation = provisionFailure(new DiagnosticError(error), privateValue, receipt);
  expect(observation.category).toBe("managed_lock");
  expect(observation.error.codes).toEqual(["orcad_instance_lock_held"]);
  expect(observation.error.names).toEqual(["OrcadInstanceLockError"]);
  expect(observation.error.exitCodes).toEqual([42]);
  expect(observation.error.signals).toEqual(["SIGTERM"]);
  expect(observation.error.fields).toContainEqual({ path: "cause.code", kind: "string" });
  expect(observation.boundary).toBe("native_ssh_setup");
  expect(observation.recipe).toEqual({ valid: true, connection: "ssh" });
  expect(JSON.stringify(observation)).not.toContain(privateValue);
  expect(JSON.stringify(observation)).not.toContain("/private/path");
  expect(failureCategory("read EPIPE " + privateValue)).toBe("broken_pipe");
});

test("Orca generic setup error is distinguished from a missing or non-string error", () => {
  const setup = provisionFailure("Orca couldn’t start its server on this host. Try connecting again.");
  expect(setup.category).toBe("managed_setup_failed");
  expect(setup.signals).toContain("managed_setup_failed");
  expect(provisionFailure(undefined).error.kind).toBe("undefined");
  expect(provisionFailure({ message: privateValue }).error.fields).toEqual([{ path: "message", kind: "string" }]);
  expect(provisionFailure(privateValue, undefined, privateValue).boundary).toBe("recipe");
});

test("cyclic or unreadable errors are bounded and marked incomplete", () => {
  const error: Record<string, unknown> = { message: "x".repeat(20_000), code: privateValue };
  error.cause = error;
  Object.defineProperty(error, "reason", { get() { throw new Error(privateValue); } });
  const observed = provisionFailure(error);
  expect(observed.error.truncated).toBe(true);
  expect(observed.error.unreadable).toBe(true);
  expect(observed.error.codes).toEqual([]);
  expect(JSON.stringify(observed)).not.toContain(privateValue);
});

test("workspace progress and native console cause are retained across chunk boundaries", async () => {
  const observed = new OrcaObservations();
  observed.begin(0);
  observed.provision({ provisionId: "provision-0", stream: "stderr", chunk: "12:00:00 create: run" });
  observed.provision({ provisionId: "provision-0", stream: "stderr", chunk: "ning…\n" + privateValue + "\n12:00:01 create: done (1.0s)\n" });
  observed.provision({ provisionId: "provision-0", stream: "stdout", chunk: receipt });
  observed.console("[ssh] Managed Orca server setup failed; using the relay this session:", { message: privateValue, code: "orcad_candidate_preflight_failed" });
  observed.finish(0, { ok: false, error: "Orca couldn’t start its server on this host.", stderr: privateValue, stdout: receipt });
  const report = await observed.snapshot();
  expect(report.completeness).toBe("complete");
  expect(report.events.map(event => event.status)).toEqual(["running", "done", "failed", "failed"]);
  expect(report.events[2].activeWorkspaces).toEqual([0]);
  expect(report.events[2].error?.category).toBe("managed_preflight");
  expect(report.events[3].error?.boundary).toBe("native_ssh_setup");
  expect(JSON.stringify(report)).not.toContain(privateValue);
});

test("opt-out, capacity loss and reader failure do not affect the result contract", async () => {
  const disabled = new OrcaObservations(false);
  disabled.begin(0);
  disabled.provision({ provisionId: "provision-0", stream: "stderr", chunk: "create: failed\n" });
  disabled.finish(0, { ok: false, error: privateValue });
  expect((await disabled.snapshot()).events).toEqual([]);
  const observed = new OrcaObservations();
  observed.console("[ssh] Managed Orca server setup failed", new Error("read EPIPE"));
  for (let i = 0; i < 300; i++) observed.provision({ provisionId: "provision-0", stream: "stderr", chunk: "create: done\n" });
  observed.capture(async () => { throw new Error(privateValue); });
  const report = await observed.snapshot();
  expect(report.events).toHaveLength(256);
  expect(report.events.some(event => event.error?.category === "broken_pipe")).toBe(true);
  expect(report.dropped).toBeGreaterThan(0);
  expect(report.degraded).toBe(1);
  expect(report.completeness).toBe("partial");
  expect(JSON.stringify(report)).not.toContain(privateValue);
});


test("async console reads retain the originating workspace and ordering", async () => {
  const observed = new OrcaObservations();
  const deferred = Promise.withResolvers<unknown>();
  observed.begin(0);
  observed.captureConsole("[ssh] Managed Orca server setup failed", () => deferred.promise);
  observed.finish(0, { ok: false, error: "Orca couldn’t start its server on this host.", stdout: receipt });
  deferred.resolve({ code: "EPIPE" });
  const report = await observed.snapshot();
  expect(report.events.map(event => event.source)).toEqual(["console", "result"]);
  expect(report.events[0].activeWorkspaces).toEqual([0]);
  expect(report.events[0].error?.category).toBe("broken_pipe");
  expect(report.completeness).toBe("complete");
});

test("native SSH gate runs adapter creation before release and defers only its receipt", async () => {
  const { mkdtemp, writeFile, rm } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join, resolve } = await import("node:path");
  const root = await mkdtemp(join(tmpdir(), "orca-native-gate-"));
  try {
    const adapter = root + "/adapter";
    await writeFile(adapter, `#!/bin/sh\nprintf started > '${root}/started'\nwhile test ! -f '${root}/created'; do sleep 0.01; done\nprintf '${receipt.replaceAll("'", "'\\''")}\\n'\n`, { mode: 0o700 });
    const entry = root + "/entry.ts", release = root + "/release";
    await writeFile(entry, `import { deferSshReceipt } from ${JSON.stringify(resolve("tests/e2e/native-setup.ts"))}; await deferSshReceipt(${JSON.stringify(adapter)}, ${JSON.stringify(release)}, 5000);`);
    const child = Bun.spawn([process.execPath, entry], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    let output = "", progress = "";
    const stdout = (async () => { for await (const chunk of child.stdout) output += Buffer.from(chunk).toString(); })();
    const stderr = (async () => { for await (const chunk of child.stderr) progress += Buffer.from(chunk).toString(); })();
    try {
      const until = async (ready: () => Promise<boolean> | boolean) => {
        const deadline = performance.now() + 5000;
        while (!await ready()) { if (performance.now() >= deadline) throw new Error("Gate fixture deadline exceeded"); await Bun.sleep(10); }
      };
      await until(() => Bun.file(root + "/started").exists());
      expect(output).toBe("");
      await writeFile(root + "/created", "");
      await until(() => progress.includes("waiting for the first deployment"));
      expect(output).toBe("");
      await writeFile(release, "");
      expect(await child.exited).toBe(0);
      await Promise.all([stdout, stderr]);
      expect(output).toBe(receipt + "\n");
      expect(progress).not.toContain(privateValue);
    } finally { child.kill("SIGKILL"); await child.exited; }
    await writeFile(adapter, "#!/bin/sh\nprintf failure-output\nexit 7\n", { mode: 0o700 });
    await rm(release);
    const failed = Bun.spawn([process.execPath, entry], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    expect(await failed.exited).toBe(7);
    expect(await new Response(failed.stdout).text()).toBe("failure-output");
    expect(await new Response(failed.stderr).text()).toBe("");
    await writeFile(adapter, "#!/bin/sh\nprintf pending-receipt\n", { mode: 0o700 });
    const cancelled = Bun.spawn([process.execPath, entry], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    await cancelled.stderr.getReader().read();
    cancelled.kill("SIGTERM");
    expect(await cancelled.exited).toBe(143);
    expect(cancelled.signalCode).toBe("SIGTERM");
    expect(await new Response(cancelled.stdout).text()).toBe("");
  } finally { await rm(root, { recursive: true, force: true }); }
});
