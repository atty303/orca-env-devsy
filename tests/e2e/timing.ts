import assert from "node:assert/strict";

export const targets = { firstUse: 2_000, sshConnections: 10_000, operation: 5_000, recovery: 5_000, provision: 600_000, lifecycle: 60_000, cleanup: 120_000 };
export const bufferMs = 5_000;
export const budgets = { ...targets };
for (const key of Object.keys(budgets) as (keyof typeof budgets)[]) budgets[key] += bufferMs;
export const timings: { operation: string; workspace?: number; elapsedMs: number; targetMs: number; budgetMs: number; ok: boolean }[] = [];

export async function measure<T>(operation: string, budgetMs: number, action: () => Promise<T>, workspace?: number): Promise<T> {
  const started = performance.now();
  let ok = false;
  try {
    const result = await action();
    assert(performance.now() - started <= budgetMs, `${operation} exceeded ${budgetMs} ms`);
    ok = true;
    return result;
  } finally {
    assert(timings.length < 4096, "Timing recording limit exceeded");
    timings.push({ operation, workspace, elapsedMs: Math.ceil(performance.now() - started), targetMs: Math.max(0, budgetMs - bufferMs), budgetMs, ok });
  }
}
