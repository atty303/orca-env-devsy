import { provisionFailure, type FailureObservation } from "./diagnostics.ts";

const consoleStages = [
  ["[ssh] Managed Orca server setup failed", "managed_setup", "failed"],
  ["[ssh] Managed Orca server setup deferred", "managed_setup", "deferred"],
  ["[ssh] The managed Orca server setup keeps its fence", "managed_fence", "failed"],
  ["[orcad] Could not stop the unreachable setup's server", "managed_cleanup", "failed"],
] as const;
const stages = "create resolve-context resolve-build-ref workspace-list workspace-create workspace-status ssh-tunnel resolve-root verify-build-commit checkout-workspace codex-auth orca-install orca-serve create-cleanup".split(" ");
type Observation = {
  sequence: number; elapsedMs: number; source: "console" | "provision" | "result";
  workspace?: number; activeWorkspaces?: number[]; stage: string; status: string;
  error?: FailureObservation;
};

export class OrcaObservations {
  private readonly origin = performance.now();
  private readonly events: Observation[] = [];
  private readonly active = new Set<number>();
  private readonly tails = new Map<number, string>();
  private readonly pending = new Set<Promise<void>>();
  private sequence = 0;
  private dropped = 0;
  private degraded = 0;
  constructor(readonly enabled = true) {}

  begin(workspace: number) { if (this.enabled) this.active.add(workspace); }
  finish(workspace: number, result: { ok: boolean; error?: unknown; stderr?: string; stdout?: string }) {
    if (!this.enabled) return;
    this.add({ source: "result", workspace, stage: "provision", status: result.ok ? "success" : "failed", ...result.ok ? {} : { error: provisionFailure(result.error, result.stderr, result.stdout) } });
    this.active.delete(workspace);
    this.tails.delete(workspace);
  }
  acceptsConsole(text: string) { return this.enabled && consoleStages.some(([prefix]) => text.startsWith(prefix)); }
  private consoleEvent(text: string) {
    const entry = consoleStages.find(([prefix]) => text.startsWith(prefix));
    if (!this.enabled || !entry) return;
    return this.add({ source: "console", activeWorkspaces: [...this.active], stage: entry[1], status: entry[2] });
  }
  console(text: string, error: unknown) {
    const event = this.consoleEvent(text);
    if (event) event.error = provisionFailure(error);
  }
  captureConsole(text: string, read: () => Promise<unknown>) {
    const event = this.consoleEvent(text);
    if (event) this.capture(async () => { event.error = provisionFailure(await read()); });
  }
  provision(event: { provisionId?: unknown; stream?: unknown; chunk?: unknown }) {
    if (!this.enabled || typeof event.provisionId !== "string" || !/^provision-[0-3]$/.test(event.provisionId) || event.stream !== "stderr" || typeof event.chunk !== "string") return;
    const workspace = Number(event.provisionId.slice(-1));
    if (event.chunk.length > 16_384) this.dropped++;
    const text = (this.tails.get(workspace) ?? "") + event.chunk.slice(-16_384);
    const lines = text.split("\n");
    this.tails.set(workspace, lines.pop()!.slice(-256));
    for (const line of lines) {
      for (const stage of stages) {
        const match = new RegExp(`(?:^| )${stage}: (running|connecting|connected|done|failed)(?:[^a-z]|$)`).exec(line);
        if (match) this.add({ source: "provision", workspace, stage, status: match[1] });
      }
    }
  }
  // Console argument handles can become unavailable during application exit.
  // Recording failures are observable and never change the operation result.
  capture(read: () => Promise<void>) {
    if (!this.enabled) return;
    if (this.pending.size >= 16) { this.dropped++; return; }
    const operation = Promise.resolve().then(read).catch(() => { this.degraded++; }).finally(() => this.pending.delete(operation));
    this.pending.add(operation);
  }
  recordingFailure() { if (this.enabled) this.degraded++; }
  private add(event: Omit<Observation, "sequence" | "elapsedMs">) {
    if (this.events.length >= 256) {
      const expendable = this.events.findIndex(event => event.status !== "failed");
      this.events.splice(expendable < 0 ? 0 : expendable, 1);
      this.dropped++;
    }
    const observation = { sequence: ++this.sequence, elapsedMs: Math.round(performance.now() - this.origin), ...event };
    this.events.push(observation);
    return observation;
  }
  async snapshot() {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([Promise.allSettled([...this.pending]), new Promise<void>(resolve => { timer = setTimeout(resolve, 500); })]);
    } finally { clearTimeout(timer); }
    return { enabled: this.enabled, completeness: this.pending.size || this.active.size || this.dropped || this.degraded ? "partial" : "complete", dropped: this.dropped, degraded: this.degraded, pending: this.pending.size, activeWorkspaces: [...this.active], events: [...this.events] };
  }
}
