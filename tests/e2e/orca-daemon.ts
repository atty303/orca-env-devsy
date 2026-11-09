import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { budgets, measure } from "./timing.ts";
import { until } from "../../scripts/process.ts";

type DaemonRecord = { pid: number; linuxStartTicks: string | number; bootId: string; entryPath: string };

async function missingAsUndefined<T>(read: () => Promise<T>): Promise<T | undefined> {
  try { return await read(); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT" || (error as NodeJS.ErrnoException).code === "ESRCH") return undefined;
    throw error;
  }
}

export async function stopOrcaDaemons(profile: string) {
  if (process.platform !== "linux") return;
  await measure("orca-daemon-stop", budgets.operation, async () => {
    const directory = join(profile, "daemon");
    const files = await missingAsUndefined(() => readdir(directory)) ?? [];
    const bootId = (await readFile("/proc/sys/kernel/random/boot_id", "utf8")).trim();
    for (const file of files.filter(name => /^daemon-v[^/]+\.pid$/.test(name))) {
      const content = await missingAsUndefined(() => readFile(join(directory, file), "utf8"));
      if (content === undefined) continue;
      const record = JSON.parse(content) as DaemonRecord;
      if (!Number.isSafeInteger(record.pid) || record.pid <= 0 || !["string", "number"].includes(typeof record.linuxStartTicks) || typeof record.bootId !== "string" || typeof record.entryPath !== "string" || !record.entryPath.endsWith("/daemon-entry.js")) throw new Error("Invalid Orca daemon identity");
      const proc = `/proc/${record.pid}`;
      const stat = await missingAsUndefined(() => readFile(proc + "/stat", "utf8"));
      if (stat === undefined || /\) Z /.test(stat)) continue;
      const args = await missingAsUndefined(() => readFile(proc + "/cmdline", "utf8"));
      if (args === undefined) continue;
      const parts = args.split("\0");
      const ticks = stat.slice(stat.lastIndexOf(") ") + 2).split(" ")[19];
      const socketIndex = parts.indexOf("--socket");
      if (record.bootId !== bootId || String(record.linuxStartTicks) !== ticks || !parts.includes(record.entryPath) || socketIndex < 0 || !parts[socketIndex + 1]?.startsWith(directory + "/")) throw new Error("Cannot verify Orca daemon ownership");
      await measure("orca-daemon-signal", budgets.operation, async () => {
        try { process.kill(record.pid, "SIGTERM"); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error; }
        await until(async () => {
          const current = await missingAsUndefined(() => readFile(proc + "/stat", "utf8"));
          if (current === undefined || /\) Z /.test(current)) return true;
          if (current.slice(current.lastIndexOf(") ") + 2).split(" ")[19] !== ticks) return true;
          return false;
        }, budgets.operation);
      });
    }
  });
}
