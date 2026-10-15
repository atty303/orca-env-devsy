import { _electron, type ElectronApplication } from "playwright";
import { mkdir, chmod, rm, realpath } from "node:fs/promises";
import { resolve } from "node:path";
import { budgets, measure } from "./timing.ts";
import { DiagnosticError } from "./diagnostics.ts";
import { OrcaObservations } from "./observations.ts";
import { run, until, type Environment } from "../../scripts/process.ts";

export type Runtime = {
  id: string; workspaceId?: string; status: string; cleanupStatus?: string;
  recipeResult: { userData: Record<string, unknown>; connection: { type: string; projectRoot: string; pairingCode?: string } };
  sshTargetId?: string; runtimeEnvironmentId?: string;
};
export type Provision = { ok: boolean; error?: unknown; stderr?: string; stdout?: string; runtime: Runtime; sshTargetId?: string; environment?: { id: string } };

export async function latestOrca() {
  const headers: Record<string, string> = { "Accept": "application/vnd.github+json" };
  if (process.env.GITHUB_TOKEN) headers.Authorization = "Bearer " + process.env.GITHUB_TOKEN;
  const response = await fetch("https://api.github.com/repos/stablyai/orca/releases/latest", { headers, signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`Orca release lookup failed (${response.status})`);
  const release = await response.json() as { tag_name: string; assets: { name: string; browser_download_url: string; digest?: string }[] };
  const version = release.tag_name.replace(/^v/, "");
  const name = process.platform === "darwin" ? `Orca-${version}-arm64-mac.zip` : process.arch === "arm64" ? "orca-linux-arm64.AppImage" : "orca-linux.AppImage";
  const asset = release.assets.find(asset => asset.name === name);
  if (!asset) throw new Error("Latest Orca has no artifact for this host");
  const root = resolve(`.tools/e2e/orca/${release.tag_name}/${process.platform}-${process.arch}`);
  const executable = process.platform === "darwin" ? root + "/Orca.app/Contents/MacOS/Orca" : root + "/squashfs-root/orca-ide";
  if (!await Bun.file(executable).exists()) {
    await mkdir(root, { recursive: true });
    const archive = root + "/" + name;
    const download = await fetch(asset.browser_download_url, { signal: AbortSignal.timeout(120_000) });
    if (!download.ok) throw new Error("Orca artifact download failed");
    await Bun.write(archive, download);
    if (asset.digest && "sha256:" + new Bun.CryptoHasher("sha256").update(await Bun.file(archive).bytes()).digest("hex") !== asset.digest) throw new Error("Orca artifact checksum mismatch");
    if (process.platform === "darwin") await run(["ditto", "-xk", archive, root], { timeout: 180_000 });
    else { await chmod(archive, 0o755); await run([archive, "--appimage-extract"], { cwd: root, timeout: 180_000 }); }
    await rm(archive);
  }
  return { version, executable };
}

export class Orca {
  private constructor(readonly app: ElectronApplication, readonly bridgeId: number, readonly observations: OrcaObservations) {}
  static async launch(executable: string, profile: string, env: Environment) {
    await mkdir(env.HOME!, { recursive: true, mode: 0o700 });
    const home = await realpath(env.HOME!);
    const app = await _electron.launch({ executablePath: executable,
      args: ["--user-data-dir=" + profile, ...(process.platform === "darwin" ? ["--password-store=basic", "--use-mock-keychain"] : ["--no-sandbox", "--disable-dev-shm-usage", "--password-store=basic"])],
      env: { ...env, ...(process.platform === "linux" ? { DISPLAY: process.env.DISPLAY, XAUTHORITY: process.env.XAUTHORITY } : {}), HOME: home, USERPROFILE: home, ORCA_USER_DATA_PATH: profile, ORCA_E2E_USER_DATA_DIR: profile, ORCA_E2E_HOME_DIR: home, ORCA_E2E_HEADLESS: "1" } as Record<string, string>, timeout: 60_000 });
    const observations = new OrcaObservations(env.ORCA_ENV_DEVSY_RECORDING !== "0");
    app.on("console", message => {
      const text = message.text().slice(0, 16_384);
      if (!observations.acceptsConsole(text)) return;
      observations.captureConsole(text, async () => {
        const args = message.args();
        const argument = args.length > 1 ? await args[args.length - 1].evaluate(value => {
          const seen = new Set<object>();
          let remaining = 32;
          let truncated = false;
          const read = (value: unknown, depth: number): unknown => {
            if (remaining-- <= 0) { truncated = true; return undefined; }
            if (typeof value === "string") {
              if (value.length > 16_384) truncated = true;
              return value.slice(0, 16_384);
            }
            if (typeof value === "number" && Number.isInteger(value) && Math.abs(value) <= 255) return value;
            if (!value || typeof value !== "object") return undefined;
            if (depth >= 4 || seen.has(value)) { truncated = true; return undefined; }
            seen.add(value);
            const fields: Record<string, unknown> = {};
            for (const key of ["name", "message", "code", "exitCode", "signal", "reason", "cause", "error"]) {
              if (key in value) fields[key] = read((value as Record<string, unknown>)[key], depth + 1);
            }
            return fields;
          };
          const result = read(value, 0);
          return { value: result, truncated };
        }) : { value: text, truncated: false };
        if (argument.truncated) observations.recordingFailure();
        return argument.value;
      });
    });
    const actual = await app.evaluate(({ app }) => app.getPath("home"));
    if (await realpath(actual) !== home) { app.process().kill("SIGKILL"); throw new Error("Orca escaped disposable HOME"); }
    // The release's own preload is the transport. No handler functions, renderer
    // orchestration or persisted Orca state are copied into this driver.
    const id = await app.evaluate(async ({ app, BrowserWindow }) => {
      const bridge = new BrowserWindow({ show: false, webPreferences: { preload: app.getAppPath() + "/out/preload/index.js", contextIsolation: true, sandbox: true } });
      await bridge.loadURL("about:blank");
      return bridge.id;
    });
    if (observations.enabled) {
      try {
        let bridge: ReturnType<ElectronApplication["windows"]>[number] | undefined;
        await until(async () => {
          const windows = await Promise.all(app.windows().map(async page => ({ page, id: await (await app.browserWindow(page)).evaluate(window => window.id) })));
          bridge = windows.find(window => window.id === id)?.page;
          return bridge !== undefined;
        }, 2000);
        if (bridge) {
          await bridge.exposeFunction("__orcaE2EObserve", (event: { provisionId?: unknown; stream?: unknown; chunk?: unknown }) => { try { observations.provision(event); } catch { observations.recordingFailure(); } });
          await bridge.evaluate(() => {
            const view = window as unknown as { api: { ephemeralVm: { onProvisionEvent(callback: (event: unknown) => void): () => void } }; __orcaE2EObserve(event: unknown): Promise<void> };
            view.api.ephemeralVm.onProvisionEvent(event => { void view.__orcaE2EObserve(event).catch(() => {}); });
          });
        }
      } catch { observations.recordingFailure(); }
    }
    return new Orca(app, id, observations);
  }
  async call<T>(section: string, method: string, args?: unknown): Promise<T> {
    console.log(`IPC ${section}.${method}: started`);
    const provisionId = section === "ephemeralVm" && method === "provision" ? (args as { provisionId?: unknown } | undefined)?.provisionId : undefined;
    const workspace = typeof provisionId === "string" && /^provision-[0-3]$/.test(provisionId) ? Number(provisionId.slice(-1)) : undefined;
    if (workspace !== undefined) this.observations.begin(workspace);
    const operation = this.app.evaluate(async ({ BrowserWindow }, request) => {
      const bridge = BrowserWindow.fromId(request.id);
      if (!bridge) throw new Error("IPC bridge window disappeared");
      return await bridge.webContents.executeJavaScript(`window.api[${JSON.stringify(request.section)}][${JSON.stringify(request.method)}](${request.args === undefined ? "" : JSON.stringify(request.args)})`);
    }, { id: this.bridgeId, section, method, args }) as T;
    let timer: ReturnType<typeof setTimeout>;
    const budget = method === "provision" ? budgets.provision : ["resumeWorkspace", "suspendWorkspace", "cleanup"].includes(method) ? budgets.lifecycle : budgets.operation;
    try {
      const result = await measure(`ipc-${section}.${method}`, budget, () => Promise.race([operation, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(`IPC ${section}.${method} exceeded deadline`)), budget); })]));
      if (workspace !== undefined) this.observations.finish(workspace, result as { ok: boolean; error?: unknown; stderr?: string; stdout?: string });
      console.log(`IPC ${section}.${method}: completed`);
      return result;
    } catch (error) {
      if (workspace !== undefined) this.observations.finish(workspace, { ok: false, error });
      throw new DiagnosticError(error);
    } finally { clearTimeout(timer!); }
  }
  async close(timeout = budgets.operation) {
    let timer: ReturnType<typeof setTimeout>;
    console.log("Orca close: started");
    try {
      await measure("orca-close", timeout, () => Promise.race([
        this.app.close(),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => {
            try { this.app.process().kill("SIGKILL"); } catch { /* Closing still fails at the deadline. */ }
            reject(new Error("Orca close deadline exceeded"));
          }, timeout);
        }),
      ]));
      console.log("Orca close: completed");
    } catch (error) {
      console.log("Orca close: failed");
      throw error;
    } finally { clearTimeout(timer!); }
  }
}
