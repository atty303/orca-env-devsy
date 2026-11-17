///|
priv suberror SettingsProcessError {
  SettingsProcessError(String, String, Int32)
}

///|
impl Show for SettingsProcessError with fn output(self, logger) {
  logger.write_string(diagnostic_error(self))
}

///|
#borrow(buffer)
extern "C" fn process_executable(
  pid : Int32,
  buffer : Bytes,
  capacity : Int32,
) -> Int32 = "orca_process_executable"

///|
async fn settings_executable(pid : Int32) -> String {
  if @async.platform is Linux {
    return @fs.realpath("/proc/\{pid}/exe")
  }
  let buffer = Bytes::make(4096, 0)
  let length = process_executable(pid, buffer, buffer.length())
  guard length > 0 && length < buffer.length() else {
    raise AdapterError("Cannot locate the running host Orca executable")
  }
  @utf8.decode(buffer[:length])
}

///|
fn host_orca_user_data() -> String raise {
  let home = environment("HOME")
  @env.get_env_var("ORCA_USER_DATA_PATH")
  .filter(p => p != "")
  .unwrap_or(
    if @async.platform is MacOS {
      home + "/Library/Application Support/orca"
    } else {
      @env.get_env_var("XDG_CONFIG_HOME")
      .filter(p => p != "")
      .unwrap_or(home + "/.config") +
      "/orca"
    },
  )
}

///|
async fn host_orca_status(stage : String) -> Json {
  let cli = if @async.platform is Linux { "orca-ide" } else { "orca" }
  let output = command(
    cli,
    ["status", "--environment", "local", "--json"],
    stage,
  )
  let status = @json.parse(output) catch {
    _ => {
      save_diagnostic(stage, "invalid-response", error_type="invalid_json")
      raise AdapterError("Invalid host Orca status response")
    }
  }
  guard field(status, "ok") == Some(Json::boolean(true)) else {
    save_diagnostic(stage, "invalid-response", error_type="status_unavailable")
    raise AdapterError("Cannot query host Orca status")
  }
  let result = field(status, "result").unwrap_or(Json::null())
  let app = field(result, "app").unwrap_or(Json::null())
  guard field(app, "running") == Some(Json::boolean(true)) else {
    save_diagnostic(stage, "invalid-response", error_type="app_not_running")
    raise AdapterError("Host Orca is not running")
  }
  let profile_source = match @env.get_env_var("ORCA_USER_DATA_PATH") {
    None => "unset"
    Some("") => "empty"
    Some(_) => "environment"
  }
  let progress = Progress::new(stage)
  let profile = progress.safe_message(host_orca_user_data())
  save_diagnostic(stage, "validated", evidence={
    "profileSource": profile_source,
    "profilePath": profile.unwrap_or("[unavailable]"),
  })
  result
}

///|
async fn host_orca_location() -> (String, String, String) {
  let user_data = host_orca_user_data()
  let status = host_orca_status("host-orca-status")
  let app = field(status, "app").unwrap_or(Json::null())
  let pid = match field(app, "pid") {
    Some(Json::Number(value, ..)) if value > 1 && value == value.trunc() =>
      value.to_int()
    _ => {
      save_diagnostic(
        "host-orca-status",
        "invalid-response",
        error_type="invalid_pid",
      )
      raise AdapterError("Invalid host Orca runtime PID")
    }
  }
  let executables = [settings_executable(pid)]
  if @async.platform is Linux {
    let args = @fs.read_file("/proc/\{pid}/cmdline")
      .text()
      .split("\u0000")
      .to_array()
    for i = 0; i + 1 < args.length(); i = i + 1 {
      if args[i] == "--spawner-exec-path" {
        executables.push(args[i + 1].to_owned())
      }
    }
  }
  for executable in executables {
    let parts = executable.split("/").to_array()
    let parent = parts[:parts.length() - 1].join("/")
    let parent_parts = parent.split("/").to_array()
    let app_parent = parent_parts[:parent_parts.length() - 1].join("/")
    for resources in [parent + "/resources", app_parent + "/Resources"] {
      if @fs.exists(resources + "/app.asar") {
        return (executable, resources, user_data)
      }
    }
  }
  raise AdapterError("Cannot locate the running host Orca resources")
}

