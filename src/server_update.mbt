///|
priv struct ServerUpdateOptions {
  provider : String?
  workspace : String?
  force : Bool
}

///|
fn server_update_options(args : Array[String]) -> ServerUpdateOptions raise {
  let mut provider = None
  let mut workspace = None
  let mut force = false
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--provider" if provider is None && i + 1 < args.length() => {
        i += 1
        guard valid_context(args[i]) else {
          raise AdapterError("Invalid provider")
        }
        provider = Some(args[i])
      }
      "--workspace" if workspace is None && i + 1 < args.length() => {
        i += 1
        guard valid_workspace_id(args[i]) else {
          raise AdapterError("Invalid workspace ID")
        }
        workspace = Some(args[i])
      }
      "--force" if !force => force = true
      _ => raise AdapterError("Invalid update option: " + args[i])
    }
    i += 1
  }
  guard workspace is None || provider is Some(_) else {
    raise AdapterError("--workspace requires --provider")
  }
  { provider, workspace, force, }
}

///|
fn server_version(value : String) -> Array[Int32] raise {
  let parts = value.split(".").to_array()
  guard parts.length() == 3 &&
    parts
    .iter()
    .all(part => {
      part.length() > 0 &&
      part.length() <= 9 &&
      part.iter().all(c => c >= '0' && c <= '9')
    }) else {
    raise AdapterError("Unsupported Orca version: " + value)
  }
  parts.map(part => @string.parse_int(part))
}

///|
fn server_version_is_older(target : String, current : String) -> Bool raise {
  let a = server_version(target)
  let b = server_version(current)
  for i = 0; i < 3; i = i + 1 {
    if a[i] != b[i] {
      return a[i] < b[i]
    }
  }
  false
}

///|
async fn desktop_orca_version() -> String {
  let (executable, resources, _) = host_orca_location()
  let env = @env.get_env_vars()
  env.set("ELECTRON_RUN_AS_NODE", "1")
  env.remove("NODE_OPTIONS")
  env.remove("NODE_REPL_EXTERNAL_MODULE")
  let version = command(
      executable,
      [resources + "/app.asar/out/cli/index.js", "--version"],
      "desktop-orca-version",
      environment=env,
    )
    .trim()
    .to_owned()
  ignore(server_version(version))
  version
}

///|
fn server_update_locked(script : String) -> String {
  let body = "trap 'rmdir \"$HOME/.local/share/orca-env-devsy/orca/update-active\"' EXIT; sh -c " +
    quote(script)
  "marker=\"$HOME/.local/share/orca-env-devsy/orca/update-active\"; mkdir \"$marker\" 2>/dev/null || { printf 'Another update may be running or its marker needs inspection\\n' >&2; exit 1; }; sh -c " +
  quote(body) +
  " & child=$!; wait \"$child\""
}

///|
async fn update_remote(state : Json, script : String, stage : String) -> String {
  remote(state, server_update_locked(script), stage)
}

///|
fn server_update_prepare_script(version : String) -> String {
  let script =
    #|set -eu
    #|version=VERSION
    #|case "$(uname -s)-$(uname -m)" in
    #|  Linux-x86_64) asset=orca-linux.AppImage ;;
    #|  Linux-aarch64) asset=orca-linux-arm64.AppImage ;;
    #|  *) printf 'Unsupported remote Orca platform\n' >&2; exit 1 ;;
    #|esac
    #|base="$HOME/.local/share/orca-env-devsy/orca"
    #|candidate="$base/update-$version"
    #|umask 077
    #|if test -e "$base/current"; then test -d "$base/current" && test ! -L "$base/current"; else test -d "$base/update-previous" && test ! -L "$base/update-previous"; fi
    #|if test -e "$candidate"; then
    #|  test -d "$candidate" && test ! -L "$candidate"
    #|else
    #|  work=$(mktemp -d "$base/update.XXXXXX")
    #|  trap 'rm -rf "$work"' EXIT
    #|  curl -fLsS "https://github.com/stablyai/orca/releases/download/v$version/$asset" -o "$work/orca.AppImage"
    #|  chmod +x "$work/orca.AppImage"
    #|  (cd "$work" && ./orca.AppImage --appimage-extract >/dev/null)
    #|  test -x "$work/squashfs-root/orca-ide"
    #|  actual=$(ELECTRON_RUN_AS_NODE=1 "$work/squashfs-root/orca-ide" "$work/squashfs-root/resources/app.asar/out/cli/index.js" --version)
    #|  test "$actual" = "$version"
    #|  mv "$work/squashfs-root" "$candidate"
    #|fi
    #|actual=$(ELECTRON_RUN_AS_NODE=1 "$candidate/orca-ide" "$candidate/resources/app.asar/out/cli/index.js" --version)
    #|test "$actual" = "$version"
  script.replace_all(old="VERSION", new=quote(version))
}

