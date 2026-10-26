import { _electron, type ElectronApplication } from "playwright";
import { mkdir, chmod, rm, realpath } from "node:fs/promises";
import { resolve } from "node:path";
import { budgets, measure } from "./timing.ts";
import { DiagnosticError } from "./diagnostics.ts";
import { OrcaObservations } from "./observations.ts";
import { run, until, withAbort, type Environment } from "../../scripts/process.ts";

export type Runtime = {
  id: string; workspaceId?: string; status: string; cleanupStatus?: string;
  recipeResult: { userData: Record<string, unknown>; connection: { type: string; projectRoot: string; pairingCode?: string } };
  sshTargetId?: string; runtimeEnvironmentId?: string;
};
export type Provision = { ok: boolean; error?: unknown; stderr?: string; stdout?: string; runtime: Runtime; sshTargetId?: string; environment?: { id: string } };

export async function ensureOrcaInstallation(root: string, executable: string, install: () => Promise<void>) {
  const marker = root + "/.extraction-complete";
  if (await Bun.file(executable).exists() && await Bun.file(marker).text().catch(() => "") === "complete\n") return;
  await rm(marker, { force: true });
  await install();
  if (!await Bun.file(executable).exists()) throw new Error("Orca extraction did not produce an executable");
  await Bun.write(marker, "complete\n");
}

export async function latestOrca(signal?: AbortSignal) {
  const headers: Record<string, string> = { "Accept": "application/vnd.github+json" };
  if (process.env.GITHUB_TOKEN) headers.Authorization = "Bearer " + process.env.GITHUB_TOKEN;
  const response = await fetch("https://api.github.com/repos/stablyai/orca/releases/latest", { headers, signal: AbortSignal.any([AbortSignal.timeout(30_000), ...signal ? [signal] : []]) });
  if (!response.ok) throw new Error(`Orca release lookup failed (${response.status})`);
  const release = await response.json() as { tag_name: string; assets: { name: string; browser_download_url: string; digest?: string }[] };
  const version = release.tag_name.replace(/^v/, "");
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error("Stable Orca release has an invalid version");
  const name = process.platform === "darwin" ? `Orca-${version}-arm64-mac.zip` : process.arch === "arm64" ? "orca-linux-arm64.AppImage" : "orca-linux.AppImage";
  const asset = release.assets.find(asset => asset.name === name);
  if (!asset) throw new Error("Selected Orca release has no artifact for this host");
  const root = resolve(`.tools/e2e/orca/${release.tag_name}/${process.platform}-${process.arch}`);
  const executable = process.platform === "darwin" ? root + "/Orca.app/Contents/MacOS/Orca" : root + "/squashfs-root/orca-ide";
  await ensureOrcaInstallation(root, executable, async () => {
    await mkdir(root, { recursive: true });
    const archive = root + "/" + name;
    const download = await fetch(asset.browser_download_url, { signal: AbortSignal.any([AbortSignal.timeout(120_000), ...signal ? [signal] : []]) });
    if (!download.ok) throw new Error("Orca artifact download failed");
    await Bun.write(archive, download);
    if (asset.digest && "sha256:" + new Bun.CryptoHasher("sha256").update(await Bun.file(archive).bytes()).digest("hex") !== asset.digest) throw new Error("Orca artifact checksum mismatch");
    if (process.platform === "darwin") await run(["ditto", "-xk", archive, root], { timeout: 180_000, signal });
    else { await chmod(archive, 0o755); await run([archive, "--appimage-extract"], { cwd: root, timeout: 180_000, signal }); }
    await rm(archive);
  });
  return { version, executable };
}

