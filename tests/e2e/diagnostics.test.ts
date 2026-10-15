import { expect, spyOn, test } from "bun:test";
import { DiagnosticError, failureCategory, provisionFailure, sshStartupPhases } from "./diagnostics.ts";
import { OrcaObservations } from "./observations.ts";
import { classifyPodman } from "./podman.ts";
import { processFailureCategory } from "../../scripts/process.ts";

import { targets, bufferMs, budgets, timings, measure } from "./timing.ts";

const privateValue = "private-credential-fixture";
const receipt = JSON.stringify({ schemaVersion: 1, connection: { type: "ssh", pairingCode: privateValue, projectRoot: "/private/path" }, userData: { token: privateValue } });

test("specific VM start failures take precedence over generic boot failures", () => {
  expect(processFailureCategory("failed to start vm")).toBe("vm_start");
  expect(processFailureCategory("start microsandbox vm")).toBe("vm_start");
  expect(processFailureCategory("failed to start the process")).toBe("vm_boot");
});

test("SSH host-key failures remain distinct from public-key authentication failures", () => {
  expect(processFailureCategory("Host key verification failed. " + privateValue)).toBe("ssh_host_key");
  expect(processFailureCategory("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! " + privateValue)).toBe("ssh_host_key");
  expect(processFailureCategory("Permission denied (publickey). " + privateValue)).toBe("ssh_auth");
  expect(processFailureCategory(privateValue)).toBe("process_exit");
});

test("SSH startup observation retains fixed phases from real client diagnostics", async () => {
  const child = Bun.spawn(["ssh", "-v", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ProxyCommand=false", "fixture.invalid"], { stdin: "ignore", stdout: "ignore", stderr: "pipe" });
  const stderr = await new Response(child.stderr).text();
  expect(await child.exited).not.toBe(0);
  expect(sshStartupPhases(stderr)).toContain("proxy_start");
  const phases = sshStartupPhases(`debug1: Executing proxy command: ${privateValue}\ndebug1: Remote protocol version 2.0, remote software version ${privateValue}\nAuthenticated to ${privateValue} (via proxy) using "none".\n`);
  expect(phases).toEqual(["proxy_start", "remote_identification", "authenticated"]);
  expect(JSON.stringify(phases)).not.toContain(privateValue);
  expect(sshStartupPhases(privateValue)).toEqual([]);
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

test("SSH command error categories describe output rather than embedded command text", () => {
  const observed = provisionFailure(new Error(`Command "ssh -o StrictHostKeyChecking=no ${privateValue}" failed (exit 255): /private/socket: No such file or directory`));
  expect(observed.category).toBe("missing_resource");
  expect(observed.error.exitCodes).toEqual([255]);
  expect(observed.markers).toContain("no such file");
  expect(observed.markers).not.toContain("ssh");
  expect(JSON.stringify(observed)).not.toContain(privateValue);
  expect(JSON.stringify(observed)).not.toContain("/private/socket");
  expect(provisionFailure(new Error(`Command "${privateValue}" failed (exit 255): Host key verification failed`)).category).toBe("host_key");
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
  expect(observation.boundary).toBe("ssh_setup");
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
  expect(report.events[3].error?.boundary).toBe("ssh_setup");
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

test("the guest download wrapper pins only Orca assets and preserves curl arguments and exit", async () => {
  const { mkdtemp, writeFile, readFile, rm } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const root = await mkdtemp(tmpdir() + "/orca-release-curl-");
  try {
    const delegate = root + "/curl";
    await writeFile(delegate, `#!${process.execPath}\nconsole.log(JSON.stringify(process.argv.slice(2))); process.exit(7);\n`, { mode: 0o700 });
    const script = await readFile("tests/e2e/fixture/.devcontainer/curl-orca-release", "utf8");
    await writeFile(root + "/wrapper", script.replace("exec /usr/bin/curl", `exec '${delegate}'`), { mode: 0o700 });
    const urls = ["orca-linux.AppImage", "orca-linux-arm64.AppImage"].map(name => "https://github.com/stablyai/orca/releases/latest/download/" + name);
    const args = ["--data-binary", privateValue + " with spaces", urls[0], "--output", "file with spaces", "https://example.invalid/releases/latest/download/orca-linux.AppImage", urls[1]];
    const child = Bun.spawn([root + "/wrapper", ...args], { env: { ...process.env, ORCA_E2E_VERSION: "1.4.224" }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const output = await new Response(child.stdout).text();
    expect(await child.exited).toBe(7);
    expect(JSON.parse(output)).toEqual(args.map(arg => urls.includes(arg) ? arg.replace("/latest/download/", "/download/v1.4.224/") : arg));
    expect(await new Response(child.stderr).text()).toBe("");
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("adapter process API causes retain bounded errno and fixed phases without context", async () => {
  const { adapterDiagnostics } = await import("./diagnostics.ts");
  const { mkdtemp, mkdir, writeFile, rm } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const root = await mkdtemp(join(tmpdir(), "orca-errno-"));
  try {
    await mkdir(root + "/orca-env-devsy");
    const events = [26, 0, 4096, 1.5, privateValue].map(osErrno => ({ stage: "resolve-context", status: "process-error", errorType: "process_os", phase: privateValue, osErrno, context: privateValue }));
    await writeFile(root + "/orca-env-devsy/events.jsonl", events.map(event => JSON.stringify(event)).join("\n"));
    const report = await adapterDiagnostics(root);
    expect(report.events[0]).toEqual({ stage: "resolve-context", status: "process-error", errorType: "process_os", osErrno: 26 });
    expect(report.events.slice(1).every(event => event.osErrno === undefined)).toBe(true);
    expect(JSON.stringify(report)).not.toContain(privateValue);
  } finally { await rm(root, { recursive: true, force: true }); }
});


test("E2E accepts the five-second buffer while retaining the original target", async () => {
  for (const key of Object.keys(targets) as (keyof typeof targets)[]) expect(budgets[key]).toBe(targets[key] + bufferMs);
  let now = 100;
  const clock = spyOn(performance, "now").mockImplementation(() => now);
  const first = timings.length;
  try {
    for (const elapsed of [targets.firstUse + 1, budgets.firstUse, budgets.firstUse + 1]) {
      const result = measure("buffer-boundary", budgets.firstUse, async () => { now += elapsed; });
      if (elapsed <= budgets.firstUse) await result;
      else await expect(result).rejects.toThrow("exceeded");
      expect(timings.at(-1)).toMatchObject({ targetMs: targets.firstUse, budgetMs: budgets.firstUse, elapsedMs: elapsed, ok: elapsed <= budgets.firstUse });
    }
  } finally { clock.mockRestore(); timings.splice(first); }
});


test("missing resource observations retain only the failing operation and resource kind", () => {
  const archive = provisionFailure(`ENOENT: no such file or directory, open '/private/${privateValue}.tar.gz'`);
  expect(archive.missingResource).toEqual({ operation: "open", resource: "archive" });
  const wrapped = new DiagnosticError(new Error(`ENOENT: no such file or directory, stat '/private/${privateValue}'`));
  expect(provisionFailure(wrapped).missingResource).toEqual({ operation: "stat", resource: "other" });
  expect(provisionFailure(`spawn /private/${privateValue} ENOENT`).missingResource).toEqual({ operation: "spawn", resource: "executable" });
  expect(provisionFailure(privateValue).missingResource).toBeUndefined();
  expect(JSON.stringify(archive)).not.toContain(privateValue);
  expect(JSON.stringify(archive)).not.toContain("/private/");
});