///|
fn server_update_process_script(
  root : String,
  version? : String,
  relay_mode? : String,
) -> String {
  let script =
    #|const fs = require('fs');
    #|const root = process.argv[1];
    #|const expectedVersion = process.argv[2];
    #|const relayMode = process.argv[3];
    #|const inodes = new Set();
    #|for (const table of ['tcp', 'tcp6']) {
    #|  for (const row of fs.readFileSync('/proc/net/' + table, 'utf8').trim().split('\n').slice(1)) {
    #|    const f = row.trim().split(/\s+/);
    #|    if (parseInt(f[1].split(':')[1], 16) === 47121 && f[3] === '0A') inodes.add('socket:[' + f[9] + ']');
    #|  }
    #|}
    #|if (!inodes.size) { if (expectedVersion) throw Error('Orca Server is not listening'); process.exit(0); }
    #|const owners = [];
    #|for (const pid of fs.readdirSync('/proc').filter(x => /^\d+$/.test(x))) {
    #|  try {
    #|    const dir = '/proc/' + pid;
    #|    if (!fs.readdirSync(dir + '/fd').some(fd => { try { return inodes.has(fs.readlinkSync(dir + '/fd/' + fd)); } catch (_) { return false; } })) continue;
    #|    const args = fs.readFileSync(dir + '/cmdline').toString().split('\0');
    #|    if (!args.some(x => x.endsWith('/orcad-server.js')) || !args.some((x,i) => x === '--project-root' && args[i+1] === root)) throw Error('Port owner is not the expected Orca Server');
    #|    owners.push(Number(pid));
    #|  } catch (e) { if (e.code !== 'ENOENT' && e.code !== 'EACCES' && e.code !== 'EPERM') throw e; }
    #|}
    #|if (owners.length !== 1) throw Error('Cannot identify a unique Orca Server port owner');
    #|const owner = owners[0];
    #|const identity = fs.readFileSync('/proc/' + owner + '/stat', 'utf8').split(') ').pop().split(' ')[19];
    #|if (relayMode) {
    #|  const path = require('path');
    #|  const readEnv = pid => Object.fromEntries(fs.readFileSync('/proc/' + pid + '/environ').toString().split('\0').filter(x => x.includes('=')).map(x => { const i = x.indexOf('='); return [x.slice(0, i), x.slice(i + 1)]; }));
    #|  const serverEnv = readEnv(owner);
    #|  const profile = serverEnv.ORCA_USER_DATA || serverEnv.ORCA_USER_DATA_PATH || serverEnv.ORCA_SERVE_USER_DATA_PATH;
    #|  if (!profile || !path.isAbsolute(profile)) throw Error('Cannot identify Orca Server profile');
    #|  const realProfile = fs.realpathSync(profile);
    #|  const serverInstance = serverEnv.DEVSY_GH_INSTANCE || '';
    #|  const daemonDir = path.join(realProfile, 'daemon');
    #|  let entries;
    #|  try { entries = fs.readdirSync(daemonDir); } catch (e) { if (e.code !== 'ENOENT') throw e; entries = []; }
    #|  const records = new Map();
    #|  let invalidRecord = false;
    #|  for (const file of entries.filter(x => /^daemon-v[^/]+\.pid$/.test(x))) {
    #|    let record;
    #|    try { record = JSON.parse(fs.readFileSync(path.join(daemonDir, file), 'utf8')); } catch (e) { if (e instanceof SyntaxError) { invalidRecord = true; continue; } throw e; }
    #|    if (!record || !Number.isSafeInteger(record.pid) || record.pid <= 0 || typeof record.linuxStartTicks !== 'string' && typeof record.linuxStartTicks !== 'number' || typeof record.entryPath !== 'string' || records.has(record.pid)) { invalidRecord = true; continue; }
    #|    records.set(record.pid, record);
    #|  }
    #|  const daemons = [];
    #|  const uid = fs.statSync('/proc/' + owner).uid;
    #|  for (const pid of fs.readdirSync('/proc').filter(x => /^\d+$/.test(x))) {
    #|    let stat;
    #|    try { stat = fs.statSync('/proc/' + pid); } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
    #|    if (stat.uid !== uid) continue;
    #|    let args;
    #|    try { args = fs.readFileSync('/proc/' + pid + '/cmdline').toString().split('\0'); } catch (e) { if (e.code === 'ENOENT' || e.code === 'ESRCH') continue; throw Error('Cannot inspect Orca daemon processes'); }
    #|    if (!args.some(x => x.endsWith('/daemon-entry.js'))) continue;
    #|    let env;
    #|    try { env = readEnv(pid); } catch (e) { if (e.code === 'ENOENT' || e.code === 'ESRCH') continue; throw Error('Cannot read Orca daemon environment'); }
    #|    const daemonProfile = env.ORCA_USER_DATA || env.ORCA_USER_DATA_PATH || env.ORCA_SERVE_USER_DATA_PATH;
    #|    if (!daemonProfile) throw Error('Cannot identify Orca daemon profile');
    #|    if (fs.realpathSync(daemonProfile) !== realProfile) continue;
    #|    if (invalidRecord) throw Error('Invalid or ambiguous Orca daemon PID records');
    #|    const record = records.get(Number(pid));
    #|    const ticks = fs.readFileSync('/proc/' + pid + '/stat', 'utf8').split(') ').pop().split(' ')[19];
    #|    if (!record || String(record.linuxStartTicks) !== ticks || !args.includes(record.entryPath)) throw Error('Cannot verify Orca daemon ownership');
    #|    const boot = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
    #|    if (typeof record.bootId !== 'string' || record.bootId !== boot) throw Error('Cannot verify Orca daemon boot identity');
    #|    daemons.push({pid:Number(pid), ticks, entry:record.entryPath, instance:env.DEVSY_GH_INSTANCE || ''});
    #|  }
    #|  if (daemons.length > 1) throw Error('Cannot identify a unique Orca daemon');
    #|  const daemon = daemons[0];
    #|  const daemonInstance = daemon ? daemon.instance : null;
    #|  if (serverInstance.length > 1024 || daemonInstance && daemonInstance.length > 1024) throw Error('Orca relay instance exceeds limit');
    #|  let relayInstance = null;
    #|  if (serverInstance || daemonInstance || relayMode === 'verify-required') {
    #|    const cp = require('child_process');
    #|    const raw = cp.execFileSync('curl', ['--disable', '--noproxy', '*', '--silent', '--show-error', '--fail', '--max-time', '2', '--max-filesize', '4096', 'http://localhost:12049/ready'], {encoding:'utf8', timeout:3000});
    #|    const ready = JSON.parse(raw);
    #|    if (typeof ready.instance !== 'string' || !ready.instance || ready.instance.length > 1024) throw Error('Relay instance unavailable');
    #|    relayInstance = ready.instance;
    #|  }
    #|  const mismatch = serverInstance && serverInstance !== relayInstance || daemonInstance && daemonInstance !== relayInstance;
    #|  const outcome = mismatch ? 'mismatch' : serverInstance || daemonInstance ? 'match' : 'skip';
    #|  const evidence = {outcome, serverInstance, daemonInstance, relayInstance};
    #|  if (!mismatch || relayMode.startsWith('verify')) { process.stdout.write(JSON.stringify(evidence)); process.exit(0); }
    #|  global.relayEvidence = {...evidence, outcome:'restart'};
    #|  global.relayDaemon = daemon;
    #|}
    #|if (expectedVersion) {
    #|  const env = fs.readFileSync('/proc/' + owners[0] + '/environ').toString().split('\0');
    #|  if (!env.includes(expectedVersion)) throw Error('Listening Orca Server is not the updated process');
    #|  process.exit(0);
    #|}
    #|const currentStat = fs.readFileSync('/proc/' + owner + '/stat', 'utf8').split(') ').pop().split(' ')[19];
    #|const currentArgs = fs.readFileSync('/proc/' + owner + '/cmdline').toString().split('\0');
    #|if (identity !== currentStat || !currentArgs.some(x => x.endsWith('/orcad-server.js')) || !currentArgs.some((x,i) => x === '--project-root' && currentArgs[i+1] === root) || !fs.readdirSync('/proc/' + owner + '/fd').some(fd => { try { return inodes.has(fs.readlinkSync('/proc/' + owner + '/fd/' + fd)); } catch (_) { return false; } })) throw Error('Orca Server ownership changed');
    #|process.kill(owner, 'SIGTERM');
    #|const deadline = Date.now() + 10000;
    #|const finish = () => {
    #|  const daemon = global.relayDaemon;
    #|  if (!daemon) { if (relayMode) process.stdout.write(JSON.stringify(global.relayEvidence)); return; }
    #|  const dir = '/proc/' + daemon.pid;
    #|  let stat, args;
    #|  try { stat = fs.readFileSync(dir + '/stat', 'utf8'); args = fs.readFileSync(dir + '/cmdline').toString().split('\0'); } catch (e) { if (e.code === 'ENOENT' || e.code === 'ESRCH') { process.stdout.write(JSON.stringify(global.relayEvidence)); return; } throw e; }
    #|  if (stat.split(') ').pop().split(' ')[19] !== daemon.ticks || !args.includes(daemon.entry)) throw Error('Orca daemon ownership changed');
    #|  process.kill(daemon.pid, 'SIGTERM');
    #|  const daemonDeadline = Date.now() + 10000;
    #|  const waitDaemon = () => { try { const current = fs.readFileSync(dir + '/stat', 'utf8'); if (/\) Z /.test(current)) { process.stdout.write(JSON.stringify(global.relayEvidence)); return; } if (current.split(') ').pop().split(' ')[19] !== daemon.ticks) throw Error('Orca daemon identity changed while stopping'); } catch (e) { if (e.code === 'ENOENT' || e.code === 'ESRCH') { process.stdout.write(JSON.stringify(global.relayEvidence)); return; } throw e; } if (Date.now() >= daemonDeadline) throw Error('Orca daemon did not stop'); setTimeout(waitDaemon, 100); };
    #|  waitDaemon();
    #|};
    #|const wait = () => { try { const stat = fs.readFileSync('/proc/' + owner + '/stat', 'utf8'); if (/\) Z /.test(stat)) { finish(); return; } process.kill(owner, 0); } catch (e) { if (e.code === 'ESRCH' || e.code === 'ENOENT') { finish(); return; } throw e; } if (Date.now() >= deadline) throw Error('Orca Server did not stop'); setTimeout(wait, 100); };
    #|wait();
  (if relay_mode is Some(mode) {
    "# orca-server-relay-" + mode + "\n"
  } else {
    ""
  }) +
  "base=\"$HOME/.local/share/orca-env-devsy/orca\"; binary=\"$base/current/orca-ide\"; if test ! -x \"$binary\"; then binary=\"$base/update-previous/orca-ide\"; fi; ELECTRON_RUN_AS_NODE=1 \"$binary\" -e " +
  quote(script) +
  " " +
  quote(root) +
  " " +
  quote(version.unwrap_or("")) +
  " " +
  quote(relay_mode.unwrap_or(""))
}

