import assert from "node:assert/strict";
import { mkdir, chmod, symlink, appendFile } from "node:fs/promises";
import { resolve } from "node:path";
import { run } from "../../scripts/process.ts";

const provider = process.argv[2];
assert(["docker", "podman", "microsandbox"].includes(provider));
assert.equal(process.platform, "linux");
assert.equal(process.env.GITHUB_ACTIONS, "true", "Runtime installation is restricted to the disposable CI runner");
await run(["sudo", "apt-get", "update"], { inherit: true });
await run(["sudo", "apt-get", "install", "-y", "xvfb", "acl", "libasound2t64", "libatk-bridge2.0-0", "libatspi2.0-0", "libdrm2", "libgbm1", "libgtk-3-0", "libnss3", "libxcomposite1", "libxdamage1", "libxfixes3", "libxkbcommon0", "libxrandr2", ...(provider === "podman" ? ["podman=" + process.env.E2E_PODMAN_PACKAGE, "uidmap", "slirp4netns", "fuse-overlayfs"] : [])], { inherit: true, timeout: 180_000 });
if (provider === "docker") {
  const version = `5:${process.env.E2E_DOCKER_VERSION}-1~ubuntu.24.04~noble`;
  await run(["sudo", "apt-get", "install", "-y", "--allow-downgrades", "docker-ce=" + version, "docker-ce-cli=" + version, "containerd.io=" + process.env.E2E_CONTAINERD_PACKAGE, "docker-buildx-plugin=" + process.env.E2E_BUILDX_PACKAGE], { inherit: true, timeout: 180_000 });
  await run(["sudo", "systemctl", "restart", "docker"], { inherit: true });
  assert.equal((await run(["docker", "version", "--format", "{{.Server.Version}}"])).trim(), process.env.E2E_DOCKER_VERSION);
} else if (provider === "podman") {
  await run(["systemctl", "--user", "enable", "--now", "podman.socket"], { inherit: true });
  assert.equal((await run(["podman", "info", "--format", "{{.Host.Security.Rootless}}"])).trim(), "true", "Podman must run rootless");
} else if (provider === "microsandbox") {
  assert.equal(process.arch, "x64");
  const root = resolve(".tools/e2e/microsandbox");
  await mkdir(root, { recursive: true });
  const response = await fetch("https://github.com/superradcompany/microsandbox/releases/download/v0.7.7/microsandbox-linux-x86_64.tar.gz");
  assert(response.ok, "Microsandbox download failed");
  const data = new Uint8Array(await response.arrayBuffer());
  assert.equal(new Bun.CryptoHasher("sha256").update(data).digest("hex"), "b3cc4a5e3f52dfdd938a6f67ac4a9a959ddfe304bab56de4964044b8613f01bb");
  await Bun.write(root + "/msb.tar.gz", data);
  await run(["tar", "-xzf", root + "/msb.tar.gz", "-C", root], { inherit: true });
  await chmod(root + "/msb", 0o755);
  await symlink("libkrunfw.so.5.6.1", root + "/libkrunfw.so.5").catch(error => { if (error.code !== "EEXIST") throw error; });
  await symlink("libkrunfw.so.5", root + "/libkrunfw.so").catch(error => { if (error.code !== "EEXIST") throw error; });
  await run(["sudo", "setfacl", "-m", `u:${process.getuid!()}:rw`, "/dev/kvm"], { inherit: true });
  await appendFile(Bun.env.GITHUB_PATH!, root + "\n");
  await appendFile(Bun.env.GITHUB_ENV!, "LD_LIBRARY_PATH=" + root + "\n");
}
