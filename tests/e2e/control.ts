import { children, stop } from "../../scripts/process.ts";
import { budgets } from "./timing.ts";

export function interruptibleRun() {
  const phase = new AbortController();
  let interrupted = false;
  let cleaning = false;
  const interrupt = () => {
    if (interrupted) return;
    interrupted = true;
    if (!phase.signal.aborted) phase.abort(new Error("E2E interrupted"));
    if (cleaning) return;
    for (const child of children) {
      try { stop(child); } catch { /* Final cleanup checks termination again. */ }
    }
  };
  process.on("SIGINT", interrupt);
  process.on("SIGTERM", interrupt);
  return {
    signal: phase.signal,
    get interrupted() { return interrupted; },
    beginCleanup() {
      cleaning = true;
      if (!phase.signal.aborted) phase.abort(new Error("E2E execution ended"));
    },
    close() {
      process.off("SIGINT", interrupt);
      process.off("SIGTERM", interrupt);
    },
  };
}

export function cleanupDeadline(errors: string[], timeout = budgets.cleanup) {
  const cleanup = new AbortController();
  const timer = setTimeout(() => {
    errors.push("cleanup-deadline");
    cleanup.abort(new Error("E2E cleanup deadline exceeded"));
  }, timeout);
  return { signal: cleanup.signal, close: () => clearTimeout(timer) };
}