///|
fn server_update_swap_script(version : String) -> String {
  let script =
    #|set -eu
    #|base="$HOME/.local/share/orca-env-devsy/orca"
    #|candidate="$base/update-"VERSION
    #|previous="$base/update-previous"
    #|test -d "$candidate" && test ! -L "$candidate"
    #|if test ! -e "$previous"; then
    #|  test -d "$base/current" && test ! -L "$base/current"
    #|  mv "$base/current" "$previous"
    #|else
    #|  test -d "$previous" && test ! -L "$previous"
    #|  if test -e "$base/current"; then
    #|    test -d "$base/current" && test ! -L "$base/current"
    #|    if test -e "$base/update-retry"; then test -d "$base/update-retry" && test ! -L "$base/update-retry"; rm -rf "$base/update-retry"; fi
    #|    mv "$base/current" "$base/update-retry"
    #|  fi
    #|fi
    #|mv "$candidate" "$base/current"
  script.replace_all(old="VERSION", new=quote(version))
}

///|
async fn cleanup_server_update(state : Json) -> Unit {
  let directory = required(state, "tunnelDirectory")
  ignore(
    update_remote(
      state, "base=\"$HOME/.local/share/orca-env-devsy/orca\"; rm -rf \"$base/update-previous\" \"$base/update-retry\"",
      "server-update-cleanup",
    ),
  )
  @fs.remove(directory + "/server-update-complete")
}

