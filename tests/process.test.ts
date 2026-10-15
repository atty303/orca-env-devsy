import { expect, test } from "bun:test";
import { once } from "node:events";
import { children, run, start, terminate } from "../scripts/process.ts";
import { Orca } from "./e2e/orca.ts";
import { OrcaObservations } from "./e2e/observations.ts";

test("command deadlines reject even when an exited parent leaves inherited pipes open", async () => {
  const before = new Set(children);
  const started = performance.now();
  const operation = run(["sh", "-c", "sleep 30 & printf private-pipe-fixture; exit 0"], { timeout: 50 });
  try {
    const result = await Promise.race([
      operation.then(() => "success", error => (error as Error).message),
      Bun.sleep(1000).then(() => "still-pending"),
    ]);
    expect(result).toBe("Child command deadline exceeded (timeout)");
    expect(performance.now() - started).toBeLessThan(1000);
  } finally {
    for (const child of children) if (!before.has(child)) {
      try { process.kill(-child.pid!, "SIGKILL"); } catch { /* Owned process group may already be gone. */ }
    }
    await operation.catch(() => {});
  }
});

test("termination reaps owned descendants after their parent exits", async () => {
  const child = start(["sh", "-c", "sleep 30 & exit 0"]);
  try {
    await once(child, "exit");
    await terminate(child);
    expect(children.has(child)).toBe(false);
  } finally {
    try { process.kill(-child.pid!, "SIGKILL"); } catch { /* Owned process group may already be gone. */ }
  }
});

test("termination escalates for a descendant that ignores TERM and closes its pipes", async () => {
  const child = start(["sh", "-c", `sh -c 'trap "" TERM; echo $$; exec sleep 30 >/dev/null 2>&1' </dev/null & wait`]);
  const [output] = await once(child.stdout!, "data");
  const descendant = Number(output.toString().trim());
  expect(Number.isSafeInteger(descendant) && descendant > 1).toBe(true);
  try {
    await terminate(child);
    let gone = false;
    try { process.kill(descendant, 0); }
    catch (error) { gone = (error as NodeJS.ErrnoException).code === "ESRCH"; }
    expect(gone).toBe(true);
  } finally {
    try { process.kill(-child.pid!, "SIGKILL"); } catch { /* Owned process group may already be gone. */ }
  }
});

test("termination retains ownership after the leader and all its pipes close", async () => {
  const child = start(["sh", "-c", `sh -c 'echo $$; exec sleep 30 >/dev/null 2>&1' </dev/null & exit 0`]);
  const [output] = await once(child.stdout!, "data");
  const descendant = Number(output.toString().trim());
  expect(Number.isSafeInteger(descendant) && descendant > 1).toBe(true);
  await once(child, "close");
  try {
    expect(children.has(child)).toBe(true);
    await terminate(child);
    let gone = false;
    try { process.kill(descendant, 0); }
    catch (error) { gone = (error as NodeJS.ErrnoException).code === "ESRCH"; }
    expect(gone).toBe(true);
    expect(children.has(child)).toBe(false);
  } finally {
    try { process.kill(-child.pid!, "SIGKILL"); } catch { /* Owned process group may already be gone. */ }
  }
});

test("Orca close rejects at its deadline even if killing Electron never settles close", async () => {
  let kills = 0;
  const app = { close: () => new Promise<void>(() => {}), process: () => ({ kill(signal: string) { expect(signal).toBe("SIGKILL"); kills++; return false; } }) };
  const orca = Reflect.construct(Orca, [app, 0, new OrcaObservations()]) as Orca;
  const started = performance.now();
  const result = await Promise.race([
    orca.close(50).then(() => "success", error => (error as Error).message),
    Bun.sleep(1000).then(() => "still-pending"),
  ]);
  expect(result).toBe("Orca close deadline exceeded");
  expect(kills).toBe(1);
  expect(performance.now() - started).toBeLessThan(1000);
});
