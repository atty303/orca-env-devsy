// Export only source-owned labels. IPC errors and process streams can contain
// credentials, so unrecognized values never cross the CI artifact boundary.
export class DiagnosticError extends Error {
  constructor(readonly category: string) { super(`IPC failed (${category})`); }
}

export function failureCategory(error: unknown): string {
  if (error instanceof DiagnosticError) return error.category;
  const text = (error instanceof Error ? error.message : typeof error === "string" ? error : "").toLowerCase();
  for (const [category, phrases] of Object.entries({
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

export async function adapterDiagnostics(state: string) {
  const file = Bun.file(state + "/orca-env-devsy/events.jsonl");
  if (!await file.exists()) return { available: false, events: [] };
  if (file.size > 300_000) return { available: false, oversized: true, events: [] };
  const stages = new Set("create resume suspend destroy reconnect workspace-create workspace-create-full workspace-delete workspace-list workspace-resume workspace-stop workspace-status resolve-root resolve-context resolve-build-ref verify-build-commit validate-branch validate-build-branch checkout-workspace clone-fallback orca-install orca-serve orca-server-probe orca-tunnel git-relay git-relay-management git-relay-options git-relay-recording codex-auth codex-refresh create-cleanup".split(" "));
  const statuses = new Set("started success failed warning degraded stopped retry process-error exit-error connected connecting disconnected ready disabled unavailable ownership-error workspace-stopped target-removed".split(" "));
  const errors = new Set("address_in_use authentication_failed host_key_failed connection_refused connection_timeout name_resolution control_socket missing_resource permission_denied process_exit process_api readiness_unavailable progress_io".split(" "));
  const events: { stage: string; status: string; errorType?: string; exitCode?: number }[] = [];
  let omitted = 0;
  for (const line of (await file.text()).split("\n").filter(Boolean)) {
    try {
      const event = JSON.parse(line);
      if (!stages.has(event.stage) || !statuses.has(event.status)) { omitted++; continue; }
      events.push({ stage: event.stage, status: event.status, ...(errors.has(event.errorType) ? { errorType: event.errorType } : {}), ...(Number.isInteger(event.exitCode) && Math.abs(event.exitCode) <= 255 ? { exitCode: event.exitCode } : {}) });
    } catch { omitted++; }
  }
  return { available: true, omitted, truncated: events.length > 100, events: events.slice(-100) };
}
