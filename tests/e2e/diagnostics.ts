// Export only source-owned labels. IPC errors and process streams can contain
// credentials, so unrecognized values never cross the CI artifact boundary.
export class DiagnosticError extends Error {
  constructor(readonly category: string) { super(`IPC failed (${category})`); }
}

export function failureCategory(error: unknown): string {
  if (error instanceof DiagnosticError) return error.category;
  const text = (error instanceof Error ? error.message : typeof error === "string" ? error : "").toLowerCase();
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
  const stages = new Set("create resume suspend destroy reconnect workspace-create workspace-create-full workspace-delete workspace-list workspace-resume workspace-stop workspace-status resolve-root resolve-context resolve-build-ref verify-build-commit validate-branch validate-build-branch checkout-workspace clone-fallback orca-install orca-serve orca-server-probe orca-tunnel git-relay git-relay-management git-relay-options git-relay-recording codex-auth codex-refresh create-cleanup".split(" "));
  const statuses = new Set("adopted started succeeded skipped diagnostics-truncated success failed warning degraded stopped retry process-error exit-error connected connecting disconnected ready disabled unavailable ownership-error workspace-stopped target-removed".split(" "));
  const errors = new Set("address_in_use authentication_failed host_key_failed connection_refused connection_timeout name_resolution control_socket missing_resource permission_denied process_exit database_locked file_limit vm_boot vm_network vm_mount memory_exhausted disk_exhausted vm_image vm_create vm_start process_api readiness_unavailable progress_io backend_phase phase_limit".split(" "));
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
