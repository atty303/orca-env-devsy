import { test, expect } from "bun:test";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { start, terminate, until } from "../scripts/process.ts";

for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"] as const) {
  test(`release build restores source after ${signal}${signal === "SIGHUP" ? "" : " twice"}`, async () => {
    const directory = await mkdtemp(tmpdir() + "/oe-release-test-");
    const original = '///|\npub let version : String = "0.0.0-dev"\n';
    let child: ReturnType<typeof start> | undefined;
    let buildPid: number | undefined;
    try {
      for (const name of ["scripts", "src", "bin"]) await mkdir(`${directory}/${name}`);
      for (const name of ["release-build.ts", "process.ts"]) await cp(resolve("scripts", name), `${directory}/scripts/${name}`);
      await writeFile(`${directory}/src/version.mbt`, original);
      // Keep the build alive long enough for a repeated signal to reach the
      // parent while it is waiting to restore the tracked source.
      await writeFile(`${directory}/bin/moon`, `#!${process.execPath}\nimport { writeFileSync } from "node:fs";\nprocess.on("SIGTERM", () => { setTimeout(() => process.exit(143), 300); });\nwriteFileSync("build-pid", String(process.pid));\nsetInterval(() => {}, 1000);\n`, { mode: 0o700 });
      child = start([process.execPath, "scripts/release-build.ts", "1.2.3", `${directory}/artifacts`], {
        cwd: directory, env: { ...process.env, PATH: `${directory}/bin:${process.env.PATH}`, TMPDIR: directory, RELEASE_VERSION: undefined, RELEASE_ARTIFACT_DIR: undefined },
      });
      await until(async () => {
        try { buildPid = Number(await readFile(`${directory}/build-pid`, "utf8")); return true; }
        catch { return false; }
      }, 5000);
      expect(await readFile(`${directory}/src/version.mbt`, "utf8")).toContain('"1.2.3"');
      child.kill(signal);
      if (signal !== "SIGHUP") {
        await Bun.sleep(50);
        child.kill(signal);
      }
      await until(async () => child!.exitCode !== null || child!.signalCode !== null, 5000);
      expect(child.signalCode).toBeNull();
      expect(child.exitCode).not.toBe(0);
      expect(await readFile(`${directory}/src/version.mbt`, "utf8")).toBe(original);
    } finally {
      if (child) await terminate(child);
      if (buildPid) {
        try { process.kill(-buildPid, "SIGKILL"); }
        catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error; }
      }
      await rm(directory, { recursive: true, force: true });
    }
  }, 15_000);
}
