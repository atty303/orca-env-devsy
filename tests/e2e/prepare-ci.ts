import assert from "node:assert/strict";
import { mkdir, chmod, symlink, appendFile, access, constants } from "node:fs/promises";
import { resolve } from "node:path";
import { run } from "../../scripts/process.ts";

const provider = process.argv[2];
assert(["docker", "podman", "microsandbox"].includes(provider));
assert.equal(process.platform, "linux");
assert.equal(process.env.GITHUB_ACTIONS, "true", "Runtime installation is restricted to the disposable CI runner");
assert((await Bun.file("/etc/os-release").text()).includes("VERSION_CODENAME=noble"));
if (provider === "docker") {
  const architecture = process.arch === "x64" ? "amd64" : process.arch === "arm64" ? "arm64" : undefined;
  assert(architecture, "Unsupported Docker CI architecture");
  const response = await fetch("https://download.docker.com/linux/ubuntu/gpg", { signal: AbortSignal.timeout(30_000) });
  assert(response.ok, "Docker signing key download failed");
  const key = await response.bytes();
  assert.equal(new Bun.CryptoHasher("sha256").update(key).digest("hex"), "1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570");
  const directory = resolve(".tools/e2e/docker");
  await mkdir(directory, { recursive: true });
  await Bun.write(directory + "/docker.asc", key);
  await run(["sudo", "install", "-D", "-m", "0644", directory + "/docker.asc", "/etc/apt/keyrings/docker.asc"]);
  await run(["sudo", "tee", "/etc/apt/sources.list.d/docker.sources"], { input: `Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: ${architecture}\nSigned-By: /etc/apt/keyrings/docker.asc\n` });
}
await run(["sudo", "apt-get", "update"], { inherit: true });
await run(["sudo", "apt-get", "install", "-y", "xvfb", "acl", "libasound2t64", "libatk-bridge2.0-0", "libatspi2.0-0", "libdrm2", "libgbm1", "libgtk-3-0", "libnss3", "libxcomposite1", "libxdamage1", "libxfixes3", "libxkbcommon0", "libxrandr2", ...(provider === "podman" ? ["podman=" + process.env.E2E_PODMAN_PACKAGE, "uidmap", "slirp4netns", "fuse-overlayfs"] : [])], { inherit: true, timeout: 180_000 });
if (provider === "docker") {
  const installed = new Set((await run(["dpkg-query", "-W", "-f=${Package}\n"])).trim().split("\n"));
  const conflicts = ["docker.io", "docker-compose", "docker-compose-v2", "docker-doc", "docker-buildx", "podman-docker", "containerd", "runc", "moby-engine", "moby-cli", "moby-buildx", "moby-containerd", "moby-runc"].filter(name => installed.has(name));
  if (conflicts.length) await run(["sudo", "apt-get", "remove", "-y", ...conflicts], { inherit: true, timeout: 180_000 });
  const version = `5:${process.env.E2E_DOCKER_VERSION}-1~ubuntu.24.04~noble`;
  await run(["sudo", "apt-get", "install", "-y", "--allow-downgrades", "docker-ce=" + version, "docker-ce-cli=" + version, "containerd.io=" + process.env.E2E_CONTAINERD_PACKAGE, "docker-buildx-plugin=" + process.env.E2E_BUILDX_PACKAGE], { inherit: true, timeout: 180_000 });
  await run(["sudo", "systemctl", "restart", "docker"], { inherit: true });
  assert.equal((await run(["docker", "version", "--format", "{{.Server.Version}}"])).trim(), process.env.E2E_DOCKER_VERSION);
} else if (provider === "podman") {
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
  // KVM's first udev event can replace an ACL applied only to the current node.
  // Keep access scoped to this runner UID as device events complete.
  const acl = `u:${process.getuid!()}:rw`;
  await run(["sudo", "tee", "/etc/udev/rules.d/99-orca-e2e-kvm.rules"], { input: `KERNEL=="kvm", RUN+="/usr/bin/setfacl -m ${acl} /dev/kvm"\n` });
  await run(["sudo", "udevadm", "control", "--reload-rules"]);
  await run(["sudo", "udevadm", "trigger", "--name-match=kvm"]);
  await run(["sudo", "udevadm", "settle"]);
  await run(["sudo", "setfacl", "-m", acl, "/dev/kvm"], { inherit: true });
  await access("/dev/kvm", constants.R_OK | constants.W_OK);
  await appendFile(Bun.env.GITHUB_PATH!, root + "\n");
  await appendFile(Bun.env.GITHUB_ENV!, "LD_LIBRARY_PATH=" + root + "\n");
}
