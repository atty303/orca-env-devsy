import { expect, spyOn, test } from "bun:test";
import { orcaReleaseEndpoint } from "./orca.ts";
import { DiagnosticError, diagnosticTextSummary, failureCategory, provisionFailure, providerOperationObservation, sshStartupPhases } from "./diagnostics.ts";
import { OrcaObservations } from "./observations.ts";
import { classifyPodman, podmanExecProgram } from "./podman.ts";
import { processFailureCategory } from "../../scripts/process.ts";

import { targets, bufferMs, budgets, timings, measure } from "./timing.ts";

const privateValue = "ghp_privatecredentialfixture1234567890";
const receipt = JSON.stringify({ schemaVersion: 1, connection: { type: "ssh", pairingCode: privateValue, projectRoot: "/private/path" }, userData: { token: privateValue } });

test("Orca release override selects only a stable exact tag", () => {
  expect(orcaReleaseEndpoint()).toBe("https://api.github.com/repos/stablyai/orca/releases/latest");
  expect(orcaReleaseEndpoint("1.4.244")).toBe("https://api.github.com/repos/stablyai/orca/releases/tags/v1.4.244");
  expect(() => orcaReleaseEndpoint("latest")).toThrow("stable version");
});

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

test("provision failures retain bounded causes after masking credentials and workspace info", () => {
  const error = `Command "git clone --workspace-info ${privateValue}" failed (exit 128): clone failed: token=${privateValue}`;
  const stderr = `fatal: GitHub fetch failed; Authorization: Bearer ${privateValue}; password: "${privateValue}"; --workspace-info ${privateValue}`;
  const observed = provisionFailure(error, stderr);
  expect(observed.errorSummary).toContain("clone failed");
  expect(observed.error.exitCodes).toEqual([128]);
  expect(observed.adapterSummary).toContain("GitHub fetch failed");
  expect(observed.adapterSummary).toContain("password:");
  expect(observed.adapterSummary).toContain("--workspace-info [redacted]");
  expect(JSON.stringify(observed)).not.toContain(privateValue);
  expect(observed.errorSummaryTruncated).toBe(false);
  expect(observed.adapterSummaryTruncated).toBe(false);
  const unknownOutput = provisionFailure("Recipe exited with code 1", "provider returned an unclassified cause");
  expect(unknownOutput.adapterMarkers).toEqual([]);
  expect(unknownOutput.adapterSummary).toContain("provider returned an unclassified cause");
  const context = "x".repeat(4096) + "GitHub API returned 403\n" + "cleanup\n".repeat(2000);
  const contextual = provisionFailure("Recipe exited with code 1", context);
  expect(contextual.adapterMarkers).toContain("403");
  expect(contextual.adapterSummary).toContain("GitHub API returned 403");
  expect(contextual.adapterSummary?.length).toBe(16_384);
  expect(contextual.adapterSummaryTruncated).toBe(true);
  const recipeOutput = provisionFailure("Recipe exited with code 1", undefined, `GitHub API returned 403; token=${privateValue}; --workspace-info ${privateValue}`);
  expect(recipeOutput.recipeOutputSummary).toContain("GitHub API returned 403");
  expect(recipeOutput.recipeOutputSummary).toContain("token=[redacted]");
  expect(recipeOutput.recipeOutputSummary).toContain("--workspace-info [redacted]");
  expect(JSON.stringify(recipeOutput)).not.toContain(privateValue);
  expect(recipeOutput.recipeOutputSummaryTruncated).toBe(false);
  const objectError = provisionFailure(new Error(`Command failed (exit 128): AWS_SECRET_ACCESS_KEY=${privateValue}`));
  expect(objectError.errorSummary).toContain("Command failed");
  expect(objectError.errorSummary).toContain("AWS_SECRET_ACCESS_KEY=[redacted]");
  expect(JSON.stringify(objectError)).not.toContain(privateValue);
  const aws = provisionFailure("provider failed (exit 1): AWS_SECRET_ACCESS_KEY=fixture_secret; AWS_SESSION_TOKEN=fixture_token");
  expect(aws.errorSummary).not.toContain("fixture_secret");
  expect(aws.errorSummary).not.toContain("fixture_token");
  const long = provisionFailure("x".repeat(4096));
  expect(long.errorSummary?.length).toBe(2048);
  expect(long.errorSummaryTruncated).toBe(true);
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
  observed.finish(0, { ok: false, error: "Orca couldn’t start its server on this host.", stdout: receipt });
  observed.provision({ provisionId: "provision-0", stream: "stderr", chunk: `provider command failed (exit 128): clone failed; token=${privateValue}\n` });
  const report = await observed.snapshot();
  expect(report.completeness).toBe("complete");
  expect(report.events.map(event => event.status)).toEqual(["running", "done", "failed", "failed"]);
  expect(report.events[2].activeWorkspaces).toEqual([0]);
  expect(report.events[2].error?.category).toBe("managed_preflight");
  expect(report.events[3].error?.boundary).toBe("ssh_setup");
  expect(report.events[3].error?.adapterSummary).toContain("clone failed");
  expect(report.events[3].error?.adapterSummary).toContain("token=[redacted]");
  expect(report.events[3].error?.adapterStreamBytes).toBeGreaterThan(0);
  expect(report.events[3].error?.adapterStreamTruncated).toBe(false);
  expect(JSON.stringify(report)).not.toContain(privateValue);
});

