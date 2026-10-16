import assert from "node:assert/strict";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { gitServer, type GitServerOptions } from "./git-server.ts";
import { processScope, stop, type Environment } from "../../scripts/process.ts";

export const access = (generation: number, expiry = Math.floor(Date.now() / 1000) + 1_209_600) => "fixture." + Buffer.from(JSON.stringify({ exp: expiry, generation })).toString("base64url") + ".invalid-signature";
export const auth = (token: string) => JSON.stringify({ auth_mode: "chatgpt", tokens: { access_token: token, id_token: token, account_id: "e2e-account", refresh_token: "fixture-not-a-real-refresh-token" } });

export async function services(root: string, env: Environment, options: GitServerOptions, signal?: AbortSignal) {
  const { run, start } = processScope(signal);
  await mkdir(root + "/bin", { recursive: true });
  await mkdir(env.CODEX_HOME!, { recursive: true, mode: 0o700 });
  await writeFile(env.CODEX_HOME + "/auth.json", auth(access(0, Math.floor(Date.now() / 1000) + 60)), { mode: 0o600 });
  await writeFile(env.CODEX_HOME + "/next-auth.json", auth(access(1)), { mode: 0o600 });
  // Only the account refresh RPC is synthetic; the adapter reads, locks and
  // delivers the actual files through its production SSH path.
  await writeFile(root + "/bin/codex", `#!${process.execPath}
import { createInterface } from "node:readline";
import { appendFile, copyFile } from "node:fs/promises";
for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  if (request.method === "account/read") {
    await appendFile(process.env.CODEX_HOME + "/refresh-count", "refresh\\n");
    await Bun.sleep(100);
    await copyFile(process.env.CODEX_HOME + "/next-auth.json", process.env.CODEX_HOME + "/auth.json");
  }
  if (request.id) console.log(JSON.stringify({ id: request.id, result: {} }));
}
`, { mode: 0o700 });
  env.PATH = root + "/bin:" + env.PATH;
  const key = root + "/agent-key";
  await run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "e2e", "-f", key], { env });
  env.SSH_AUTH_SOCK = root + "/agent.sock";
  const agent = start(["ssh-agent", "-D", "-a", env.SSH_AUTH_SOCK], { env });
  let server: Awaited<ReturnType<typeof gitServer>> | undefined;
  try {
    for (let attempt = 0; ; attempt++) {
      try { await run(["ssh-add", key], { env }); break; }
      catch (error) { signal?.throwIfAborted(); if (attempt === 50) throw error; await Bun.sleep(100); }
    }
    const publicKey = (await readFile(key + ".pub", "utf8")).trim();
    await writeFile(root + "/helper", `#!${process.execPath}
import { appendFile } from "node:fs/promises";
const input = await Bun.stdin.text();
const values = Object.fromEntries(input.trim().split("\\n").map(line => { const i = line.indexOf("="); return [line.slice(0, i), line.slice(i + 1)]; }));
await appendFile(${JSON.stringify(root + "/helper-audit")}, JSON.stringify({ action: process.argv[2], path: /^w-[0-3]\\.git$/.test(values.path ?? "") ? values.path : "other", host: values.host === "127.0.0.1:18080" }) + "\\n");
const child = Bun.spawn(["git", "credential-store", "--file", ${JSON.stringify(root + "/credentials")}, process.argv[2]], { stdin: Buffer.from(input), stdout: "inherit", stderr: "ignore" });
process.exit(await child.exited);
`, { mode: 0o700 });
    await run(["git", "config", "--global", "credential.helper", root + "/helper"], { env });
    await run(["git", "config", "--global", "credential.useHttpPath", "true"], { env });
    await run(["git", "config", "--global", "user.name", "E2E"], { env });
    await run(["git", "config", "--global", "user.email", "e2e@example.invalid"], { env });
    for (let i = 0; i < 4; i++) {
      await run(["git", "credential", "approve"], { env, input: `protocol=http\nhost=127.0.0.1:18080\npath=w-${i}.git\nusername=w-${i}\npassword=dummy-w-${i}\n\n` });
    }
    for (let i = 0; i < 4; i++) {
      const credential = await run(["git", "credential", "fill"], { env, input: `protocol=http\nhost=127.0.0.1:18080\npath=w-${i}.git\n\n` });
      assert(credential.includes(`username=w-${i}\n`), "Shared host helper must resolve each fixture target");
    }
    server = await gitServer(root, env, options, signal);
    return { ...server, publicKey, async close(cleanupSignal?: AbortSignal) { try { await server!.close(cleanupSignal); } finally { stop(agent, "SIGKILL"); } } };
  } catch (error) { await server?.close().catch(() => {}); stop(agent, "SIGKILL"); throw error; }
}
