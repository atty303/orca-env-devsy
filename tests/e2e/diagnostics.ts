// Export only source-owned labels. IPC errors and process streams can contain
// credentials, so unrecognized values never cross the CI artifact boundary.
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
      text.push(value.slice(0, 16_384));
      if (value.length > 16_384) truncated = true;
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
  for (const code of Object.keys(errorCodes)) if (new RegExp(`\\b${code}\\b`).test(message)) codes.add(code);
  return { message, shape: { kind: inputKind(error), fields, names: [...names], codes: [...codes], exitCodes: [...exitCodes], signals: [...signals], truncated, unreadable } };
}

export type FailureObservation = {
  category: string;
  markers: string[];
  error: ReturnType<typeof errorInformation>["shape"];
  signals: string[];
  adapterMarkers?: string[];
  recipe?: { valid: boolean; connection?: "ssh" | "orca-server" };
  boundary?: "recipe" | "native_ssh_setup" | "server_registration";
};

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
  const observation = error instanceof DiagnosticError ? error.observation : {
    category: failureCategory(error), markers: markers(message), error: information.shape,
    signals: Object.entries(errorPatterns).filter(([, phrases]) => phrases.some(phrase => message.toLowerCase().includes(phrase.toLowerCase()))).map(([signal]) => signal),
  };
  return { ...observation, ...(stderr === undefined ? {} : { adapterMarkers: markers(stderr) }), ...(recipe === undefined ? {} : { recipe, boundary: recipe.connection === "ssh" ? "native_ssh_setup" : recipe.connection === "orca-server" ? "server_registration" : "recipe" }) };

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
  const stages = new Set("create resume suspend destroy reconnect workspace-create workspace-create-full workspace-delete workspace-list workspace-resume workspace-stop workspace-status resolve-root resolve-context resolve-build-ref verify-build-commit validate-branch validate-build-branch checkout-workspace clone-fallback orca-install orca-serve orca-server-probe orca-tunnel ssh-proxy git-relay git-relay-management git-relay-options git-relay-recording codex-auth codex-refresh create-cleanup".split(" "));
  const statuses = new Set("adopted started succeeded skipped diagnostics-truncated success failed warning degraded stopped retry process-error exit-error connected connecting disconnected ready disabled pending timeout unavailable cancelled ownership-error workspace-stopped target-removed".split(" "));
  const errors = new Set("address_in_use authentication_failed host_key_failed connection_refused connection_timeout name_resolution control_socket missing_resource permission_denied process_exit database_locked file_limit vm_boot vm_network vm_mount memory_exhausted disk_exhausted vm_image vm_create vm_start process_api readiness_unavailable readiness_timeout progress_io backend_phase phase_limit".split(" "));
  const phases = new Set("cloning_repository resolving_config initialize_command preparing_devcontainer building_image starting_container injecting_agent running_lifecycle_hook waiting_for running_command configuring_workspace configuring_ssh starting_ssh_tunnel launching_ide stopping_workspace deleting_workspace rebuilding_workspace resetting_workspace importing_workspace ready failed installing_provider resolving_options running_init".split(" "));
  const events: { stage: string; status: string; run?: number; elapsedMs?: number; phase?: string; errorType?: string; exitCode?: number }[] = [];
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
      events.push({ stage: event.stage, status: event.status, ...(run === undefined ? {} : { run }), ...(Number.isFinite(elapsedMs) && Math.abs(elapsedMs) <= 86_400_000 ? { elapsedMs: Math.round(elapsedMs) } : {}), ...(phases.has(event.phase) ? { phase: event.phase } : {}), ...(errors.has(event.errorType) ? { errorType: event.errorType } : {}), ...(Number.isInteger(event.exitCode) && Math.abs(event.exitCode) <= 255 ? { exitCode: event.exitCode } : {}) });
    } catch { omitted++; }
  }
  return { available: true, omitted, truncated: events.length > 100, events: [...events.slice(0, -100).filter(event => ["failed", "exit-error", "process-error", "warning"].includes(event.status)), ...events.slice(-100)] };
}
