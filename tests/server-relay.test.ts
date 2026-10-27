import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import vm from "node:vm";

const sourceFile = readFileSync(new URL("../src/server_update.mbt", import.meta.url), "utf8");
const section = sourceFile.slice(sourceFile.indexOf("fn server_update_process_script("), sourceFile.indexOf("fn server_update_swap_script("));
const source = section.split("\n").filter(line => line.trimStart().startsWith("#|")).map(line => line.trimStart().slice(2)).join("\n");
type Options = { server?: string; daemon?: string | null; relay?: string; mode?: string; badIdentity?: boolean; unreadable?: boolean; changeIdentity?: boolean; profileKey?: string };
function run(options: Options = {}) {
  const server = options.server ?? "current";
  const daemon = options.daemon === undefined ? "current" : options.daemon;
  const relay = options.relay ?? "current";
  const signals: number[] = [];
  let output = "";
  const ended = new Set<number>();
  const noFile = () => Object.assign(new Error("missing"), { code: "ENOENT" });
  const stat = (pid: number) => `${pid} (node) ${ended.has(pid) ? "Z" : "S"} ${Array.from({ length: 18 }, () => "0").join(" ")} ${pid === 202 && options.changeIdentity && ended.has(101) ? "changed" : pid === 101 ? "server-ticks" : "daemon-ticks"} 0`;
  const fs = {
    readFileSync(name: string) {
      if (name === "/proc/net/tcp") return "header\n0: 0100007F:B811 00000000:0000 0A 0 0 0 0 0 123\n";
      if (name === "/proc/net/tcp6") return "header\n";
      if (name === "/proc/sys/kernel/random/boot_id") return "boot";
      if (name === "/profile/daemon/daemon-v52.pid") return JSON.stringify({ pid: 202, linuxStartTicks: options.badIdentity ? "wrong" : "daemon-ticks", entryPath: "/orca/daemon-entry.js", bootId: "boot" });
      if (name === "/proc/101/stat") return stat(101);
      if (name === "/proc/202/stat" && daemon !== null) return stat(202);
      if (name === "/proc/101/cmdline") return Buffer.from("node\0/orca/orcad-server.js\0--project-root\0/repo\0");
      if (name === "/proc/202/cmdline" && daemon !== null) return Buffer.from("node\0/orca/daemon-entry.js\0");
      if (name === "/proc/101/environ") return Buffer.from(`${options.profileKey ?? "ORCA_USER_DATA_PATH"}=/profile\0DEVSY_GH_INSTANCE=${server}\0`);
      if (name === "/proc/202/environ" && daemon !== null) {
        if (options.unreadable) throw Object.assign(new Error("denied"), { code: "EACCES" });
        return Buffer.from(`${options.profileKey ?? "ORCA_USER_DATA_PATH"}=/profile\0DEVSY_GH_INSTANCE=${daemon}\0`);
      }
      throw noFile();
    },
    readdirSync(name: string) {
      if (name === "/proc") return daemon === null ? ["101"] : ["101", "202"];
      if (name === "/profile/daemon") return daemon === null ? [] : ["daemon-v52.pid"];
      if (name === "/proc/101/fd") return ["3"];
      if (name === "/proc/202/fd") return [];
      throw noFile();
    },
    readlinkSync(name: string) { if (name === "/proc/101/fd/3") return "socket:[123]"; throw noFile(); },
    statSync() { return { uid: 1000 }; },
    realpathSync(name: string) { return name; },
  };
  const exit = Symbol("exit");
  try {
    vm.runInNewContext(source, {
      require(name: string) {
        if (name === "fs") return fs;
        if (name === "path") return path;
        if (name === "child_process") return { execFileSync: () => JSON.stringify({ instance: relay }) };
        throw Error(`unexpected module ${name}`);
      },
      process: { argv: ["node", "/repo", "", options.mode ?? "verify"], stdout: { write(value: string) { output += value; } }, exit() { throw exit; }, kill(pid: number, signal: string) { if (signal !== "SIGTERM") throw Error("unexpected signal"); signals.push(pid); ended.add(pid); } },
      global: {}, setTimeout(fn: () => void) { fn(); }, Date, Buffer,
    });
  } catch (error) { if (error !== exit) throw error; }
  return { result: JSON.parse(output), signals };
}

test("a stale daemon triggers coordinated restart after the server", () => {
  expect(run({ daemon: "old" }).result.outcome).toBe("mismatch");
  const stopped = run({ daemon: "old", mode: "sync" });
  expect(stopped.result.outcome).toBe("restart");
  expect(stopped.signals).toEqual([101, 202]);
});

test("absent and unset daemons do not trigger a restart", () => {
  expect(run({ daemon: null, mode: "sync" }).result.outcome).toBe("match");
  expect(run({ daemon: "", mode: "sync" }).signals).toEqual([]);
  expect(run({ profileKey: "ORCA_USER_DATA" }).result.outcome).toBe("match");
  expect(run({ server: "", daemon: "", mode: "sync" }).result.outcome).toBe("skip");
  expect(run({ server: "", daemon: null, relay: "new", mode: "verify-required" }).result).toMatchObject({ outcome: "skip", relayInstance: "new" });
});

test("an unverifiable or replaced daemon is never stopped", () => {
  expect(() => run({ daemon: "old", badIdentity: true, mode: "sync" })).toThrow("Cannot verify Orca daemon ownership");
  expect(() => run({ daemon: "old", unreadable: true, mode: "sync" })).toThrow("Cannot read Orca daemon environment");
  expect(() => run({ daemon: "old", changeIdentity: true, mode: "sync" })).toThrow("Orca daemon ownership changed");
});