///|
async fn update_one_server(
  state : Json,
  provider : String,
  version : String,
  force : Bool,
) -> Json {
  let directory = required(state, "tunnelDirectory")
  let result : Json = {
    "id": required(state, "workspaceId"),
    "provider": provider,
    "context": required(state, "context"),
    "targetVersion": version,
    "outcome": "failed",
  }
  let mut phase = "identity"
  try {
    let operation = connection_operation_lock(state)
    defer operation.close()
    let current = workspace(state)
    guard current is Some(current) &&
      field(current, "uid") == field(state, "workspaceUid") &&
      field(field(current, "provider").unwrap_or(Json::null()), "name") ==
      Some(Json::string(provider)) else {
      raise AdapterError(
        "Workspace is missing, replaced, or has a different provider",
      )
    }
    phase = "workspace-status"
    let status = workspace_status(state)
    set_field(result, "workspaceStatus", Json::string(status))
    if status == "Stopped" {
      set_field(result, "outcome", Json::string("skipped"))
      set_field(result, "reason", Json::string("workspace_stopped"))
      save_diagnostic(
        "server-update",
        "skipped",
        evidence=result,
        tunnel_directory=directory,
        recording=workspace_recording(state),
      )
      return result
    }
    guard status == "Running" else {
      raise AdapterError("Workspace is not running")
    }
    phase = "transport"
    ensure_ssh_worker(state, Some(reserve_server_port(state)))
    let lock = @fs.open(
      directory + "/server.lock",
      mode=ReadWrite,
      create_mode=OpenOrCreate,
      permission=0o600,
    )
    defer lock.close()
    @async.with_timeout(30000, async fn() {
      while !lock.try_lock(Exclusive) {
        @async.sleep(100)
      }
    })
    if @fs.exists(directory + "/server-update-complete") {
      cleanup_server_update(state)
    }
    let pending = @fs.exists(directory + "/server-update-pending")
    set_field(result, "retry", Json::boolean(pending))
    phase = "version"
    let installed = update_remote(
        state, "base=\"$HOME/.local/share/orca-env-devsy/orca\"; dir=\"$base/current\"; if test ! -x \"$dir/orca-ide\"; then dir=\"$base/update-previous\"; fi; ELECTRON_RUN_AS_NODE=1 \"$dir/orca-ide\" \"$dir/resources/app.asar/out/cli/index.js\" --version",
        "server-update-version",
      )
      .trim()
      .to_owned()
    ignore(server_version(installed))
    set_field(result, "previousVersion", Json::string(installed))
    if server_version_is_older(version, installed) && !force {
      raise AdapterError("Server downgrade requires --force")
    }
    phase = "prepare"
    if !pending {
      ignore(
        update_remote(
          state, "test ! -e \"$HOME/.local/share/orca-env-devsy/orca/update-previous\" && test ! -e \"$HOME/.local/share/orca-env-devsy/orca/update-retry\"",
          "server-update-ownership",
        ),
      )
    }
    ignore(
      update_remote(
        state,
        server_update_prepare_script(version),
        "server-update-prepare",
      ),
    )
    phase = "identity-recheck"
    let current = workspace(state)
    guard current is Some(current) &&
      field(current, "uid") == field(state, "workspaceUid") &&
      field(field(current, "provider").unwrap_or(Json::null()), "name") ==
      Some(Json::string(provider)) &&
      workspace_status(state) == "Running" else {
      raise AdapterError("Workspace changed before Server update")
    }
    @fs.write_file(
      directory + "/server-update-pending",
      version,
      permission=0o600,
    )
    phase = "stop"
    ignore(
      update_remote(
        state,
        server_update_process_script(required(state, "projectRoot")),
        "server-update-stop",
      ),
    )
    phase = "switch"
    ignore(
      update_remote(
        state,
        server_update_swap_script(version),
        "server-update-switch",
      ),
    )
    phase = "start"
    let launch_id = version +
      ":" +
      recording_run_id +
      ":" +
      required(state, "workspaceUid")
    let mut marker_name = "ORCA_ENV_DEVSY_UPDATE_" + recording_run_id
    while field(
            field(state, "serverEnv").unwrap_or(Json::empty_object()),
            marker_name,
          )
          is Some(_) {
      marker_name = marker_name + "_"
    }
    ignore(launch_server(state, update_marker=(marker_name, launch_id)))
    phase = "verify"
    let actual = update_remote(
        state, "base=\"$HOME/.local/share/orca-env-devsy/orca/current\"; ELECTRON_RUN_AS_NODE=1 \"$base/orca-ide\" \"$base/resources/app.asar/out/cli/index.js\" --version",
        "server-update-verify-version",
      )
      .trim()
      .to_owned()
    guard actual == version else {
      raise AdapterError("Updated Server version does not match Desktop")
    }
    @async.with_timeout(15000, async fn() {
      while !server_is_running(state) {
        @async.sleep(200)
      }
    })
    ignore(
      update_remote(
        state,
        server_update_process_script(
          required(state, "projectRoot"),
          version=marker_name + "=" + launch_id,
        ),
        "server-update-verify-owner",
      ),
    )
    phase = "commit"
    @fs.rename(
      directory + "/server-update-pending",
      directory + "/server-update-complete",
      replace=true,
    )
    cleanup_server_update(state) catch {
      error =>
        set_field(
          result,
          "cleanupWarning",
          Json::string(
            diagnostic_error(error, environment=workspace_environment(state)),
          ),
        )
    }
    set_field(result, "outcome", Json::string("success"))
    save_diagnostic(
      "server-update",
      "success",
      evidence=result,
      tunnel_directory=directory,
      recording=workspace_recording(state),
    )
  } catch {
    error => {
      set_field(result, "phase", Json::string(phase))
      set_field(
        result,
        "error",
        Json::string(
          diagnostic_error(error, environment=workspace_environment(state)),
        ),
      )
      set_field(
        result,
        "recoverySuppressed",
        Json::boolean(@fs.exists(directory + "/server-update-pending")),
      )
      save_diagnostic(
        "server-update",
        "failed",
        phase~,
        error_type="server_update_failed",
        evidence=result,
        tunnel_directory=directory,
        recording=workspace_recording(state),
      )
    }
  }
  result
}

