// Temporary CI diagnosis: compare KVM access before and after native VM startup.
import { mkdtemp, rm, mkdir, writeFile, access, constants } from "node:fs/promises";
import { resolve } from "node:path";
import { run, processFailureCategory, type Environment } from "../../scripts/process.ts";

if (process.platform !== "linux" || process.env.GITHUB_ACTIONS !== "true") throw new Error("Disposable Linux CI only");
const root = await mkdtemp("/tmp/msb-probe-");
const binary = resolve(".tools/e2e/microsandbox/msb");
const env: Environment = { PATH: process.env.PATH, HOME: root, MSB_HOME: root + "/msb", LD_LIBRARY_PATH: resolve(".tools/e2e/microsandbox") };
const prefix = root.split("/").at(-1)!.toLowerCase();
const rule = "/etc/udev/rules.d/99-" + prefix + "-kvm.rules";
const kvmAccess = () => access("/dev/kvm", constants.R_OK | constants.W_OK).then(() => true, () => false);
const initialKvmAccess = await kvmAccess();
const outcomes: { phase: string; ready: boolean; exitCode: number | null; sites: string[]; category: string }[] = [];
const processes: ReturnType<typeof Bun.spawn>[] = [];
const names: string[] = [];
let permissionRuleInstalled = false;
const phase = async (label: string) => {
  const group: typeof outcomes = [];
  const groupNames: string[] = [];
  const groupProcesses: typeof processes = [];
  for (let index = 0; index < 4; index++) {
    const name = prefix + "-" + label + "-" + index;
    names.push(name); groupNames.push(name);
    const state = { phase: label, ready: false, exitCode: null as number | null, sites: [] as string[], category: "pending" };
    group.push(state);
    const child = Bun.spawn([binary, "run", "--name", name, "--memory", "2048M", "--cpus", "1", "--no-stdin", "--no-tty", "ubuntu:24.04", "--", "/bin/sh", "-c", "printf MSB_PROBE_READY; sleep 120"], { env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    processes.push(child); groupProcesses.push(child);
    const read = async (stream: ReadableStream<Uint8Array>) => {
      let tail = "";
      for await (const chunk of stream) {
        tail = (tail + Buffer.from(chunk).toString()).slice(-65536);
        if (tail.includes("MSB_PROBE_READY")) state.ready = true;
        state.category = processFailureCategory(tail);
        state.sites = [...new Set([...tail.matchAll(/([A-Za-z0-9_]+\.(?:c|cc|rs)):(\d+)(?::\d+)?/g)].map(match => match[1] + ":" + match[2]))].slice(-16);
      }
    };
    void Promise.all([read(child.stdout), read(child.stderr), child.exited.then(code => { state.exitCode = code; })]).catch(() => {});
  }
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline && group.some(outcome => !outcome.ready && outcome.exitCode === null)) await Bun.sleep(200);
  outcomes.push(...group.map(outcome => ({ ...outcome, sites: [...outcome.sites] })));
  for (const child of groupProcesses) child.kill("SIGTERM");
  for (const name of groupNames) {
    await run([binary, "stop", name], { env, timeout: 10_000 }).catch(() => {});
    await run([binary, "remove", name], { env, timeout: 10_000 }).catch(() => {});
  }
  for (const child of groupProcesses) { child.kill("SIGKILL"); await child.exited; }
};
try {
  await phase("baseline");
  const afterBaselineKvmAccess = await kvmAccess();
  if (!initialKvmAccess || !afterBaselineKvmAccess) {
    permissionRuleInstalled = true;
    await run(["sudo", "tee", rule], { input: `KERNEL=="kvm", RUN+="/usr/bin/setfacl -m u:${process.getuid!()}:rw /dev/kvm"\n` });
    await run(["sudo", "udevadm", "control", "--reload-rules"]);
    await run(["sudo", "udevadm", "trigger", "--name-match=kvm"]);
    await run(["sudo", "udevadm", "settle"]);
    await run(["sudo", "setfacl", "-m", `u:${process.getuid!()}:rw`, "/dev/kvm"]);
    await phase("acl");
  }
  await mkdir(".e2e/runtime-probe", { recursive: true });
  await writeFile(".e2e/runtime-probe/diagnostic.json", JSON.stringify({ kind: "native-microsandbox-kvm-access", initialKvmAccess, afterBaselineKvmAccess, finalKvmAccess: await kvmAccess(), outcomes }, null, 2), { mode: 0o600 });
  if (outcomes.some(outcome => !outcome.ready || outcome.exitCode !== null)) process.exitCode = 1;
} finally {
  for (const child of processes) child.kill("SIGTERM");
  for (const name of names) {
    await run([binary, "stop", name], { env, timeout: 10_000 }).catch(() => {});
    await run([binary, "remove", name], { env, timeout: 10_000 }).catch(() => {});
  }
  for (const child of processes) { child.kill("SIGKILL"); await child.exited; }
  if (permissionRuleInstalled) {
    await run(["sudo", "rm", "-f", rule]);
    await run(["sudo", "udevadm", "control", "--reload-rules"]);
  }
  await rm(root, { recursive: true, force: true });
}
