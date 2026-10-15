import { writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { quote } from "../../scripts/process.ts";
import { budgets } from "./timing.ts";

export async function nativeSshSetupGate(root: string, adapter: string) {
  const release = root + "/native-ssh-setup-released";
  const launcher = root + "/native-ssh-create.ts";
  await writeFile(launcher, `import { deferSshReceipt } from ${JSON.stringify(resolve("tests/e2e/native-setup.ts"))};\nawait deferSshReceipt(${JSON.stringify(adapter)}, ${JSON.stringify(release)}, ${budgets.provision});\n`, { mode: 0o600 });
  return { command: [process.execPath, launcher].map(quote).join(" "), release: () => writeFile(release, "", { mode: 0o600 }) };
}

// Devsy creation runs immediately. Only delivery of the second SSH receipt waits
// for the first native Orca deployment, whose shared artifact cache is mutable.
export async function deferSshReceipt(adapter: string, release: string, timeout: number) {
  const child = Bun.spawn([adapter, "create"], { stdin: "inherit", stdout: "pipe", stderr: "inherit" });
  let cancelled: NodeJS.Signals | undefined;
  const interrupt = (signal: NodeJS.Signals) => { cancelled = signal; if (child.exitCode === null) child.kill(signal); };
  const terminate = () => interrupt("SIGTERM"), interject = () => interrupt("SIGINT");
  process.once("SIGTERM", terminate);
  process.once("SIGINT", interject);
  const output = new Response(child.stdout).arrayBuffer();
  const code = await child.exited;
  const bytes = await output;
  let expired = false;
  if (code === 0 && !cancelled) {
    console.error("native-ssh-setup: waiting for the first deployment");
    const deadline = performance.now() + timeout;
    while (!cancelled && !await Bun.file(release).exists()) {
      if (performance.now() >= deadline) { expired = true; break; }
      await Bun.sleep(25);
    }
  }
  process.off("SIGTERM", terminate);
  process.off("SIGINT", interject);
  const signal = cancelled ?? child.signalCode;
  if (signal) { process.kill(process.pid, signal); return; }
  if (expired) { console.error("native-ssh-setup: gate deadline exceeded"); process.exit(1); }
  await Bun.write(Bun.stdout, bytes);
  process.exit(code);
}
