///|
priv suberror SettingsProcessError {
  SettingsProcessError(String, String, Int32)
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
fn settings_parent(path : String) -> String {
  let parts = path.split("/").to_array()
  parts[:parts.length() - 1].join("/")
}

///|
async fn host_orca_location() -> (String, String, String) {
  let home = environment("HOME")
  let user_data = @env.get_env_var("ORCA_USER_DATA_PATH")
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
  let metadata = @json.parse(
    @fs.read_file(user_data + "/orca-runtime.json").text(),
  )
  let pid = match field(metadata, "pid") {
    Some(Json::Number(value, ..)) if value > 1 && value == value.trunc() =>
      value.to_int()
    _ => raise AdapterError("Invalid host Orca runtime PID")
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
    let parent = settings_parent(executable)
    for
      resources in [
        parent + "/resources",
        settings_parent(parent) + "/Resources",
      ] {
      if @fs.exists(
          resources +
          "/app.asar.unpacked/out/main/persistence/profile-state/profile-state-domain-reader.js",
        ) {
        return (executable, resources, user_data)
      }
    }
  }
  raise AdapterError("Cannot locate the running host Orca resources")
}

///|
async fn host_orca_settings() -> String {
  let (executable, resources, user_data) = host_orca_location()
  let env = @env.get_env_vars()
  env.set("ELECTRON_RUN_AS_NODE", "1")
  env.remove("NODE_OPTIONS")
  env.remove("NODE_REPL_EXTERNAL_MODULE")
  settings_process(
    executable,
    ["-e", orca_settings_script(), "--", "export", resources, user_data],
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
        if ["load", "read", "normalize", "input", "profile", "write", "verify"].contains(
            phase,
          ) &&
          ["EACCES", "ENOENT", "EBUSY", "ENOSPC", "INCOMPATIBLE", "INVALID"].contains(
            code,
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
  @async.with_timeout(30000, async fn() {
    let payload = host_orca_settings()
    phase = "remote"
    let script = "unset NODE_OPTIONS NODE_REPL_EXTERNAL_MODULE; ORCA_USER_DATA_PATH=/worktrees/.orca ELECTRON_RUN_AS_NODE=1 \"$HOME/.local/share/orca-env-devsy/orca/current/orca-ide\" -e " +
      quote(orca_settings_script()) +
      " -- import \"$HOME/.local/share/orca-env-devsy/orca/current/resources\" /worktrees/.orca"
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
    #|const os = require('node:os');
    #|const assert = require('node:assert/strict');
    #|let phase = 'load';
    #|function main() {
    #|  const [mode, resources, userData] = process.argv.slice(-3);
    #|  const root = path.join(resources, 'app.asar.unpacked/out');
    #|  function load(name) { return require(path.join(root, name)); }
    #|  function dependency(entry, prefix) {
    #|    const id = require.resolve(path.join(root, entry));
    #|    require(id);
    #|    const matches = require.cache[id].children.filter(m => path.basename(m.filename).startsWith(prefix + '-'));
    #|    if (matches.length !== 1) throw new Error('INCOMPATIBLE');
    #|    return matches[0].exports;
    #|  }
    #|  const readerEntry = 'main/persistence/profile-state/profile-state-domain-reader.js';
    #|  const offlineEntry = 'main/persistence/profile-state/profile-state-offline-settings.js';
    #|  const reader = load(readerEntry);
    #|  function read(location) {
    #|    const result = reader.readProfileStateDomains(location.databaseFile, location.profileId, ['settings']);
    #|    if (result.kind !== 'values' || !result.values.has('settings')) throw new Error('INVALID');
    #|    return result;
    #|  }
    #|  function modelChoice(source) {
    #|    return {
    #|      selectedModelByAgent: source?.selectedModelByAgent ?? {},
    #|      selectedModelByAgentByHost: source?.selectedModelByAgentByHost?.local ? { local: source.selectedModelByAgentByHost.local } : {},
    #|      selectedThinkingByModel: source?.selectedThinkingByModel ?? {}
    #|    };
    #|  }
    #|  if (mode === 'export') {
    #|    phase = 'read';
    #|    const location = load('main/persistence/profile-state/profile-state-active-location.js').getActiveProfileStateLocation(userData);
    #|    const settings = read(location).values.get('settings');
    #|    phase = 'normalize';
    #|    const source = load('shared/source-control-ai-settings.js').normalizeSourceControlAiSettings(settings.sourceControlAi, settings.commitMessageAi);
    #|    const autoRename = load('shared/auto-rename-branch-from-work-settings.js').normalizeAutoRenameBranchFromWorkDefaultOn(settings);
    #|    const actions = {};
    #|    const modelOverridesByOperation = {};
    #|    for (const name of ['branchName', 'conversationName']) {
    #|      const action = source.actions[name];
    #|      actions[name] = Object.fromEntries(['agentId', 'commandInputTemplate', 'agentArgs'].filter(key => Object.hasOwn(action, key)).map(key => [key, action[key]]));
    #|      if (source.modelOverridesByOperation?.[name]) modelOverridesByOperation[name] = modelChoice(source.modelOverridesByOperation[name]);
    #|    }
    #|    const payload = {
    #|      defaultTuiAgent: settings.defaultTuiAgent ?? null,
    #|      disabledTuiAgents: settings.disabledTuiAgents ?? [],
    #|      ...autoRename,
    #|      branchPrefix: settings.branchPrefix ?? 'git-username',
    #|      branchPrefixCustom: settings.branchPrefixCustom ?? '',
    #|      sourceControlAi: { agentId: source.agentId, actions, ...modelChoice(source), modelOverridesByOperation }
    #|    };
    #|    process.stdout.write(JSON.stringify(payload));
    #|  } else if (mode === 'import') {
    #|    phase = 'input';
    #|    const input = fs.readFileSync(0, 'utf8');
    #|    if (Buffer.byteLength(input) > 4 * 1024 * 1024) throw new Error('INVALID');
    #|    const payload = JSON.parse(input);
    #|    phase = 'profile';
    #|    fs.mkdirSync(userData, { recursive: true, mode: 0o700 });
    #|    const maintenance = load('main/persistence/profile-state/profile-state-access.js').acquireProfileStateMaintenance(userData);
    #|    let database;
    #|    try {
    #|      const profile = load('main/orca-profiles/profile-index-store.js').ensureActiveOrcaProfile(userData);
    #|      const location = { databaseFile: profile.stateDatabaseFile, profileId: profile.profile.id };
    #|      const dbModule = dependency(readerEntry, 'profile-state-database');
    #|      const authority = dependency(offlineEntry, 'profile-state-sqlite-authority');
    #|      const constants = dependency(offlineEntry, 'constants');
    #|      let defaults;
    #|      for (const fn of [constants.s, constants.a]) {
    #|        if (typeof fn !== 'function') continue;
    #|        try { defaults = fn(os.homedir())?.settings; } catch { continue; }
    #|        if (defaults?.sourceControlAi?.actions) break;
    #|      }
    #|      if (!defaults?.sourceControlAi?.actions) throw new Error('INCOMPATIBLE');
    #|      database = dbModule.n(location.databaseFile, location.profileId);
    #|      const current = reader.readProfileStateDomainsWithRevisionFromDatabase(database.db, ['settings']);
    #|      if (current.kind !== 'values') throw new Error('INVALID');
    #|      const settings = { ...defaults, ...current.values.get('settings'), ...payload };
    #|      settings.sourceControlAi = { ...defaults.sourceControlAi, ...current.values.get('settings')?.sourceControlAi, ...payload.sourceControlAi,
    #|        actions: { ...defaults.sourceControlAi.actions, ...current.values.get('settings')?.sourceControlAi?.actions, ...payload.sourceControlAi.actions } };
    #|      phase = 'write';
    #|      authority.o(database.db, { domain: 'settings', payload: JSON.stringify(settings), expectedRevision: current.revision });
    #|      database.db.close();
    #|      database = undefined;
    #|      phase = 'verify';
    #|      const saved = read(location).values.get('settings');
    #|      for (const key of Object.keys(payload)) {
    #|        if (key === 'sourceControlAi') {
    #|          for (const name of Object.keys(payload.sourceControlAi)) {
    #|            if (name === 'actions') {
    #|              for (const action of Object.keys(payload.sourceControlAi.actions)) assert.deepEqual(saved.sourceControlAi.actions[action], payload.sourceControlAi.actions[action]);
    #|            } else assert.deepEqual(saved.sourceControlAi[name], payload.sourceControlAi[name]);
    #|          }
    #|        } else assert.deepEqual(saved[key], payload[key]);
    #|      }
    #|    } finally { database?.db.close(); maintenance.release(); }
    #|  } else throw new Error('INVALID');
    #|}
    #|try { main(); } catch (error) {
    #|  const code = ['EACCES', 'ENOENT', 'EBUSY', 'ENOSPC'].includes(error.code) ? error.code : error.message === 'INCOMPATIBLE' ? 'INCOMPATIBLE' : 'INVALID';
    #|  process.stderr.write(JSON.stringify({ phase, code }));
    #|  process.exitCode = 1;
    #|}
  script
}
