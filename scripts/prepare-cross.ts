import { mkdir, readFile, rm, symlink, cp, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { run } from "./process.ts";

const source = (await run(["mise", "where", "http:moonbit"])).trim();
const home = resolve(".tools/cross/moon");
const stamp = source + ":" + (await run(["zig", "version"])).trim();
if (await readFile(home + "/.prepared", "utf8").catch(() => "") !== stamp + "\n") {
  const response = await fetch("https://raw.githubusercontent.com/apple-oss-distributions/xnu/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/vnode.h");
  if (!response.ok) throw new Error("Darwin header download failed");
  const data = new Uint8Array(await response.arrayBuffer());
  if (new Bun.CryptoHasher("sha256").update(data).digest("hex") !== "2d6b4a7f2963d78829f9f8b840568a433a4ae30a1fe8a99f18ecb314d430ecb2") throw new Error("Darwin header checksum mismatch");
  await rm(home, { recursive: true, force: true });
  await mkdir(home + "/lib", { recursive: true });
  await symlink(source + "/bin", home + "/bin");
  await symlink(source + "/include", home + "/include");
  await symlink(source + "/lib/core", home + "/lib/core");
  await cp(source + "/lib/runtime", home + "/lib/runtime", { recursive: true });
  await mkdir(home + "/cross-headers/sys", { recursive: true });
  await writeFile(home + "/cross-headers/sys/vnode.h", data);
  await writeFile(home + "/.prepared", stamp + "\n");
}