///|
async fn host_orca_settings() -> String {
  let (executable, _, user_data) = host_orca_location()
  let env = @env.get_env_vars()
  env.set("ELECTRON_RUN_AS_NODE", "1")
  env.remove("NODE_OPTIONS")
  env.remove("NODE_REPL_EXTERNAL_MODULE")
  settings_process(
    executable,
    ["-e", orca_settings_script(), "--", "export", user_data],
    environment=env,
  )
}

///|
async fn settings_process(
  program : String,
  args : Array[String],
  environment~ : Map[String, String],
  input? : String,
) -> String {
  let (stdin, writer) = @process.write_to_process()
  defer writer.close()
  @async.with_task_group(async fn(group) {
    let output = group.spawn(async fn() {
      @process.collect_output(
        program[:],
        args[:],
        extra_env=environment,
        inherit_env=false,
        stdin~,
      )
    })
    if input is Some(value) {
      writer.write(value)
    }
    writer.close()
    let (status, stdout, stderr) = output.wait()
    guard status == 0 else {
      let (phase, code) = try {
        let error = @json.parse(stderr.text())
        let phase = required(error, "phase")
        let code = required(error, "code")
        if [
            "load", "read", "normalize", "input", "initialize", "profile", "write",
            "verify",
          ].contains(phase) &&
          (
            [
              "EACCES", "ENOENT", "EBUSY", "ENOSPC", "INCOMPATIBLE", "INVALID", "SERVER_START",
              "SERVER_TIMEOUT", "SERVER_STOP", "PROFILE_MISSING",
            ].contains(code) ||
            (
              code.has_prefix("SERVER_EXIT_") &&
              code.length() > 12 &&
              code.length() <= 15 &&
              code[12:].iter().all(c => c >= '0' && c <= '9')
            ) ||
            [
              "SERVER_SPAWN_EAGAIN", "SERVER_SPAWN_EACCES", "SERVER_SPAWN_OTHER",
              "SERVER_SIGNAL_SIGTERM", "SERVER_SIGNAL_SIGKILL", "SERVER_SIGNAL_OTHER",
            ].contains(code)
          ) {
          (phase, code)
        } else {
          ("process", "process_exit")
        }
      } catch {
        _ => ("process", "process_exit")
      }
      raise SettingsProcessError(phase, code, status)
    }
    guard stdout.binary().length() <= 4194304 else {
      raise AdapterError("Orca settings result exceeds size limit")
    }
    stdout.text()
  })
}

///|
async fn initialize_orca_settings(state : Json) -> Unit {
  let mut phase = "host"
  save_diagnostic("orca-settings", "started")
  progress_message("orca-settings: running…")
  @async.with_timeout(120000, async fn() {
    let payload = host_orca_settings()
    phase = "remote"
    let script = "unset NODE_OPTIONS NODE_REPL_EXTERNAL_MODULE; export ORCA_USER_DATA_PATH=/worktrees/.orca; " +
      orca_remote_functions() +
      "export ORCA_ADAPTER_CLI=\"$base/bin/orca-ide\"; if test ! -x \"$ORCA_ADAPTER_CLI\"; then unset ORCA_ADAPTER_CLI; fi; orca_node -e " +
      quote(orca_settings_script()) +
      " -- import /worktrees/.orca " +
      quote(required(state, "projectRoot"))
    let env = workspace_environment(state)
    ignore(
      settings_process(
        workspace_program(state, "ssh"),
        mux_ssh_args(state) + [script],
        environment=env,
        input=payload,
      ),
    )
  }) catch {
    SettingsProcessError(helper_phase, code, status) => {
      save_diagnostic(
        "orca-settings",
        "failed",
        phase=phase + "/" + helper_phase,
        error_type=code,
        exit_code=status,
      )
      raise AdapterError(
        "Orca settings transfer failed (exit \{status}, " +
        phase +
        "/" +
        helper_phase +
        ": " +
        code +
        ")",
      )
    }
    @async.TimeoutError as error => {
      save_diagnostic("orca-settings", "timeout", phase~, error_type="timeout")
      raise error
    }
    error => {
      save_diagnostic(
        "orca-settings",
        if @async.is_being_cancelled() {
          "cancelled"
        } else {
          "failed"
        },
        phase~,
        error_type=if error is AdapterError(_) {
          "settings_source"
        } else {
          "settings_transfer"
        },
      )
      raise error
    }
  }
  save_diagnostic("orca-settings", "success", phase~)
  progress_message("orca-settings: done")
}

