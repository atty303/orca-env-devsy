import { mkdir, mkdtemp, readFile, writeFile, cp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { run, children, stop } from "./process.ts";

const [version, output] = process.argv.slice(2);
if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$/.test(version ?? "") || !output || !isAbsolute(output)) throw new Error("Expected SemVer and absolute artifact directory");
if ((process.env.RELEASE_VERSION ?? version) !== version || (process.env.RELEASE_ARTIFACT_DIR ?? output) !== output) throw new Error("Release arguments disagree with environment");
const original = await readFile("src/version.mbt");
const work = await mkdtemp(tmpdir() + "/oe-release-");
const moon = resolve(".tools/cross/moon");
let interrupted = false;
const interrupt = () => {
  interrupted = true;
  for (const child of children) stop(child, "SIGTERM");
};
process.once("SIGINT", interrupt);
process.once("SIGTERM", interrupt);
try {
  await writeFile("src/version.mbt", `///|\npub let version : String = "${version}"\n`);
  await mkdir(output, { recursive: true });
  for (const [platform, target] of Object.entries({ "macos-arm64": "aarch64-macos.13.0", "linux-x64": "x86_64-linux-gnu.2.31", "linux-arm64": "aarch64-linux-gnu.2.31" })) {
    if (interrupted) throw new Error("Build interrupted");
    const build = `${work}/build/${platform}`;
    await run(["moon", "build", "--target", "native", "--release", "--deny-warn", "--target-dir", build], {
      env: { ...process.env, MOON_TOOLCHAIN_ROOT: moon, MOON_CC: resolve("scripts/clang-cross.ts"), MOON_AR: resolve("scripts/llvm-ar"), ORCA_ENV_DEVSY_TARGET: target },
      timeout: 600_000, inherit: true,
    });
    const pkg = `${work}/${platform}`;
    await mkdir(pkg + "/licenses", { recursive: true });
    await cp(build + "/native/release/build/cmd/main/main.exe", pkg + "/orca-env-devsy");
    await cp("LICENSE", pkg + "/LICENSE");
    for (const [source, name] of [[".mooncakes/moonbitlang/async/LICENSE", "moonbitlang-async.txt"], [".mooncakes/moonbit-community/yaml/LICENSE", "moonbit-community-yaml.txt"], [moon + "/lib/core/LICENSE", "moonbitlang-core.txt"], ...(platform === "macos-arm64" ? [[moon + "/cross-headers/sys/vnode.h", "apple-xnu-vnode.h.txt"]] : [])]) await cp(source, pkg + "/licenses/" + name);
    console.log(`Standalone executable: ${(await stat(pkg + "/orca-env-devsy")).size} bytes (${platform})`);
    await run(["tar", "-czf", `${output}/orca-env-devsy-${version}-${platform}.tar.gz`, "-C", pkg, "orca-env-devsy", "LICENSE", "licenses"]);
  }
  if (interrupted) throw new Error("Build interrupted");
} finally {
  await writeFile("src/version.mbt", original);
  await rm(work, { recursive: true, force: true });
  process.removeListener("SIGINT", interrupt);
  process.removeListener("SIGTERM", interrupt);
}
