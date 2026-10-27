// IPC errors and process streams may contain credentials. Export classified
// fields, including filesystem paths needed to locate a missing resource.
export class DiagnosticError extends Error {
  readonly category: string;
  readonly markers: string[];
  readonly observation: FailureObservation;
  constructor(error: unknown) {
    const observation = provisionFailure(error);
    super(`IPC failed (${observation.category})`);
    this.observation = observation;
    this.category = observation.category;
    this.markers = observation.markers;
  }
}

const errorCodes = {
  ENOTCONN: "connection_closed", ECONNABORTED: "connection_reset", EHOSTUNREACH: "network_unreachable", ENETUNREACH: "network_unreachable", EPIPE: "broken_pipe", ECONNRESET: "connection_reset", ECONNREFUSED: "refused", ETIMEDOUT: "timeout",
  ENOENT: "missing_resource", EACCES: "permission", EPERM: "permission", ENOSPC: "disk", ENOMEM: "memory",
  orcad_candidate_launch_failed: "managed_launch", orcad_candidate_preflight_failed: "managed_preflight",
  orcad_activation_pty_self_test_failed: "managed_preflight", ssh_tunnel_unavailable: "managed_tunnel",
  orcad_instance_lock_held: "managed_lock", orcad_instance_lock_foreign_identity: "managed_lock",
  orcad_instance_lock_unreadable: "managed_lock", orcad_data_root_shared: "managed_data_root",
  orcad_data_root_unusable: "managed_data_root", orcad_data_root_wrong_owner: "managed_data_root",
} as const;
const errorNames = new Set(["Error", "TypeError", "RangeError", "OrcadInstanceLockError", "OrcadHostUnsupportedError", "OrcadArtifactsUnavailableError", "OrcadRemoteLaunchUnsupportedError", "UnidentifiedHostLibcError", "RemoteNodeRuntimeSelfTestError", "RemoteNodeRuntimeSecurityModifiedError", "OrcadStdioBridgeUnavailableError"]);
const errorFields = ["message", "name", "code", "exitCode", "signal", "reason", "error", "cause"] as const;
const errorSignals = new Set(["SIGHUP", "SIGINT", "SIGTERM", "SIGKILL", "SIGABRT", "SIGSEGV", "SIGPIPE"]);
const errorPatterns = {
  tar_directory_changed: ["tar: .: file changed as we read it", "tar: ./: file changed as we read it"],
  tar_source_changed: ["file changed as we read it", "file removed before we read it", "file shrank by"],
  local_tar_upload_failed: ["local tar relay upload failed"],
  managed_setup_failed: ["Orca couldn’t start its server on this host", "Managed Orca server setup failed"],
  managed_setup_deferred: ["Managed Orca server setup deferred"],
  managed_unavailable: ["This SSH host isn’t supported by this version of Orca"],
  ssh_target_unconnected: ["SSH target did not connect"],
  ssh_handlers_unregistered: ["SSH handlers are not registered", "ssh_handlers_not_registered"],
  channel_closed: ["channel closed without exit status", "premature close"],
  sftp: ["sftp", "subsystem request failed"],
} as const;

function inputKind(value: unknown): string {
  return value === null ? "null" : value instanceof Error ? "error" : Array.isArray(value) ? "array" : typeof value;
}