///|
pub async fn update_server(args : Array[String]) -> Unit {
  let options = server_update_options(args)
  let version = desktop_orca_version()
  let base = adapter_state_home() + "/tunnels"
  let states : Array[Json] = []
  let errors : Array[Json] = []
  let results : Array[Json] = []
  let discovery_counts : Map[String, Int32] = Map([])
  if @fs.exists(base) {
    for name in @fs.readdir(base, sort=true) {
      let directory = base + "/" + name
      let mut discovery_phase = "kind"
      try {
        if @fs.kind(directory, follow_symlink=false) != @fs.FileKind::Directory ||
          !@fs.exists(directory + "/enabled") {
          continue
        }
        discovery_phase = "read"
        let raw = @fs.read_file(directory + "/state.json").text()
        discovery_phase = "parse"
        let state = @json.parse(raw)
        if options.workspace is Some(id) &&
          field(state, "workspaceId") is Some(Json::String(saved_id)) &&
          saved_id != id {
          continue
        }
        discovery_phase = "validate"
        validate_state(state)
        if field(state, "connection") != Some(Json::string("orca-server")) {
          continue
        }
        if options.workspace is Some(id) &&
          field(state, "workspaceId") != Some(Json::string(id)) {
          continue
        }
        ignore(required(state, "workspaceUid"))
        ignore(required(state, "context"))
        set_field(state, "tunnelDirectory", Json::string(directory))
        states.push(state)
      } catch {
        error => {
          let kind = discovery_phase +
            ":" +
            process_error_type(diagnostic_error(error))
          discovery_counts.set(
            kind,
            discovery_counts.get(kind).unwrap_or(0) + 1,
          )
          errors.push({
            "savedState": directory,
            "error": diagnostic_error(error),
          })
        }
      }
    }
  }
  let batch_recording = errors.is_empty() &&
    states.iter().all(workspace_recording)
  save_diagnostic(
    "server-update-batch",
    "started",
    evidence={
      "provider": options.provider.map(Json::string).unwrap_or(Json::null()),
      "workspace": options.workspace.map(Json::string).unwrap_or(Json::null()),
      "force": options.force,
      "targetVersion": version,
    },
    recording=batch_recording &&
      @env.get_env_var("ORCA_ENV_DEVSY_RECORDING") != Some("0"),
  )
  if !batch_recording && !errors.is_empty() {
    let classes : Array[Json] = []
    for (kind, count) in discovery_counts {
      classes.push({ "class": kind, "count": count })
    }
    save_diagnostic(
      "server-update-discovery",
      "failed",
      error_type="saved_state_invalid",
      evidence={ "classes": classes },
    )
  }
  let keys : Map[String, Int32] = Map([])
  for state in states {
    let key = required(state, "context") + ":" + required(state, "workspaceUid")
    keys.set(key, keys.get(key).unwrap_or(0) + 1)
  }
  let selected : Array[(Json, String)] = []
  for state in states {
    try {
      let key = required(state, "context") +
        ":" +
        required(state, "workspaceUid")
      guard keys.get(key) == Some(1) else {
        raise AdapterError("Duplicate saved workspace identity")
      }
      let current = workspace(state)
      guard current is Some(current) else {
        raise AdapterError("Workspace is missing")
      }
      let provider = required(
        field(current, "provider").unwrap_or(Json::null()),
        "name",
      )
      if options.provider is Some(filter) && provider != filter {
        continue
      }
      selected.push((state, provider))
    } catch {
      error =>
        errors.push({
          "workspace": required(state, "workspaceId"),
          "error": diagnostic_error(
            error,
            environment=workspace_environment(state),
          ),
        })
    }
  }
  if options.workspace is Some(_) && selected.length() != 1 {
    errors.push({ "error": "Workspace selection is missing or ambiguous" })
  }
  if options.workspace is None || (selected.length() == 1 && errors.is_empty()) {
    for (state, provider) in selected {
      results.push(update_one_server(state, provider, version, options.force))
    }
  }
  let failed = results
    .filter(row => field(row, "outcome") == Some(Json::string("failed")))
    .length() +
    errors.length()
  let output : Json = {
    "schemaVersion": 1,
    "action": "update",
    "targetVersion": version,
    "workspaces": results,
    "errors": errors,
    "failed": failed,
  }
  @stdio.stdout.write(output.stringify(indent=2) + "\n")
  save_diagnostic(
    "server-update-batch",
    if failed == 0 {
      "success"
    } else {
      "failed"
    },
    evidence=output,
    recording=batch_recording &&
      @env.get_env_var("ORCA_ENV_DEVSY_RECORDING") != Some("0"),
  )
  guard failed == 0 else { raise AdapterError("Some Server updates failed") }
}