test("renderer errors during provisioning are retained with bounded redaction", async () => {
  const observed = new OrcaObservations();
  observed.console("unrelated renderer error", new Error("outside provision"), "error");
  observed.begin(1);
  observed.captureConsole("build failed while pulling base image", async () => new Error(`request failed: token=${privateValue}`), "error");
  observed.finish(1, { ok: false, error: "Recipe exited with code 1." });
  const report = await observed.snapshot();
  expect(report.events).toHaveLength(2);
  expect(report.events[0]).toMatchObject({ source: "console", activeWorkspaces: [1], stage: "renderer-error", status: "observed" });
  expect(report.events[0].error?.errorSummary).toContain("request failed: token=[redacted]");
  expect(report.events[0].error?.errorSummary?.length).toBeLessThanOrEqual(2048);
  expect(JSON.stringify(report)).not.toContain(privateValue);
});

test("provision stderr recording retains a bounded tail and exposes truncation", async () => {
  const observed = new OrcaObservations();
  observed.begin(0);
  const cause = "x".repeat(20_000) + "\nprovider command failed (exit 128).";
  observed.provision({ provisionId: "provision-0", stream: "stderr", chunk: cause });
  observed.finish(0, { ok: false, error: "Recipe exited with code 1." });
  const report = await observed.snapshot();
  const error = report.events[0].error!;
  expect(error.adapterStreamBytes).toBe(Buffer.byteLength(cause));
  expect(error.adapterStreamTruncated).toBe(true);
  expect(error.adapterSummary?.length).toBe(16_384);
  expect(error.adapterSummaryTruncated).toBe(false);
});

test("provision stream metadata is independent from result stderr", async () => {
  const observed = new OrcaObservations();
  observed.begin(0);
  observed.provision({ provisionId: "provision-0", stream: "stderr", chunk: "x".repeat(17_000) });
  observed.finish(0, { ok: false, error: "Recipe exited with code 1.", stderr: "different result stderr" });
  const report = await observed.snapshot();
  const error = report.events[0].error!;
  expect(error.adapterSummary).toBe("different result stderr");
  expect(error.adapterStreamBytes).toBe(17_000);
  expect(error.adapterStreamTruncated).toBe(true);
});

test("empty result stderr does not hide streamed provision failure output", async () => {
  const observed = new OrcaObservations();
  observed.begin(0);
  observed.provision({ provisionId: "provision-0", stream: "stderr", chunk: "provider clone failed: remote closed the connection" });
  observed.finish(0, { ok: false, error: "Recipe exited with code 1.", stderr: "" });
  const report = await observed.snapshot();
  expect(report.events[0].error?.adapterSummary).toContain("remote closed the connection");
  expect(report.events[0].error?.adapterStreamBytes).toBeGreaterThan(0);
});