export class Orca {
  private constructor(readonly app: ElectronApplication, readonly bridgeId: number, readonly observations: OrcaObservations, readonly signal?: AbortSignal) {}
  private static readonly launches = new Set<Promise<boolean>>();
  static launch(executable: string, profile: string, env: Environment, signal?: AbortSignal, launchApplication: typeof _electron.launch = options => _electron.launch(options)) {
    const owner = { cleanupFailed: false };
    const operation = this.launchOwned(executable, profile, env, signal, launchApplication, owner).catch(error => { throw new DiagnosticError(error); });
    this.launches.add(operation.then(() => !owner.cleanupFailed, () => !owner.cleanupFailed));
    return withAbort(signal, () => operation);
  }
  static async settleLaunches(signal: AbortSignal) {
    const pending = [...this.launches];
    const results = await withAbort(signal, () => Promise.all(pending));
    for (const launch of pending) this.launches.delete(launch);
    if (results.some(ok => !ok)) throw new Error("Orca launch cleanup failed");
  }
  private static async launchOwned(executable: string, profile: string, env: Environment, signal: AbortSignal | undefined, launchApplication: typeof _electron.launch, owner: { cleanupFailed: boolean }) {
    signal?.throwIfAborted();
    await withAbort(signal, () => mkdir(env.HOME!, { recursive: true, mode: 0o700 }));
    const home = await withAbort(signal, () => realpath(env.HOME!));
    signal?.throwIfAborted();
    let acquired: ElectronApplication | undefined;
    const observations = new OrcaObservations(env.ORCA_ENV_DEVSY_RECORDING !== "0");
    const executionSignal = signal;
    try {
      const app = await measure("electron-launch", budgets.lifecycle, async () => {
        acquired = await launchApplication({ executablePath: executable,
      args: ["--user-data-dir=" + profile, ...(process.platform === "darwin" ? ["--password-store=basic", "--use-mock-keychain"] : ["--no-sandbox", "--disable-dev-shm-usage", "--password-store=basic"])],
      env: { ...env, ...(process.platform === "linux" ? { DISPLAY: process.env.DISPLAY, XAUTHORITY: process.env.XAUTHORITY } : {}), HOME: home, USERPROFILE: home, ORCA_USER_DATA_PATH: profile, ORCA_E2E_USER_DATA_DIR: profile, ORCA_E2E_HOME_DIR: home, ORCA_E2E_HEADLESS: "1" } as Record<string, string>, timeout: budgets.lifecycle });
        return acquired;
      });
      signal = AbortSignal.any([AbortSignal.timeout(budgets.lifecycle), ...signal ? [signal] : []]);
      signal?.throwIfAborted();
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
      const actual = await measure("electron-home", budgets.lifecycle, () => withAbort(signal, () => app.evaluate(({ app }) => app.getPath("home"))));
      if (await withAbort(signal, () => realpath(actual)) !== home) { app.process().kill("SIGKILL"); throw new Error("Orca escaped disposable HOME"); }
      const hostEnv = await measure("electron-environment", budgets.lifecycle, () => withAbort(signal, () => app.evaluate(() => ({ home: process.env.HOME, git: process.env.GIT_CONFIG_GLOBAL, agent: process.env.SSH_AUTH_SOCK, path: process.env.PATH }))));
      for (const [name, actual, expected] of [["HOME", hostEnv.home, env.HOME], ["GIT_CONFIG_GLOBAL", hostEnv.git, env.GIT_CONFIG_GLOBAL], ["SSH_AUTH_SOCK", hostEnv.agent, env.SSH_AUTH_SOCK]]) {
        if (actual !== expected) throw new Error("Orca fixture environment mismatch: " + name);
      }
      if (!env.PATH || !hostEnv.path?.split(":").includes(env.PATH.split(":")[0])) throw new Error("Orca fixture environment mismatch: PATH");
      // The release's own preload is the transport. No handler functions, renderer
      // orchestration or persisted Orca state are copied into this driver.
      const id = await measure("electron-bridge", budgets.lifecycle, () => withAbort(signal, () => app.evaluate(async ({ app, BrowserWindow }) => {
        const bridge = new BrowserWindow({ show: false, webPreferences: { preload: app.getAppPath() + "/out/preload/index.js", contextIsolation: true, sandbox: true } });
        await bridge.loadURL("about:blank");
        return bridge.id;
      })));
      if (observations.enabled) {
        try {
          let bridge: ReturnType<ElectronApplication["windows"]>[number] | undefined;
          await until(async () => {
            const windows = await Promise.all(app.windows().map(async page => ({ page, id: await (await app.browserWindow(page)).evaluate(window => window.id) })));
            bridge = windows.find(window => window.id === id)?.page;
            return bridge !== undefined;
          }, 2000, signal);
          if (bridge) {
            await withAbort(signal, () => bridge!.exposeFunction("__orcaE2EObserve", (event: { provisionId?: unknown; stream?: unknown; chunk?: unknown }) => { try { observations.provision(event); } catch { observations.recordingFailure(); } }));
            await withAbort(signal, () => bridge!.evaluate(() => {
              const view = window as unknown as { api: { ephemeralVm: { onProvisionEvent(callback: (event: unknown) => void): () => void } }; __orcaE2EObserve(event: unknown): Promise<void> };
              view.api.ephemeralVm.onProvisionEvent(event => { void view.__orcaE2EObserve(event).catch(() => {}); });
            }));
          }
        } catch { observations.recordingFailure(); }
      }
      signal?.throwIfAborted();
      return new Orca(app, id, observations, executionSignal);
    } catch (error) {
      if (acquired) await new Orca(acquired, 0, observations).close().catch(() => { owner.cleanupFailed = true; });
      throw error;
    }
  }
  async call<T>(section: string, method: string, args?: unknown, signal = this.signal): Promise<T> {
    signal?.throwIfAborted();
    console.log(`IPC ${section}.${method}: started`);
    const provisionId = section === "ephemeralVm" && method === "provision" ? (args as { provisionId?: unknown } | undefined)?.provisionId : undefined;
    const workspace = typeof provisionId === "string" && /^provision-[0-3]$/.test(provisionId) ? Number(provisionId.slice(-1)) : undefined;
    if (workspace !== undefined) this.observations.begin(workspace);
    const operation = this.app.evaluate(async ({ BrowserWindow }, request) => {
      const bridge = BrowserWindow.fromId(request.id);
      if (!bridge) throw new Error("IPC bridge window disappeared");
      return await bridge.webContents.executeJavaScript(`(async () => {
        try { return { ok: true, value: await window.api[${JSON.stringify(request.section)}][${JSON.stringify(request.method)}](${request.args === undefined ? "" : JSON.stringify(request.args)}) }; }
        catch (error) { return { ok: false, error: { name: error?.name, message: error?.message, code: error?.code } }; }
      })()`);
    }, { id: this.bridgeId, section, method, args }).then(reply => {
      if (!reply.ok) throw reply.error;
      return reply.value as T;
    });
    let timer: ReturnType<typeof setTimeout>;
    const budget = method === "provision" ? budgets.provision : ["resumeWorkspace", "sleep", "cleanup"].includes(method) ? budgets.lifecycle : budgets.operation;
    try {
      const result = await measure(`ipc-${section}.${method}`, budget, () => withAbort(signal, () => Promise.race([operation, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(`IPC ${section}.${method} exceeded deadline`)), budget); })])));
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
