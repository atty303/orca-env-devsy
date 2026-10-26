import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../src/activity_probe.mbt", import.meta.url), "utf8").split("\n").filter(line => line.trimStart().startsWith("#|")).map(line => line.trimStart().slice(2)).join("\n");
type Facts = { process?: string | null; children?: boolean; agent?: string; state?: string; program?: string; working?: boolean; queued?: number; prompts?: number; tasks?: number; truncated?: boolean; verdict?: string; nativeError?: boolean; emptyChats?: boolean; authoritative?: boolean; connected?: boolean; age?: number; pairing?: string; };
async function probe(f: Facts = {}) {
  let output = "";
  let finish!: () => void;
  const done = new Promise<void>(resolve => finish = resolve);
  class Client {
    remote = { endpoint: "unused" };
    async call(method: string) {
      const results: Record<string, unknown> = {
        "status.get": { appVersion: "1.4.241", graphStatus: "ready" },
        "terminal.list": { truncated: f.truncated ?? false, terminals: [{ handle: "t", worktreeId: "w", tabId: "tab", leafId: "leaf", connected: f.connected ?? true, agentIdentity: f.agent }] },
        "worktree.ps": { truncated: false, worktrees: [{ worktreeId: "w", unverifiableTerminalCount: 0, agents: f.agent ? [{ paneKey: "tab:leaf", agentType: f.agent, state: f.state ?? "done", programStatus: { state: f.program ?? "idle" } }] : [] }] },
        "terminal.inspectProcess": { process: { foregroundProcess: f.process ?? null, hasChildProcesses: f.children ?? false, foregroundProcessEvidence: { verdict: f.verdict ?? "live", capturedAgeMs: f.age ?? 2, observationEpoch: 1, ptyIncarnationId: "p" } } },
      };
      return { result: results[method] };
    }
  }
  const remote = {
    async subscribeRemoteRuntimeRequest(_r: unknown, _m: unknown, _p: unknown, _t: unknown, callbacks: { onResponse(r: unknown): void }) {
      queueMicrotask(() => callbacks.onResponse({ ok: true, result: { type: "snapshot", sessions: [], namingActiveSessionIds: [] } }));
      queueMicrotask(() => callbacks.onResponse({ ok: true, result: { type: "snapshot", sessions: f.emptyChats ? [] : [{ sessionId: "s", workspaceId: "w", agent: "codex", latestPrompt: "private prompt" }] } }));
      return { close() {} };
    },
    async sendRemoteRuntimeRequest(_r: unknown, method: string) {
      if (f.nativeError) throw Object.assign(new Error("secret token must not escape"), { code: "rpc_timeout" });
      return { ok: true, result: method === "session.tabs.listAll" ? { authoritative: f.authoritative ?? true } : { page: { working: f.working ?? false, queuedMessages: Array(f.queued ?? 0).fill({ text: "private" }), actionablePromptIds: Array(f.prompts ?? 0).fill("approval"), backgroundTasks: f.tasks ? { tasks: Array(f.tasks).fill({ command: "private" }) } : undefined } } };
    },
  };
  vm.runInNewContext(source, {
    require(name: string) {
      if (name === "node:fs") return { readFileSync: () => JSON.stringify({ pairingCode: f.pairing ?? "private-credential" }) };
      if (name.endsWith("/client.js")) return { RuntimeClient: Client };
      if (name.endsWith("/remote-runtime-client.js")) return remote;
      if (name.endsWith("/structured-agent-session-renderer-client-capabilities.js")) return { STRUCTURED_AGENT_SESSION_RENDERER_CLIENT_CAPABILITIES: ["agent-session.structured.v1", "agent-session.structured.registered-agents.v1"] };
      throw Error("unexpected module");
    },
    process: { env: { HOME: "/fixture" }, stdout: { write(s: string) { output += s; finish(); } } },
    setTimeout, clearTimeout, queueMicrotask, Date, Promise,
  });
  await done;
  expect(output).not.toContain("private");
  expect(output).not.toContain("secret token");
  return JSON.parse(output);
}

describe("VM activity observation", () => {
  test("silent foreground command stays active until the shell is restored", async () => {
    expect((await probe({ process: "sleep", children: true })).activity).toBe("active");
    expect((await probe()).activity).toBe("idle");
  });
  test("terminal agent idle -> active -> idle distinguishes CLI lifetime", async () => {
    const f = { agent: "codex", process: "codex" };
    expect((await probe(f)).activity).toBe("idle");
    expect((await probe({ ...f, state: "working", program: "working" })).activity).toBe("active");
    expect((await probe(f)).activity).toBe("idle");
    expect((await probe({ ...f, state: "waiting" })).activity).toBe("active");
  });
  test("native chat idle -> active -> idle and pending work", async () => {
    expect((await probe()).activity).toBe("idle");
    expect((await probe({ working: true })).activity).toBe("active");
    expect((await probe()).activity).toBe("idle");
    for (const f of [{ queued: 1 }, { prompts: 1 }, { tasks: 1 }]) expect((await probe(f)).activity).toBe("active");
    expect((await probe({ emptyChats: true })).activity).toBe("idle");
  });
  test("incomplete enumeration, stale evidence and inaccessible APIs never imply idle", async () => {
    for (const f of [{ truncated: true }, { verdict: "unverifiable" }, { connected: false }, { age: 6000 }, { nativeError: true }, { authoritative: false }, { pairing: "" }]) {
      expect((await probe(f)).activity).toBe("unknown");
    }
  });
});
