import { cp, mkdir, writeFile, readFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { run, type Environment } from "../../scripts/process.ts";

export async function fixture(root: string, env: Environment) {
  const source = root + "/source";
  await cp(resolve("tests/e2e/fixture"), source, { recursive: true });
  const git = (args: string[]) => run(["git", "-C", source, ...args], { env });
  await git(["init", "-b", "main"]);
  await git(["add", "."]);
  await git(["commit", "-qm", "fixture build"]);
  const build = (await git(["rev-parse", "HEAD"])).trim();
  await git(["checkout", "-b", "task"]);
  await writeFile(source + "/identity.txt", "fixture-task\n");
  await git(["commit", "-qam", "fixture task"]);
  const task = (await git(["rev-parse", "HEAD"])).trim();
  await git(["checkout", "main"]);
  const bare = root + "/source.git";
  await run(["git", "clone", "--bare", source, bare], { env });
  await run(["git", "-C", bare, "update-server-info"], { env });
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const path = decodeURIComponent(new URL(request.url).pathname);
    if (!path.startsWith("/source.git/") || path.includes("..")) return new Response(null, { status: 404 });
    const file = Bun.file(join(root, path));
    return await file.exists() ? new Response(file) : new Response(null, { status: 404 });
  }});
  const url = `http://127.0.0.1:${server.port}/source.git`;
  try { await git(["remote", "add", "origin", url]); }
  catch (error) { server.stop(true); throw error; }
  return { source, build, task, url, close: () => server.stop(true) };
}

export async function recipes(source: string, devsy: string, home: string, provider: string, adapter: string, build: string, deferredSshCreate: string) {
  const definitions = [
    { id: "ssh-worktree", connection: "ssh", mode: "orca-worktree" },
    { id: "ssh-root", connection: "ssh", mode: "provisioned-root" },
    { id: "server-a", connection: "orca-server", mode: "orca-worktree" },
    { id: "server-b", connection: "orca-server", mode: "orca-worktree" },
  ];
  await writeFile(source + "/orca.yaml", JSON.stringify({
    devsy: { command: [devsy], home, buildRef: build, addons: { codexAuth: true }, upArgs: ["--provider", provider] },
    environmentRecipes: definitions.map(({ id, connection, mode }) => ({ id, name: id, checkoutMode: mode, devsy: { connection }, create: id === "ssh-root" ? deferredSshCreate : adapter + " create", resume: adapter + " resume", suspend: adapter + " suspend", destroy: adapter + " destroy" })),
  }, null, 2));
  return definitions;
}
