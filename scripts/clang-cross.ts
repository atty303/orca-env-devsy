#!/usr/bin/env bun
import { run, children, terminate } from "./process.ts";
const target = process.env.ORCA_ENV_DEVSY_TARGET;
if (!target) throw new Error("ORCA_ENV_DEVSY_TARGET is required");
const args = process.argv.slice(2);
const link = !args.some(arg => ["-c", "-E", "-S", "-dumpmachine", "--version", "-v"].includes(arg));
const interrupt = () => { for (const child of children) void terminate(child); };
process.on("SIGINT", interrupt);
process.on("SIGTERM", interrupt);
try {
  await run(["zig", "cc", "-target", target, ...args,
    ...(link && target.includes("-linux-") ? ["-Wl,--strip-all"] : ["-isystem", `${process.env.MOON_TOOLCHAIN_ROOT}/cross-headers`])], { inherit: true });
} finally {
  process.removeListener("SIGINT", interrupt);
  process.removeListener("SIGTERM", interrupt);
}