test("provision stderr removes a private key block before bounding the retained tail", async () => {
  const observed = new OrcaObservations();
  observed.begin(0);
  const keyType = ["OPENSSH", "PRIVATE", "KEY"].join(" ");
  const marker = "-----" + ["BEGIN", keyType].join(" ") + "-----\n";
  const body = "NOT_BASE64_SECRET_CONTENT\n".repeat(900);
  const end = "-----" + ["END", keyType].join(" ") + "-----\n";
  const cause = marker + body + end + "provider command failed (exit 128).";
  observed.provision({ provisionId: "provision-0", stream: "stderr", chunk: marker.slice(0, 17) });
  observed.provision({ provisionId: "provision-0", stream: "stderr", chunk: cause.slice(17) });
  observed.finish(0, { ok: false, error: "Recipe exited with code 1." });
  const report = await observed.snapshot();
  const error = report.events[0].error!;
  expect(error.adapterSummary).toContain("[private key redacted]");
  expect(error.adapterSummary).toContain("provider command failed");
  expect(error.adapterSummary).not.toContain("NOT_BASE64_SECRET_CONTENT");
  expect(error.adapterStreamBytes).toBe(Buffer.byteLength(cause));
  expect(error.adapterStreamTruncated).toBe(true);
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
    const relay = { stage: "relay-probe", status: "failed", errorType: "transport_error", phase: "readiness", exitCode: 79, errorMessage: "readiness connection refused" };
    const codex = ["refresh", "deliver", "pipe", "spawn", "write", "wait"].map(phase => ({ stage: "codex-auth", status: "warning", phase, errorMessage: "operation timed out" }));
    await writeFile(root + "/orca-env-devsy/events.jsonl", [...events, relay, ...codex].map(event => JSON.stringify(event)).join("\n"));
    const report = await adapterDiagnostics(root);
    expect(report.events[0]).toEqual({ stage: "resolve-context", status: "process-error", errorType: "process_os", osErrno: 26 });
    expect(report.events.slice(1).every(event => event.osErrno === undefined)).toBe(true);
    expect(report.events.at(-codex.length - 1)).toEqual(relay);
    expect(report.events.slice(-codex.length)).toEqual(codex);
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


test("missing resource diagnostics retain filenames and paths without unrelated identity or URL credentials", () => {
  const archive = provisionFailure("ENOENT: no such file or directory, open '/tmp/orca/cache/node-linux-arm64.tar.gz'");
  expect(archive.missingResource).toEqual({ operation: "open", path: "/tmp/orca/cache/node-linux-arm64.tar.gz", resource: "archive" });
  const wrapped = new DiagnosticError(new Error("ENOENT: no such file or directory, stat '/home/fixture-user/cache/relay.js'"));
  expect(provisionFailure(wrapped).missingResource).toEqual({ operation: "stat", path: "~/cache/relay.js", resource: "other" });
  expect(provisionFailure("spawn /usr/bin/ssh ENOENT").missingResource).toEqual({ operation: "spawn", path: "/usr/bin/ssh", resource: "executable" });
  expect(provisionFailure("spawn C:\\Users\\fixture-user\\bin\\ssh.exe ENOENT").missingResource?.path).toBe("~\\bin\\ssh.exe");
  const credential = provisionFailure(`ENOENT: no such file or directory, open 'https://user:${privateValue}@fixture.invalid/file?token=${privateValue}'`);
  expect(credential.missingResource?.path).toBe("[url]");
  expect(JSON.stringify(credential)).not.toContain(privateValue);
  expect(JSON.stringify(provisionFailure(wrapped))).not.toContain("fixture-user");
  expect(provisionFailure(privateValue).missingResource).toBeUndefined();
});

test("provider operation records distinguish slow success from failure and redact only identified secrets", () => {
  expect(providerOperationObservation("inspect", 29_999, 0, "")).toBeUndefined();
  expect(providerOperationObservation("run", 30_001, 0, "")).toMatchObject({ status: "success", slow: true, elapsedMs: 30_001 });
  const slowSuccess = providerOperationObservation("exec", 611_000, 0, `slow operation token=${privateValue}`);
  expect(slowSuccess).toMatchObject({ status: "success", slow: true, stderrSummary: "slow operation token=[redacted]", stderrSummaryTruncated: false });
  expect(JSON.stringify(slowSuccess)).not.toContain(privateValue);
  const failed = providerOperationObservation("run", 12, 1, `container failed; GITHUB_TOKEN=${privateValue}; retry the build`);
  expect(failed).toMatchObject({ status: "exit_error", exitCode: 1, stderrSummary: `container failed; GITHUB_TOKEN=[redacted]; retry the build`, stderrSummaryTruncated: false });
  expect(JSON.stringify(failed)).not.toContain(privateValue);
  const summary = diagnosticTextSummary("cause: " + "x".repeat(3000), 2048);
  expect(summary).toMatchObject({ truncated: true });
  expect(summary.text).toHaveLength(2048);
});

test("Podman exec observations retain only an allowlisted executable name", () => {
  expect(podmanExecProgram(["exec", "--user", "root", "container", "/bin/sh", "-c", "private command"])).toBe("sh");
  expect(podmanExecProgram(["exec", "--latest", "custom-secret-name", "argument"])).toBe("other");
  expect(podmanExecProgram(["run", "image"])).toBeUndefined();
});


test("missing resource paths preserve embedded quotes from filesystem errors", async () => {
  const { mkdtemp, readFile, rm } = await import("node:fs/promises");
  const root = await mkdtemp("/tmp/orca-resource-path-");
  try {
    for (const name of ["owner's-relay.js", 'a"b.js']) {
      const path = root + "/" + name;
      const error = await readFile(path).then(() => { throw new Error("Expected missing fixture file"); }, error => error);
      expect(provisionFailure(error).missingResource).toMatchObject({ operation: "open", path });
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
