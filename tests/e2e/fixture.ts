import { cp, writeFile, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { processScope, type Environment } from "../../scripts/process.ts";

export async function fixture(root: string, env: Environment, version: string, signal?: AbortSignal) {
  const { run } = processScope(signal);
  const source = root + "/source";
  await cp(resolve("tests/e2e/fixture"), source, { recursive: true });
  const dockerfile = source + "/.devcontainer/Dockerfile";
  await writeFile(dockerfile, await readFile(dockerfile, "utf8") + `ENV ORCA_E2E_VERSION=${version}\n`);
  const git = (args: string[]) => run(["git", "-C", source, ...args], { env });
  await git(["init", "-b", "main"]);
  await git(["add", "."]);
  await git(["commit", "-qm", "fixture ancestor"]);
  await git(["commit", "--allow-empty", "-qm", "fixture build"]);
  const build = (await git(["rev-parse", "HEAD"])).trim();
  await git(["checkout", "-b", "task"]);
  await writeFile(source + "/identity.txt", "fixture-task\n");
  await git(["commit", "-qam", "fixture task"]);
  const task = (await git(["rev-parse", "HEAD"])).trim();
  await git(["checkout", "-b", "devcontainer", "main"]);
  await writeFile(source + "/identity.txt", "fixture-devcontainer\n");
  await git(["commit", "-qam", "fixture devcontainer"]);
  const customBuild = (await git(["rev-parse", "HEAD"])).trim();
  await git(["checkout", "main"]);
  await run(["git", "clone", "--bare", source, root + "/source.git"], { env });
  await run(["git", "-C", root + "/source.git", "config", "uploadpack.allowFilter", "true"], { env });
  return { source, build, task, customBuild, bare: root + "/source.git", async connect(url: string) {
    await git(["remote", "add", "origin", url]);
    await git(["fetch", "origin"]);
  } };
}

export async function recipes(source: string, devsy: string, home: string, provider: string, adapter: string) {
  const definitions = [
    { id: "ssh-worktree", connection: "ssh", mode: "orca-worktree", buildRef: "main" },
    { id: "ssh-root", connection: "ssh", mode: "provisioned-root" },
    { id: "server-a", connection: "orca-server", mode: "orca-worktree", buildRef: "main" },
    { id: "server-b", connection: "orca-server", mode: "orca-worktree", buildRef: "devcontainer" },
  ];
  const audit = home + "/clone-audit.ts";
  await writeFile(audit, `import { appendFile } from "node:fs/promises";
const args = process.argv.slice(3);
const index = args.indexOf("up");
if (index > 0 && args[index - 1] === "workspace") {
  const recipe = process.env.ORCA_RECIPE_ID;
  if (!${JSON.stringify(definitions.map(d => d.id))}.includes(recipe ?? "")) throw new Error("Unknown fixture recipe");
  const strategies = args.filter(arg => arg.startsWith("--git-clone-strategy="));
  await appendFile(${JSON.stringify(home + "/clone-audit.jsonl")}, JSON.stringify({ recipe, pinned: args[index + 1].includes("@sha256:"), strategies: strategies.map(arg => arg.slice("--git-clone-strategy=".length)) }) + "\\n");
}
const child = Bun.spawn([process.argv[2], ...args], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
process.exit(await child.exited);
`);
  await writeFile(source + "/orca.yaml", JSON.stringify({
    devsy: { command: [process.execPath, audit, devsy], home, addons: { codexAuth: true }, upArgs: ["--provider", provider] },
    environmentRecipes: definitions.map(({ id, connection, mode, buildRef }) => ({ id, name: id, checkoutMode: mode, devsy: { connection, ...(buildRef ? { buildRef } : {}) }, create: adapter + " recipe create", resume: adapter + " recipe resume", suspend: adapter + " recipe suspend", destroy: adapter + " recipe destroy" })),
  }, null, 2));
  return definitions;
}