///|
fn orca_settings_script() -> String {
  let script =
    #|const fs = require('node:fs');
    #|const path = require('node:path');
    #|const { DatabaseSync } = require('node:sqlite');
    #|const crypto = require('node:crypto');
    #|let phase = 'load';
    #|function location(userData) {
    #|  const index = JSON.parse(fs.readFileSync(path.join(userData, 'orca-profile-index.json'), 'utf8'));
    #|  const id = index.activeProfileId;
    #|  if (typeof id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(id) || !Array.isArray(index.profiles) || !index.profiles.some(p => p?.id === id)) throw new Error('INVALID');
    #|  return path.join(userData, 'profiles', id, 'profile-state.db');
    #|}
    #|function select(object, keys) { return Object.fromEntries(keys.filter(key => Object.hasOwn(object, key)).map(key => [key, object[key]])); }
    #|function model(source) {
    #|  return { ...select(source, ['selectedModelByAgent', 'selectedThinkingByModel']), ...(source.selectedModelByAgentByHost?.local ? { selectedModelByAgentByHost: { local: source.selectedModelByAgentByHost.local } } : {}) };
    #|}
    #|async function initialize(userData, projectRoot) {
    #|  const { spawn } = require('node:child_process');
    #|  const net = require('node:net');
    #|  const cli = path.join(path.dirname(process.execPath), 'resources/app.asar/out/cli/index.js');
    #|  const serverCli = process.env.ORCA_ADAPTER_CLI;
    #|  const child = spawn(serverCli || process.execPath, [...serverCli ? [] : [cli], 'serve', '--no-pairing', '--bind', '127.0.0.1', '--port', '47121', '--project-root', projectRoot], { stdio: 'ignore', detached: true });
    #|  let exited = false;
    #|  const done = new Promise(resolve => { child.once('error', error => { exited = true; resolve({ spawn: ['EAGAIN', 'EACCES'].includes(error.code) ? error.code : 'OTHER' }); }); child.once('exit', (code, signal) => { exited = true; resolve({ code, signal }); }); });
    #|  const kill = signal => { if (child.pid) try { process.kill(-child.pid, signal); } catch (e) { if (e.code !== 'ESRCH') throw e; } };
    #|  const interrupted = () => { try { kill('SIGKILL'); } finally { process.exit(1); } };
    #|  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.once(signal, interrupted);
    #|  try {
    #|    const until = Date.now() + 60000;
    #|    let ready = false;
    #|    while (!ready && !exited && Date.now() < until) {
    #|      ready = await new Promise(resolve => { const socket = net.createConnection({ host: '127.0.0.1', port: 47121 }); socket.setTimeout(300); socket.once('connect', () => { socket.destroy(); resolve(true); }); socket.once('error', () => resolve(false)); socket.once('timeout', () => { socket.destroy(); resolve(false); }); });
    #|      if (!ready) await new Promise(resolve => setTimeout(resolve, 200));
    #|    }
    #|    if (exited) { const exit = await done; throw new Error(exit.spawn ? 'SERVER_SPAWN_' + exit.spawn : exit.signal ? 'SERVER_SIGNAL_' + (['SIGTERM', 'SIGKILL'].includes(exit.signal) ? exit.signal : 'OTHER') : 'SERVER_EXIT_' + exit.code); }
    #|    if (!ready) throw new Error('SERVER_TIMEOUT');
    #|    if (!fs.existsSync(location(userData))) throw new Error('PROFILE_MISSING');
    #|    kill('SIGINT');
    #|    const stopped = await Promise.race([done, new Promise(resolve => { const timer = setTimeout(() => resolve(null), 15000); timer.unref(); })]);
    #|    if (!stopped || stopped.code !== 0) throw new Error('SERVER_STOP');
    #|  } finally {
    #|    if (!exited) { kill('SIGKILL'); await done; }
    #|    for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.removeListener(signal, interrupted);
    #|  }
    #|}
    #|async function main() {
    #|  const [mode, userData, projectRoot] = process.argv.slice(1);
    #|  if (mode === 'export') {
    #|    phase = 'read';
    #|    let settings;
    #|    const deadline = Date.now() + 8000;
    #|    while (true) {
    #|      const db = new DatabaseSync(location(userData), { readOnly: true });
    #|      try { const row = db.prepare("SELECT payload FROM profile_state_documents WHERE domain = 'settings'").get(); if (!row) throw new Error('INVALID'); settings = JSON.parse(row.payload); } finally { db.close(); }
    #|      if (settings.sourceControlAi?.actions && settings.autoRenameBranchFromWorkDefaultedOn === true) break;
    #|      if (Date.now() >= deadline) throw new Error('INCOMPATIBLE');
    #|      await new Promise(resolve => setTimeout(resolve, 200));
    #|    }
    #|    phase = 'normalize';
    #|    const source = settings.sourceControlAi;
    #|    const actions = {};
    #|    const overrides = {};
    #|    for (const name of ['branchName', 'conversationName']) {
    #|      if (source.actions[name]) actions[name] = select(source.actions[name], ['agentId', 'commandInputTemplate', 'agentArgs']);
    #|      if (source.modelOverridesByOperation?.[name]) overrides[name] = model(source.modelOverridesByOperation[name]);
    #|    }
    #|    const payload = { ...select(settings, ['defaultTuiAgent', 'disabledTuiAgents', 'autoRenameBranchFromWork', 'autoRenameBranchFromWorkDefaultedOn', 'branchPrefix', 'branchPrefixCustom']), sourceControlAi: { ...select(source, ['agentId']), ...model(source), actions, modelOverridesByOperation: overrides } };
    #|    process.stdout.write(JSON.stringify(payload));
    #|  } else if (mode === 'import') {
    #|    phase = 'input';
    #|    const input = fs.readFileSync(0, 'utf8');
    #|    if (Buffer.byteLength(input) > 4 * 1024 * 1024) throw new Error('INVALID');
    #|    const payload = JSON.parse(input);
    #|    phase = 'initialize';
    #|    await initialize(userData, projectRoot);
    #|    phase = 'profile';
    #|    const db = new DatabaseSync(location(userData));
    #|    try {
    #|      const row = db.prepare("SELECT payload FROM profile_state_documents WHERE domain = 'settings'").get();
    #|      if (!row) throw new Error('INVALID');
    #|      const current = JSON.parse(row.payload);
    #|      const settings = { ...current, ...payload, sourceControlAi: { ...current.sourceControlAi, ...payload.sourceControlAi, actions: { ...current.sourceControlAi?.actions, ...payload.sourceControlAi.actions } } };
    #|      const serialized = JSON.stringify(settings);
    #|      phase = 'write';
    #|      db.exec('BEGIN IMMEDIATE');
    #|      try {
    #|        const revision = Number(db.prepare("SELECT value FROM profile_state_meta WHERE key = 'revision'").get()?.value) + 1;
    #|        if (!Number.isSafeInteger(revision)) throw new Error('INVALID');
    #|        db.prepare("UPDATE profile_state_documents SET payload=?, revision=?, updated_at=?, content_hash=? WHERE domain='settings'").run(serialized, revision, Date.now(), crypto.createHash('sha256').update(serialized, 'utf8').digest('hex'));
    #|        db.prepare("UPDATE profile_state_meta SET value=? WHERE key='revision'").run(String(revision));
    #|        db.exec('COMMIT');
    #|      } catch (error) { db.exec('ROLLBACK'); throw error; }
    #|    } finally { db.close(); }
    #|  } else throw new Error('INVALID');
    #|}
    #|main().catch(error => {
    #|  const code = ['EACCES', 'ENOENT', 'EBUSY', 'ENOSPC'].includes(error.code) ? error.code : ['INCOMPATIBLE', 'SERVER_TIMEOUT', 'SERVER_STOP', 'PROFILE_MISSING'].includes(error.message) || /^SERVER_(?:SPAWN_(?:EAGAIN|EACCES|OTHER)|EXIT_\d{1,3}|SIGNAL_(?:SIGTERM|SIGKILL|OTHER))$/.test(error.message) ? error.message : 'INVALID';
    #|  process.stderr.write(JSON.stringify({ phase, code }));
    #|  process.exitCode = 1;
    #|});
  script
}