function errorInformation(error: unknown) {
  const text: string[] = [], codes = new Set<string>(), names = new Set<string>(), exitCodes = new Set<number>(), signals = new Set<string>();
  const fields: { path: string; kind: string }[] = [];
  const seen = new Set<object>();
  let truncated = false, unreadable = false;
  const visit = (value: unknown, path: string, depth: number) => {
    if (fields.length >= 32 || text.length >= 16) { truncated = true; return; }
    if (typeof value === "string") {
      // Orca's sshCommandExitError embeds the command before the actual output.
      // Options and script text describe what was attempted, not why it failed.
      const commandExit = /^Command "[\s\S]*" failed \(exit (\d{1,3})\): ([\s\S]*)$/.exec(value);
      const output = commandExit?.[2] ?? value;
      if (commandExit && Number(commandExit[1]) <= 255) exitCodes.add(Number(commandExit[1]));
      text.push(output.slice(0, 16_384));
      if (output.length > 16_384) truncated = true;
      return;
    }
    if (!value || typeof value !== "object") return;
    if (seen.has(value)) { truncated = true; return; }
    seen.add(value);
    if (depth >= 4) { truncated = true; return; }
    for (const key of errorFields) {
      if (fields.length >= 32) { truncated = true; break; }
      try {
        if (!(key in value)) continue;
        const field = (value as Record<string, unknown>)[key];
        fields.push({ path: path + key, kind: inputKind(field) });
        if (key === "code" && typeof field === "string" && Object.hasOwn(errorCodes, field)) codes.add(field);
        if (key === "name" && typeof field === "string" && errorNames.has(field)) names.add(field);
        if ((key === "code" || key === "exitCode") && typeof field === "number" && Number.isInteger(field) && Math.abs(field) <= 255) exitCodes.add(field);
        if (key === "signal" && typeof field === "string" && errorSignals.has(field)) signals.add(field);
        if (key !== "name" && key !== "code") visit(field, path + key + ".", depth + 1);
      } catch { unreadable = true; }
    }
  };
  visit(error, "", 0);
  const message = text.join("\n");
  for (const match of message.matchAll(/\bfailed \(exit (\d{1,3})\)/g)) {
    const code = Number(match[1]);
    if (code <= 255) exitCodes.add(code);
  }
  for (const code of Object.keys(errorCodes)) if (new RegExp(`\\b${code}\\b`).test(message)) codes.add(code);
  return { message, shape: { kind: inputKind(error), fields, names: [...names], codes: [...codes], exitCodes: [...exitCodes], signals: [...signals], truncated, unreadable } };
}

export type FailureObservation = {
  category: string;
  markers: string[];
  error: ReturnType<typeof errorInformation>["shape"];
  signals: string[];
  missingResource?: { operation: string; path: string; resource: "archive" | "executable" | "other" };
  adapterMarkers?: string[];
  recipe?: { valid: boolean; connection?: "ssh" | "orca-server" };
  boundary?: "recipe" | "ssh_setup" | "server_registration";
};

export function sshStartupPhases(stderr: string) {
  const phases = {
    proxy_start: "debug1: Executing proxy command:",
    local_identification: "debug1: Local version string ",
    remote_identification: "debug1: Remote protocol version ",
    kex_sent: "debug1: SSH2_MSG_KEXINIT sent",
    kex_received: "debug1: SSH2_MSG_KEXINIT received",
    keys_received: "debug1: SSH2_MSG_NEWKEYS received",
    key_offered: "debug1: Offering public key:",
    authenticated: "Authenticated to ",
    session_entered: "debug1: Entering interactive session.",
  };
  return Object.entries(phases).filter(([, marker]) => stderr.includes(marker)).map(([phase]) => phase);
}

export function failureCategory(error: unknown): string {
  if (error instanceof DiagnosticError) return error.category;
  const information = errorInformation(error);
  const code = information.shape.codes[0] as keyof typeof errorCodes | undefined;
  if (code) return errorCodes[code];
  const text = information.message.toLowerCase();
  for (const [category, phrases] of Object.entries(errorPatterns)) if (phrases.some(phrase => text.includes(phrase.toLowerCase()))) return category;
  for (const [category, phrases] of Object.entries({
    memory: ["out of memory", "cannot allocate memory", "memory allocation", "not enough memory"],
    disk: ["no space left on device"],
    vm_start: ["start microsandbox vm", "failed to start vm"],
    vm_create: ["create microsandbox vm"],
    vm_image: ["ensure microsandbox final image", "prepare microsandbox final image"],
    vm_volume: ["prepare microsandbox volumes"],
    build: ["failed to build", "failed to solve", "build failed"],
    vm_runtime: ["libkrun", "kvm", "vmm"],
    host_key: ["host key verification", "host key is unknown", "hostkey"],
    authentication: ["authentication failed", "authentication methods failed", "permission denied (publickey"],
    refused: ["connection refused", "econnrefused"],
    timeout: ["timed out", "timeout", "deadline"],
    ssh_providers: ["ssh relay providers were not ready"],
    missing_resource: ["no such file", "not found", "enoent"],
    permission: ["permission denied", "eacces"],
    recipe_exit: ["exited with", "exit code", "non-zero"],
    schema: ["invalid recipe", "invalid connection", "validation", "schema"],
  })) if (phrases.some(phrase => text.includes(phrase))) return category;
  return "unclassified";
}

