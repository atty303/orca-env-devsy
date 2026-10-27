///|
async fn worker_alive(directory : String) -> Bool {
  let lock = @fs.open(
    directory + "/worker.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  !lock.try_lock(Exclusive)
}

///|
async fn tunnel_status(
  directory : String,
  status : String,
  recording? : Bool,
) -> Unit {
  let value : Json = { "status": status, "runId": recording_run_id }
  @fs.write_file(directory + "/status.tmp", value.stringify(), permission=0o600)
  @fs.rename(
    directory + "/status.tmp",
    directory + "/status.json",
    replace=true,
  )
  save_diagnostic("orca-tunnel", status, tunnel_directory=directory, recording?)
}

///|
async fn adapter_executable() -> String {
  let name = @env.args()[0]
  if name.contains("/") {
    return @fs.realpath(name)
  }
  for directory in @env.get_env_var("PATH").unwrap_or("").split(":") {
    let path = directory.to_owned() + "/" + name
    if @fs.exists(path) {
      return @fs.realpath(path)
    }
  }
  raise AdapterError("Adapter executable is unavailable for tunnel recovery")
}

///|
async fn saved_proxy_executable() -> String {
  let directory = adapter_state_home()
  @fs.mkdir(directory, recursive=true, permission=0o700, allow_exist=true)
  let lock = @fs.open(
    directory + "/launcher.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  @async.with_timeout(10000, async fn() {
    while !lock.try_lock(Exclusive) {
      @async.sleep(10)
    }
  })
  let target = directory + "/ssh-proxy-adapter"
  let executable = adapter_executable()
  if executable == target {
    return target
  }
  save_diagnostic("ssh-proxy-launcher", "started")
  errdefer save_diagnostic(
    "ssh-proxy-launcher",
    "failed",
    error_type="filesystem",
  )
  let binary = @fs.read_file(executable).binary()
  if !@fs.exists(target) || @fs.read_file(target).binary() != binary {
    // A private executable copy survives package-manager pruning. Rename keeps
    // active proxies valid while create/resume/recover refresh future calls.
    let temporary = directory + "/ssh-proxy-adapter.tmp"
    defer (@fs.remove(temporary) catch { _ => () })
    @fs.write_file(temporary, binary, permission=0o700)
    @fs.rename(temporary, target, replace=true)
  }
  save_diagnostic("ssh-proxy-launcher", "success")
  target
}

///|
fn adapter_state_home() -> String raise {
  let root = match @env.get_env_var("XDG_STATE_HOME") {
    Some(value) if value != "" => value
    _ => environment("HOME") + "/.local/state"
  }
  guard root.has_prefix("/") else {
    raise AdapterError("XDG_STATE_HOME must be absolute")
  }
  root + "/orca-env-devsy"
}

///|
fn control_socket(state : Json, directory : String) -> String {
  match field(state, "socketDirectory") {
    Some(Json::String(value)) => value + "/socket"
    _ => directory + "/socket"
  }
}

///|
async fn stop_tunnel_master(
  state : Json,
  directory : String,
  verify~ : Bool = false,
) -> Unit {
  if @fs.exists(control_socket(state, directory)) {
    @async.with_timeout(2000, async fn() {
      ignore(
        @process.collect_output(
          workspace_program(state, "ssh"),
          extra_env=workspace_environment(state),
          cwd?=workspace_directory(state).map(path => path[:]),
          inherit_env=false,
          ssh_mux_options(state, directory) + ["-O", "exit"],
        ),
      )
    }) catch {
      _ => ()
    }
    if verify {
      @async.with_timeout(5000, async fn() {
        while @fs.exists(control_socket(state, directory)) {
          let (code, _, _) = @process.collect_output(
            workspace_program(state, "ssh"),
            extra_env=workspace_environment(state),
            cwd?=workspace_directory(state).map(path => path[:]),
            inherit_env=false,
            ssh_mux_options(state, directory) + ["-O", "check"],
          )
          if code != 0 {
            break
          }
          @async.sleep(100)
        }
      })
    }
  }
  if field(state, "socketDirectory") is Some(Json::String(socket_directory)) {
    if @fs.exists(socket_directory + "/socket") {
      @fs.remove(socket_directory + "/socket")
    }
    wait_ssh_proxy(state, "primary")
    let lease = socket_directory + "/primary-proxy.lock"
    if @fs.exists(lease) {
      @fs.remove(lease)
    }
    @fs.rmdir(socket_directory) catch {
      _ => ()
    }
  }
}

