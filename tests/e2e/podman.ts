import { appendFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { processFailureCategory } from "../../scripts/process.ts";

const operations = new Set(["run", "start", "create", "build", "pull", "exec", "inspect", "rm", "stop", "kill", "network", "volume", "info", "version"]);
const markers = ["crun", "runc", "netavark", "aardvark", "slirp4netns", "rootlessport", "conmon", "cgroup", "dbus", "systemd", "overlay", "mount", "network", "namespace", "permission", "not found", "already exists", "invalid", "quota", "lock", "database", "socket", "timeout", "resource", "busy", "setns", "address", "port", "rootfs", "chown", "uid", "gid", "subuid", "iptables", "nftables", "re-exec", "oci runtime", "executable file", "short-name", "manifest", "registry", "unauthorized", "connection refused"];

export function classifyPodman(output: string) {
  const text = output.toLowerCase();
  return { category: processFailureCategory(text), markers: markers.filter(marker => text.includes(marker)) };
}

export async function installPodmanDiagnostics(root: string) {
  const binary = Bun.which("podman");
  if (!binary) throw new Error("Podman binary missing");
  const wrapper = root + "/bin/podman";
  await writeFile(wrapper, `#!${process.execPath}\nimport { launch } from ${JSON.stringify(resolve("tests/e2e/podman.ts"))};\nawait launch(${JSON.stringify(binary)}, ${JSON.stringify(root + "/podman-failures.jsonl")});\n`, { mode: 0o700 });
  return wrapper;
}

export async function launch(binary: string, report: string) {
  const args = process.argv.slice(2);
  const started = performance.now();
  const child = Bun.spawn([binary, ...args], { stdin: "inherit", stdout: "inherit", stderr: "pipe" });
  process.once("SIGTERM", () => child.kill("SIGTERM"));
  process.once("SIGINT", () => child.kill("SIGINT"));
  let tail = "";
  const forwarding = (async () => {
    for await (const chunk of child.stderr) {
      tail = (tail + Buffer.from(chunk).toString()).slice(-16_384);
      process.stderr.write(chunk);
    }
  })();
  const [code] = await Promise.all([child.exited, forwarding]);
  const operation = args.find(arg => operations.has(arg)) ?? "other";
  if (code !== 0 && ["run", "start", "create", "build", "pull", "network"].includes(operation)) try {
    await appendFile(report, JSON.stringify({ operation, exitCode: code, elapsedMs: Math.ceil(performance.now() - started), ...classifyPodman(tail) }) + "\n", { mode: 0o600 });
  } catch { /* Recording must preserve the runtime's result. */ }
  process.exit(code);
}