export function provisionFailure(error: unknown, stderr?: string, stdout?: string): FailureObservation {
  const information = errorInformation(error);
  const message = information.message;
  const labels = ["ssh", "managed", "orcad", "registration", "generation", "profile", "preflight", "candidate", "bootstrap", "install", "deploy", "launch", "release", "download", "github", "rate limit", "rate_limited", "rate-limit", "429", "403", "fetch", "network", "connection", "socket", "closed", "reset", "handshake", "authentication", "channel", "exec", "exit", "signal", "killed", "memory", "certificate", "checksum", "sqlite", "database", "timeout", "unverifiable", "not connected", "not found", "no such file", "permission", "address", "already", "port", "stale", "pending"];
  const markers = (text: string) => {
    const lower = text.slice(-16_384).toLowerCase();
    return labels.filter(label => lower.includes(label));
  };
  let recipe: FailureObservation["recipe"];
  if (stdout !== undefined) {
    recipe = { valid: false };
    if (stdout.length <= 65_536) try {
      const result = JSON.parse(stdout);
      if ([1, 2].includes(result?.schemaVersion) && ["ssh", "orca-server"].includes(result?.connection?.type)) recipe = { valid: true, connection: result.connection.type };
    } catch { /* A failed recipe need not produce JSON. */ }
  }
  const missing = /\bENOENT: no such file or directory, (open|stat|lstat|scandir|unlink|rename|access) (['"])([^\r\n]*)\2$/m.exec(message);
  const spawn = /^spawn ([^\r\n]+) ENOENT$/m.exec(message);
  const missingPath = missing?.[3] ?? spawn?.[1];
  const path = missingPath?.replace(/\/(?:Users|home)\/[^/]+(?=\/|$)/g, "~").replace(/[A-Za-z]:\\Users\\[^\\]+(?=\\|$)/gi, "~");
  const diagnosticPath = path === undefined ? undefined : /^[a-z][a-z0-9+.-]*:\/\//i.test(path) ? "[url]" : path.slice(-4096);
  const missingResource: FailureObservation["missingResource"] = missing && diagnosticPath !== undefined ? {
    operation: missing[1], path: diagnosticPath, resource: /\.(?:tar(?:\.(?:gz|xz|zst))?|zip)$/.test(missing[3]) ? "archive" : "other",
  } : spawn && diagnosticPath !== undefined ? { operation: "spawn", path: diagnosticPath, resource: "executable" } : undefined;
  const observation = error instanceof DiagnosticError ? error.observation : {
    category: failureCategory(error), markers: markers(message), error: information.shape,
    ...(missingResource === undefined ? {} : { missingResource }),
    signals: Object.entries(errorPatterns).filter(([, phrases]) => phrases.some(phrase => message.toLowerCase().includes(phrase.toLowerCase()))).map(([signal]) => signal),
  };
  return { ...observation, ...(stderr === undefined ? {} : { adapterMarkers: markers(stderr) }), ...(recipe === undefined ? {} : { recipe, boundary: recipe.connection === "ssh" ? "ssh_setup" : recipe.connection === "orca-server" ? "server_registration" : "recipe" }) };

}

const runOrdinals = new Map<string, number>();
export function diagnosticRun(id: unknown): number | undefined {
  if (typeof id !== "string" || id.length > 64) return undefined;
  if (!runOrdinals.has(id)) runOrdinals.set(id, runOrdinals.size);
  return runOrdinals.get(id);
}

export async function adapterDiagnostics(state: string) {
  const file = Bun.file(state + "/orca-env-devsy/events.jsonl");
  if (!await file.exists()) return { available: false, events: [] };
  if (file.size > 300_000) return { available: false, oversized: true, events: [] };
  const stages = new Set("supervisor-registration supervisor supervisor-launch supervisor-workspace supervisor-transport idle-configuration idle-observation idle-reset idle-connection idle-stop idle-monitor bulk bulk-context bulk-observation bulk-workspace create resume suspend destroy recover restart recover-workspace recover-worker recover-server workspace-create workspace-create-full workspace-delete workspace-list workspace-resume workspace-stop workspace-status resolve-root resolve-context resolve-build-ref resolve-default-branch clone-shallow clone-full clone-override git-object-storage verify-build-source verify-build-commit task-commit-presence validate-branch validate-build-branch checkout-workspace clone-fallback orca-install orca-serve orca-server-probe orca-tunnel ssh-proxy relay-probe relay-recovery connection-readiness ssh-tunnel-restart git-relay git-relay-options git-relay-recording codex-auth codex-refresh create-cleanup".split(" "));
  const statuses = new Set("stop_failed selected monitoring observation_unknown awaiting_idle_confirmation observer_reconnecting tunnel_reconnecting workspace_stopped workspace_resumed Running Stopped Busy NotFound reuse reused restore restart start adopted started succeeded skipped diagnostics-truncated success failed warning degraded stopped retry process-error exit-error connected connecting disconnected ready checking unsupported disabled pending timeout unavailable cancelled ownership-error workspace-stopped target-removed".split(" "));
  const errors = new Set("registration_failed workspace_registration_failed workspace_task_failed transport_cleanup_failed restart_failed process_signal observer_unavailable monitor_failed timer_unavailable workspace_stop_failed address_in_use authentication_failed host_key_failed connection_refused connection_timeout name_resolution control_socket missing_resource permission_denied process_exit database_locked file_limit vm_boot vm_network vm_mount memory_exhausted disk_exhausted vm_image vm_create vm_start process_api process_os process_utf8 readiness_unavailable readiness_timeout readiness_unsupported http_timeout http_error http_503 ssh_timeout transport_error owner_mismatch schema_invalid git_helper_unavailable progress_io backend_phase phase_limit".split(" "));
  const phases = new Set("read cloning_repository resolving_config initialize_command preparing_devcontainer building_image starting_container injecting_agent running_lifecycle_hook waiting_for running_command configuring_workspace configuring_ssh starting_ssh_tunnel launching_ide stopping_workspace deleting_workspace rebuilding_workspace resetting_workspace importing_workspace ready failed installing_provider resolving_options running_init".split(" "));
  const events: { stage: string; status: string; run?: number; elapsedMs?: number; phase?: string; errorType?: string; exitCode?: number; osErrno?: number }[] = [];
  let origin: number | undefined;
  let omitted = 0;
  for (const line of (await file.text()).split("\n").filter(Boolean)) {
    try {
      const event = JSON.parse(line);
      if (!stages.has(event.stage) || !statuses.has(event.status)) { omitted++; continue; }
      const run = diagnosticRun(event.runId);
      const time = typeof event.time === "string" ? Number(event.time) : NaN;
      if (Number.isFinite(time) && origin === undefined) origin = time;
      const elapsedMs = origin === undefined ? NaN : time - origin;
      events.push({ stage: event.stage, status: event.status, ...(run === undefined ? {} : { run }), ...(Number.isFinite(elapsedMs) && Math.abs(elapsedMs) <= 86_400_000 ? { elapsedMs: Math.round(elapsedMs) } : {}), ...(phases.has(event.phase) ? { phase: event.phase } : {}), ...(errors.has(event.errorType) ? { errorType: event.errorType } : {}), ...(Number.isInteger(event.osErrno) && event.osErrno > 0 && event.osErrno < 4096 ? { osErrno: event.osErrno } : {}), ...(Number.isInteger(event.exitCode) && Math.abs(event.exitCode) <= 255 ? { exitCode: event.exitCode } : {}) });
    } catch { omitted++; }
  }
  return { available: true, omitted, truncated: events.length > 100, events: [...events.slice(0, -100).filter(event => ["failed", "exit-error", "process-error", "warning"].includes(event.status)), ...events.slice(-100)] };
}