///|
async fn ensure_ssh_worker(
  state : Json,
  port : Int32?,
  deadline? : UInt64,
  restart~ : Bool = false,
) -> Unit {
  let mut expires = deadline.unwrap_or(connection_deadline())
  let base = adapter_state_home() + "/tunnels"
  @fs.mkdir(base, recursive=true, permission=0o700, allow_exist=true)
  let directory = match field(state, "tunnelDirectory") {
    Some(Json::String(old)) if old.has_prefix(base + "/") && @fs.exists(old) =>
      old
    _ => {
      if restart &&
        field(state, "tunnelDirectory") is Some(Json::String(old)) &&
        @fs.exists(old) {
        let lease = @fs.open(
          old + "/startup.lock",
          mode=ReadWrite,
          create_mode=OpenOrCreate,
          permission=0o600,
        )
        defer lease.close()
        @async.with_timeout(30000, async fn() {
          while !lease.try_lock(Exclusive) {
            @async.sleep(100)
          }
        })
        let saved = if @fs.exists(old + "/state.json") {
          @json.parse(@fs.read_file(old + "/state.json").text())
        } else {
          state
        }
        guard field(saved, "workspaceUid") == field(state, "workspaceUid") else {
          raise AdapterError("Tunnel ownership changed")
        }
        restart_tunnel(saved, old)
        expires = connection_deadline()
      }
      close_tunnel(state)
      let name = required(state, "workspaceUid")
        .replace_all(old="%", new="%25")
        .replace_all(old="/", new="%2F")
      let directory = base + "/workspace-" + name
      @fs.mkdir(directory, permission=0o700, allow_exist=true)
      set_field(state, "tunnelDirectory", Json::string(directory))
      directory
    }
  }
  let lease = @fs.open(
    directory + "/startup.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lease.close()
  @async.with_timeout(30000, async fn() {
    while !lease.try_lock(Exclusive) {
      @async.sleep(100)
    }
  })
  if @fs.exists(directory + "/state.json") {
    register_workspace(directory)
    let saved = @json.parse(@fs.read_file(directory + "/state.json").text())
    guard field(saved, "workspaceUid") == field(state, "workspaceUid") &&
      field(saved, "localPort") ==
      port.map(value => Json::number(value.to_double())) else {
      raise AdapterError("Tunnel ownership changed")
    }
    if restart {
      restart_tunnel(saved, directory)
      expires = connection_deadline()
    }
    if !worker_alive(directory) {
      @fs.write_file(directory + "/enabled", "", permission=0o600)
      spawn_tunnel_worker(directory)
    }
    wait_tunnel(directory, expires)
    return
  } else if restart {
    restart_tunnel(state, directory)
    expires = connection_deadline()
  }
  let socket_directory = @fs.tmpdir(prefix="oe")
  let saved = Json::empty_object()
  for
    name in [
      "workspaceId", "workspaceUid", "orcaVolume", "orcaVolumeCleanup", "user", "command",
      "devsyEnv", "hostDirectory", "home", "context", "connection", "projectRoot",
      "idleTimeoutMs", "idleProvider", "serverEnv",
    ] {
    if field(state, name) is Some(value) {
      set_field(saved, name, value)
    }
  }
  set_field(saved, "socketDirectory", Json::string(socket_directory))
  if port is Some(value) {
    set_field(saved, "localPort", Json::number(value.to_double()))
  }
  @fs.write_file(directory + "/state.tmp", saved.stringify(), permission=0o600)
  @fs.rename(directory + "/state.tmp", directory + "/state.json", replace=true)
  @fs.write_file(directory + "/enabled", "", permission=0o600)
  if @fs.exists(directory + "/status.json") {
    @fs.remove(directory + "/status.json")
  }
  register_workspace(directory)
  spawn_tunnel_worker(directory)
  wait_tunnel(directory, expires)
}

///|
async fn restart_tunnel(state : Json, directory : String) -> Unit {
  let enabled = directory + "/enabled"
  let was_enabled = @fs.exists(enabled)
  errdefer (if was_enabled && @fs.exists(directory) {
    @fs.write_file(enabled, "", permission=0o600) catch {
      _ => ()
    }
  })
  let mut phase = if worker_alive(directory) { "worker" } else { "master" }
  save_diagnostic(
    "ssh-tunnel-restart",
    "started",
    phase~,
    tunnel_directory=directory,
    recording=workspace_recording(state),
  )
  let mut timed_out = false
  errdefer save_diagnostic(
    "ssh-tunnel-restart",
    if timed_out {
      "timeout"
    } else {
      "failed"
    },
    phase~,
    error_type=if timed_out { "shutdown_timeout" } else { "shutdown_failed" },
    tunnel_directory=directory,
    recording=workspace_recording(state),
  )
  try {
    if @fs.exists(enabled) {
      @fs.remove(enabled)
    }
    @async.with_timeout(15000, async fn() {
      while worker_alive(directory) {
        @async.sleep(100)
      }
    })
    phase = "master"
    save_diagnostic(
      "ssh-tunnel-restart",
      "stopping",
      phase~,
      tunnel_directory=directory,
      recording=workspace_recording(state),
    )
    stop_tunnel_master(state, directory, verify=true)
  } catch {
    @async.TimeoutError as error => {
      timed_out = true
      raise error
    }
    error => raise error
  }
  save_diagnostic(
    "ssh-tunnel-restart",
    "success",
    tunnel_directory=directory,
    recording=workspace_recording(state),
  )
}

///|
async fn spawn_tunnel_worker(directory : String) -> Unit {
  @fs.write_file(directory + "/request", "", permission=0o600)
  ensure_supervisor(initial_workspace=directory)
}

///|
pub async fn recover_all(restart~ : Bool = false) -> Unit {
  recover_all_inner(restart~) catch {
    AdapterError(message) => {
      @stdio.stderr.write("orca-env-devsy: " + message + "\n")
      save_diagnostic("recover", "failed")
      raise AdapterError(message)
    }
    _ => {
      @stdio.stderr.write(
        "orca-env-devsy: bulk recover failed; inspect local diagnostics\n",
      )
      save_diagnostic("recover", "failed")
      raise AdapterError("Bulk recover failed")
    }
  }
}

///|
async fn recover_all_inner(restart~ : Bool = false) -> Unit {
  notify(if restart { "restart" } else { "recover" })
  let base = adapter_state_home() + "/tunnels"
  if !@fs.exists(base) && !@fs.exists(adapter_state_home() + "/transports") {
    save_diagnostic("recover", "success")
    return
  }
  ignore(saved_proxy_executable())
  ensure_supervisor()
  if !@fs.exists(base) {
    save_diagnostic("recover", "success")
    return
  }
  let mut failures = 0
  let permits = @async.Semaphore(4)
  @async.with_task_group(async fn(group) {
    for name in @fs.readdir(base, sort=true) {
      let directory = base + "/" + name
      permits.acquire()
      group.spawn_bg(async fn() {
        defer permits.release()
        try {
          if @fs.kind(directory, follow_symlink=false) !=
            @fs.FileKind::Directory ||
            !@fs.exists(directory + "/enabled") {
            return
          }
          let state = @json.parse(
            @fs.read_file(directory + "/state.json").text(),
          )
          validate_state(state)
          set_field(state, "tunnelDirectory", Json::string(directory))
          recover_connection(state, restart~)
        } catch {
          _ =>
            if @fs.exists(directory) {
              failures += 1
              save_diagnostic("recover", "failed", tunnel_directory=directory)
            } else {
              save_diagnostic("recover", "target-removed")
            }
        }
      })
    }
  })
  guard failures == 0 else {
    raise AdapterError(
      "Some connections could not be recovered; other targets were attempted",
    )
  }
  save_diagnostic("recover", "success")
}

///|
async fn connection_operation_lock(state : Json) -> @fs.File {
  let directory = required(state, "tunnelDirectory")
  @fs.mkdir(directory, recursive=true, permission=0o700, allow_exist=true)
  let lock = @fs.open(
    directory + "/operation.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  errdefer lock.close()
  @async.with_timeout(60000, async fn() {
    while !lock.try_lock(Exclusive) {
      @async.sleep(100)
    }
  })
  @async.with_timeout(10000, async fn() {
    match workspace(state) {
      Some(current) if field(current, "uid") == field(state, "workspaceUid") =>
        ()
      None => ()
      _ => raise AdapterError("Workspace replaced during lifecycle operation")
    }
  })
  lock
}

///|
async fn pause_request(directory : String) -> String? {
  Some(@fs.read_file(directory + "/paused").text()) catch {
    error => if !@fs.exists(directory + "/paused") { None } else { raise error }
  }
}

///|
async fn pause_tunnel(state : Json) -> Unit {
  let directory = required(state, "tunnelDirectory")
  errdefer unpause_tunnel(state)
  if @fs.exists(directory + "/pause-ack") {
    @fs.remove(directory + "/pause-ack")
  }
  @fs.write_file(directory + "/paused", recording_run_id, permission=0o600)
  @async.with_timeout(15000, async fn() {
    while worker_alive(directory) {
      if @fs.exists(directory + "/pause-ack") &&
        @fs.read_file(directory + "/pause-ack").text() == recording_run_id {
        return
      }
      @async.sleep(100)
    }
  })
}

///|
async fn unpause_tunnel(state : Json) -> Unit {
  let directory = required(state, "tunnelDirectory")
  if @fs.exists(directory + "/paused") {
    @fs.remove(directory + "/paused")
  }
  if @fs.exists(directory + "/pause-ack") {
    @fs.remove(directory + "/pause-ack")
  }
  if @fs.exists(directory + "/enabled") {
    @fs.write_file(directory + "/probe-request", "", permission=0o600)
  }
}

///|
fn configured_timing_ms(
  name : String,
  fallback : Int32,
  state? : Json,
) -> Int32 raise {
  match
    state
    .map(state => workspace_environment(state).get(name))
    .unwrap_or(@env.get_env_var(name)) {
    None => fallback
    Some(text) => {
      let value = @string.parse_int(text) catch {
        _ => raise AdapterError(name + " must be positive milliseconds")
      }
      guard value > 0 else {
        raise AdapterError(name + " must be positive milliseconds")
      }
      value
    }
  }
}

///|
fn connection_timeout_ms(state? : Json) -> Int32 raise {
  configured_timing_ms("ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS", 60000, state?)
}

///|
fn connection_deadline() -> UInt64 raise {
  @env.now() + connection_timeout_ms().to_uint64()
}

///|
fn connection_timeout_message() -> String raise {
  let timeout = connection_timeout_ms()
  let duration = if timeout % 1000 == 0 {
    "\{timeout / 1000} seconds"
  } else {
    "\{timeout} ms"
  }
  "SSH and relay readiness timed out after " + duration
}

///|
fn monitor_delay(attempt : Int32) -> Int32 {
  match attempt {
    0 => 15000
    1 => 30000
    2 => 60000
    3 => 120000
    _ => 300000
  }
}

///|
async fn monitor_wait(directory : String, delay : Int32) -> Unit {
  for elapsed = 0
      elapsed < delay && @fs.exists(directory + "/enabled")
      elapsed = elapsed + 100 {
    if @fs.exists(directory + "/probe-request") ||
      @fs.exists(directory + "/paused") {
      return
    }
    @async.sleep(100)
  }
}

///|
async fn recover_connection(
  state : Json,
  restart~ : Bool = false,
  deadline? : UInt64,
) -> Unit {
  let operation = connection_operation_lock(state)
  defer operation.close()
  let directory = required(state, "tunnelDirectory")
  let deadline = deadline.unwrap_or(connection_deadline())
  connection_timeout(deadline, async fn() {
    let current = workspace(state)
    guard current is Some(current) &&
      field(current, "uid") == field(state, "workspaceUid") else {
      save_diagnostic(
        "recover",
        "ownership-error",
        tunnel_directory=directory,
        recording=workspace_recording(state),
      )
      raise AdapterError("Tunnel workspace ownership changed")
    }
    let status = workspace_status(state)
    save_diagnostic(
      "recover-workspace",
      status,
      tunnel_directory=directory,
      recording=workspace_recording(state),
    )
    match status {
      "Running" => ()
      "Stopped" => return
      "Busy" =>
        raise AdapterError(
          "Workspace is Busy; wait for workspace up to finish before recover",
        )
      _ => raise AdapterError("Workspace is missing")
    }
    @fs.mkdir(directory, recursive=true, permission=0o700, allow_exist=true)
    let lock = @fs.open(
      directory + "/recovery.lock",
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
    let port = match field(state, "localPort") {
      Some(Json::Number(value, ..)) if value >= 1 &&
        value <= 65535 &&
        value == value.to_int().to_double() => Some(value.to_int())
      None if field(state, "connection") == Some(Json::string("ssh")) => None
      _ => raise AdapterError("Invalid saved tunnel port")
    }
    save_diagnostic(
      "recover-worker",
      if restart {
        "restart"
      } else if worker_alive(directory) {
        "reuse"
      } else {
        "restore"
      },
      tunnel_directory=directory,
      recording=workspace_recording(state),
    )
    ensure_ssh_worker(state, port, deadline~, restart~)
    if required(state, "connection") == "orca-server" {
      ignore(recover_server(state))
    }
    save_diagnostic(
      "recover",
      "success",
      tunnel_directory=directory,
      recording=workspace_recording(state),
    )
  })
}

///|
async fn workspace_status(state : Json) -> String {
  let result = @json.parse(
    @async.with_timeout(10000, async fn() {
      devsy(
        state,
        [
          "--result-format",
          "json",
          "workspace",
          "status",
          required(state, "workspaceId"),
          "--container-status=false",
        ],
        "workspace-status",
      )
    }),
  )
  match field(result, "state") {
    Some(Json::String("Running" | "Stopped" | "Busy" | "NotFound" as value)) =>
      value
    _ => raise AdapterError("Invalid workspace status")
  }
}

///|
priv suberror ConnectionDeadline {
  ConnectionDeadline
}

///|
async fn[T] connection_timeout(deadline : UInt64, run : async () -> T) -> T {
  let now = @env.now()
  if deadline <= now {
    raise AdapterError(connection_timeout_message())
  }
  @async.with_timeout((deadline - now).to_int(), run, error=ConnectionDeadline) catch {
    ConnectionDeadline => {
      save_diagnostic(
        "connection-readiness",
        "timeout",
        error_type="readiness_timeout",
        timeout_ms=connection_timeout_ms(),
      )
      raise AdapterError(connection_timeout_message())
    }
    error => raise error
  }
}

///|
async fn wait_tunnel(directory : String, deadline : UInt64) -> Unit {
  let started = @env.now()
  progress_message("ssh-tunnel: connecting…")
  errdefer progress_message(
    "ssh-tunnel: failed (" + progress_timing(started) + ")",
  )
  @fs.write_file(directory + "/probe-request", "", permission=0o600)
  connection_timeout(deadline, async fn() {
    while true {
      if @fs.exists(directory + "/status.json") {
        let status = @json.parse(
          @fs.read_file(directory + "/status.json").text(),
        )
        match field(status, "status") {
          Some(Json::String("ownership-error")) => {
            while worker_alive(directory) {
              @async.sleep(25)
            }
            raise AdapterError("Tunnel workspace ownership changed")
          }
          Some(Json::String("workspace-stopped" | "workspace-busy" | "paused")) =>
            ()
          Some(Json::String("unsupported")) => {
            while worker_alive(directory) {
              @async.sleep(25)
            }
            raise AdapterError(
              "Devsy /ready is unsupported; upgrade Devsy to a version supporting relay readiness",
            )
          }
          Some(Json::String("connected")) if !@fs.exists(
              directory + "/probe-request",
            ) &&
            worker_alive(directory) => {
            let saved = @json.parse(
              @fs.read_file(directory + "/state.json").text(),
            )
            try {
              check_tunnel(saved, directory)
              return
            } catch {
              _ => ()
            }
          }
          _ => ()
        }
      }
      @async.sleep(100)
    }
  })
  progress_message("ssh-tunnel: connected (" + progress_timing(started) + ")")
}

///|
async fn wait_git_relay(directory : String) -> Unit {
  while true {
    guard @fs.exists(directory + "/enabled") && worker_alive(directory) else {
      save_diagnostic("git-relay", "failed", error_type="worker_stopped")
      raise AdapterError(
        "Tunnel worker stopped before Git credential relay readiness",
      )
    }
    if @fs.exists(directory + "/git-status") {
      let status = @fs.read_file(directory + "/git-status").text()
      if status == "ready" || status == "disabled" {
        return
      }
    }
    @async.sleep(100)
  }
}

///|
async fn close_tunnel(state : Json) -> Unit {
  guard field(state, "tunnelDirectory") is Some(Json::String(directory)) else {
    return
  }
  if !@fs.exists(directory) {
    return
  }
  let started = @env.now()
  progress_message("ssh-tunnel-close: running…")
  errdefer progress_message(
    "ssh-tunnel-close: failed (" + progress_timing(started) + ")",
  )
  if @fs.exists(directory + "/state.json") {
    let saved = @json.parse(@fs.read_file(directory + "/state.json").text())
    guard field(saved, "workspaceUid") == field(state, "workspaceUid") else {
      raise AdapterError("Tunnel ownership changed")
    }
    if @fs.exists(directory + "/enabled") {
      @fs.remove(directory + "/enabled")
    }
    @async.with_timeout(15000, async fn() {
      while worker_alive(directory) {
        @async.sleep(100)
      }
    })
    stop_tunnel_master(saved, directory)
  } else if @fs.exists(control_socket(state, directory)) {
    // Saved receipts from before the recovery worker own an SSH master only.
    ignore(
      @process.collect_output(
        workspace_program(state, "ssh"),
        extra_env=workspace_environment(state),
        cwd?=workspace_directory(state).map(path => path[:]),
        inherit_env=false,
        ssh_mux_options(state, directory) + ["-O", "exit"],
      ),
    )
  }
  // Only remove this worker's files; retain unexpected directory contents.
  for
    name in [
      "state.json", "state.tmp", "status.json", "status.tmp", "worker.lock", "startup.lock",
      "request", "socket", "git-status", "git-established", "probe-request", "recovery.lock",
      "idle.json", "idle.tmp", "idle-state.lock", "idle-enabled", "operation.lock",
      "server.lock", "server-enabled", "paused", "pause-ack", "pairing-code",
    ] {
    if @fs.exists(directory + "/" + name) {
      @fs.remove(directory + "/" + name)
    }
  }
  @fs.rmdir(directory) catch {
    _ => ()
  }
  progress_message("ssh-tunnel-close: done (" + progress_timing(started) + ")")
}

///|
async fn tunnel_worker(
  directory : String,
  environment : Map[String, String],
) -> Unit {
  let lock = @fs.open(
    directory + "/worker.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    return
  }
  if @fs.exists(directory + "/request") {
    @fs.remove(directory + "/request")
  }
  let state = @json.parse(@fs.read_file(directory + "/state.json").text())
  let execution = Json::empty_object()
  for (name, value) in environment {
    set_field(execution, name, Json::string(value))
  }
  set_field(state, "executionEnvironment", execution)
  validate_state(state)
  let forwarding = match field(state, "localPort") {
    Some(Json::Number(value, ..)) =>
      ["-L", "127.0.0.1:\{value.to_int()}:127.0.0.1:47121"]
    None if field(state, "connection") == Some(Json::string("ssh")) => []
    _ => raise AdapterError("Missing tunnel port")
  }
  let enabled = directory + "/enabled"
  let mut adopted = try {
    check_tunnel(state, directory)
    true
  } catch {
    _ => false
  }
  set_field(state, "tunnelDirectory", Json::string(directory))
  let idle_timer = if idle_timeout(state) is Some(_) {
    Some(IdleTimer::{ elapsed: 0, seen: false, epoch: -1, previous: None, })
  } else {
    None
  }
  let mut attempt = 0
  let mut monitoring = false
  let mut monitor_attempt = 0
  let mut needs_cleanup = @fs.exists(control_socket(state, directory))
  defer @async.protect_from_cancel(async fn() {
    if needs_cleanup {
      stop_tunnel_master(state, directory)
    }
  })
  while @fs.exists(enabled) {
    if pause_request(directory) is Some(request) {
      if idle_timer is Some(timer) {
        timer.previous = None
      }
      if needs_cleanup {
        stop_tunnel_master(state, directory)
        needs_cleanup = false
      }
      tunnel_status(directory, "paused", recording=workspace_recording(state))
      while @fs.exists(enabled) && pause_request(directory) == Some(request) {
        @fs.write_file(directory + "/pause-ack", request, permission=0o600)
        @async.sleep(100)
      }
      continue
    }
    if @fs.exists(directory + "/probe-request") {
      @fs.remove(directory + "/probe-request")
    }
    tunnel_status(directory, "connecting", recording=workspace_recording(state))
    git_relay_status(directory, "pending", recording=workspace_recording(state))
    let mut terminal = false
    @async.with_task_group(async fn(group) {
      let idle_busy : Ref[Bool] = { val: false, }
      let idle_done : Ref[Bool] = { val: false, }
      let mut idle_started = false
      group.spawn_bg(no_wait=true, async fn() {
        while @fs.exists(enabled) && !@fs.exists(directory + "/paused") {
          @async.sleep(100)
        }
        raise AdapterError("Tunnel disabled or paused")
      })
      monitoring = true
      let current = worker_workspace(state, directory)
      save_diagnostic(
        "monitor-identity",
        match current {
          None => "missing"
          Some(value) if field(value, "uid") == field(state, "workspaceUid") =>
            "matched"
          _ => "replaced"
        },
        tunnel_directory=directory,
        expected_workspace_uid=required(state, "workspaceUid"),
        observed_workspace_uid?=current.map(value => required(value, "uid")),
        recording=workspace_recording(state),
      )
      guard current is Some(current) &&
        field(current, "uid") == field(state, "workspaceUid") else {
        if @fs.exists(enabled) {
          @fs.remove(enabled)
        }
        terminal = true
        tunnel_status(
          directory,
          "ownership-error",
          recording=workspace_recording(state),
        )
        return
      }
      let status = required(current, "workspaceStatus")
      save_diagnostic(
        "monitor-workspace",
        status,
        tunnel_directory=directory,
        recording=workspace_recording(state),
      )
      if status == "NotFound" {
        terminal = true
        @fs.remove(enabled)
        tunnel_status(
          directory,
          "ownership-error",
          recording=workspace_recording(state),
        )
        return
      }
      if status != "Running" {
        if status == "Stopped" {
          idle_reset(state, "workspace_stopped")
        }
        monitoring = true
        tunnel_status(
          directory,
          if status == "Stopped" {
            "workspace-stopped"
          } else {
            "workspace-busy"
          },
          recording=workspace_recording(state),
        )
        return
      }
      monitoring = false
      if !adopted {
        stop_tunnel_master(state, directory, verify=true)
      }
      @fs.mkdir(
        required(state, "socketDirectory"),
        permission=0o700,
        allow_exist=true,
      )
      let sink = @process.redirect_to_file("/dev/null", shared=true)
      defer sink.close()
      let (errors, stderr) = @process.read_from_process()
      defer errors.close()
      let classified = group.spawn(
        async fn() { tunnel_errors(errors) },
        no_wait=true,
      )
      needs_cleanup = true
      let child = if adopted {
        save_diagnostic(
          "orca-tunnel",
          "adopted",
          tunnel_directory=directory,
          recording=workspace_recording(state),
        )
        None
      } else {
        Some(
          @process.spawn(
            group,
            workspace_program(state, "ssh"),
            extra_env=workspace_environment(state),
            cwd?=workspace_directory(state).map(path => path[:]),
            inherit_env=false,
            ssh_args(
              state,
              lease=required(state, "socketDirectory") + "/primary-proxy.lock",
            ) +
            [
              "-M",
              "-S",
              control_socket(state, directory),
              "-N",
              "-o",
              "ControlPersist=no",
              "-o",
              "ForkAfterAuthentication=no",
              "-o",
              "ExitOnForwardFailure=yes",
              "-o",
              "ServerAliveInterval=10",
              "-o",
              "ServerAliveCountMax=3",
            ] +
            forwarding,
            stdin=@process.redirect_from_file("/dev/null"),
            stdout=sink,
            stderr~,
            no_wait=true,
          ),
        )
      }
      adopted = false
      let git_enabled = @async.with_timeout(10000, async fn() {
        git_forwarding_enabled(state)
      })
      let mut next_probe = @env.now()
      let mut next_check = @env.now()
      let mut failures = 0
      let mut connected = false
      while @fs.exists(enabled) {
        if idle_done.val {
          monitoring = true
          break
        }
        if idle_busy.val {
          @async.sleep(100)
          continue
        }
        if child is Some(child) && child.try_wait() is Some(code) {
          save_diagnostic(
            "orca-tunnel",
            "disconnected",
            exit_code=code,
            error_type=@async.with_timeout(1000, async fn() {
              classified.wait()
            }) catch {
              _ => "process_exit"
            },
            tunnel_directory=directory,
            recording=workspace_recording(state),
          )
          break
        }
        if !connected && @env.now() >= next_check {
          let alive = try {
            check_tunnel(state, directory)
            true
          } catch {
            _ => false
          }
          if !alive {
            if connected || child is None {
              break
            }
            @async.sleep(100)
            continue
          }
          next_check = @env.now() + 1000
        }
        if @env.now() >= next_probe ||
          (connected && @fs.exists(directory + "/probe-request")) {
          match relay_readiness(state, directory, git_enabled) {
            Ready => {
              failures = 0
              attempt = 0
              if !connected {
                if @fs.exists(directory + "/server-enabled") {
                  @async.with_timeout(connection_timeout_ms(state~), async fn() {
                    ignore(recover_server(state))
                  })
                }
                connected = true
                monitoring = false
                monitor_attempt = 0
                git_relay_status(
                  directory,
                  if git_enabled {
                    "ready"
                  } else {
                    "disabled"
                  },
                  recording=workspace_recording(state),
                )
                tunnel_status(
                  directory,
                  "connected",
                  recording=workspace_recording(state),
                )
              }
              if @fs.exists(directory + "/probe-request") {
                @fs.remove(directory + "/probe-request")
              }
              next_probe = @env.now() + 10000
              if !idle_started &&
                idle_timer is Some(timer) &&
                @fs.exists(directory + "/idle-enabled") {
                idle_started = true
                group.spawn_bg(no_wait=true, async fn() {
                  idle_supervisor(state, timer, idle_busy, idle_done) catch {
                    error =>
                      save_diagnostic(
                        "idle-monitor",
                        "failed",
                        error_type="monitor_failed",
                        error_message=redact_credentials(error.to_string()),
                        tunnel_directory=directory,
                        recording=workspace_recording(state),
                      )
                  }
                })
              }
            }
            Unsupported => {
              terminal = true
              tunnel_status(
                directory,
                "unsupported",
                recording=workspace_recording(state),
              )
              break
            }
            WaitingForGitHelper => {
              failures = 0
              connected = false
              git_relay_status(
                directory,
                "unavailable",
                recording=workspace_recording(state),
              )
              tunnel_status(
                directory,
                "checking",
                recording=workspace_recording(state),
              )
              next_probe = @env.now() + 1000
            }
            Retry(reason) => {
              failures += 1
              connected = false
              git_relay_status(
                directory,
                "unavailable",
                recording=workspace_recording(state),
              )
              tunnel_status(
                directory,
                "checking",
                recording=workspace_recording(state),
              )
              save_diagnostic(
                "relay-recovery",
                "failed",
                attempt=failures,
                error_type=reason,
                tunnel_directory=directory,
                recording=workspace_recording(state),
              )
              if failures >= 2 {
                break
              }
              next_probe = @env.now()
              continue
            }
          }
        }
        @async.sleep(100)
      }
    }) catch {
      error => {
        let message = match error {
          AdapterError(message) => Some(redact_credentials(message))
          _ => None
        }
        if @fs.exists(enabled) && !@fs.exists(directory + "/paused") {
          save_diagnostic(
            "orca-tunnel",
            "process-error",
            tunnel_directory=directory,
            error_type=if monitoring {
              "workspace_query_failed"
            } else {
              "connection_failed"
            },
            error_message?=message,
            recording=workspace_recording(state),
          )
        }
      }
    }
    if needs_cleanup {
      stop_tunnel_master(state, directory, verify=true)
      needs_cleanup = false
    }
    if terminal {
      return
    }
    if @fs.exists(directory + "/paused") {
      continue
    }
    if monitoring && @fs.exists(enabled) {
      let delay = configured_timing_ms(
        "ORCA_ENV_DEVSY_TEST_MONITOR_DELAY_MS",
        monitor_delay(monitor_attempt),
        state~,
      )
      save_diagnostic(
        "monitor-wait",
        "waiting",
        attempt=monitor_attempt,
        retry_delay_ms=delay,
        tunnel_directory=directory,
        recording=workspace_recording(state),
      )
      monitor_attempt = if monitor_attempt < 4 {
        monitor_attempt + 1
      } else {
        4
      }
      idle_retry_wait(state, idle_timer, delay)
      continue
    }
    if @fs.exists(enabled) {
      tunnel_status(
        directory,
        "disconnected",
        recording=workspace_recording(state),
      )
      attempt = if attempt < 6 { attempt + 1 } else { 6 }
      let delay = if attempt < 6 { 500 * (1 << attempt) } else { 30000 }
      save_diagnostic(
        "orca-tunnel",
        "retry",
        attempt~,
        retry_delay_ms=delay,
        tunnel_directory=directory,
        recording=workspace_recording(state),
      )
      idle_retry_wait(state, idle_timer, delay)
    }
  }
  tunnel_status(directory, "stopped", recording=workspace_recording(state))
}

///|
async fn check_tunnel(state : Json, directory : String) -> Unit {
  guard @fs.exists(control_socket(state, directory)) else {
    raise AdapterError("Tunnel not ready")
  }
  @async.with_timeout(2000, async fn() {
    let (status, _, _) = @process.collect_output(
      workspace_program(state, "ssh"),
      extra_env=workspace_environment(state),
      cwd?=workspace_directory(state).map(path => path[:]),
      inherit_env=false,
      ssh_mux_options(state, directory) + ["-O", "check"],
    )
    guard status == 0 else { raise AdapterError("Tunnel not ready") }
    match field(state, "localPort") {
      Some(Json::Number(value, ..)) => {
        let socket = @socket.Tcp::connect(
          @socket.Addr::parse("127.0.0.1:" + value.to_int().to_string()),
        )
        socket.close()
      }
      None if field(state, "connection") == Some(Json::string("ssh")) => ()
      _ => raise AdapterError("Missing tunnel port")
    }
  })
}

///|
async fn worker_workspace(state : Json, directory : String) -> Json? {
  @async.with_timeout(10000, async fn() {
    @async.with_task_group(async fn(group) {
      let running = group.spawn(
        async fn() { workspace_status(state) },
        allow_failure=true,
        no_wait=true,
      )
      let query = group.spawn(async fn() {
        let current = workspace(state)
        if current is Some(value) &&
          field(value, "uid") == field(state, "workspaceUid") {
          set_field(value, "workspaceStatus", Json::string(running.wait()))
        }
        current
      })
      group.spawn_bg(no_wait=true, async fn() {
        while @fs.exists(directory + "/enabled") {
          @async.sleep(100)
        }
        query.cancel()
      })
      query.wait()
    })
  })
}
