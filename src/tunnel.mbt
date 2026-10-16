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
async fn tunnel_status(directory : String, status : String) -> Unit {
  let value : Json = { "status": status, "runId": recording_run_id }
  @fs.write_file(directory + "/status.tmp", value.stringify(), permission=0o600)
  @fs.rename(
    directory + "/status.tmp",
    directory + "/status.json",
    replace=true,
  )
  save_diagnostic("orca-tunnel", status)
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
    // active proxies valid while create/resume/reconnect refresh future calls.
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
async fn stop_tunnel_master(state : Json, directory : String) -> Unit {
  stop_git_management(state)
  @async.with_timeout(2000, async fn() {
    ignore(
      @process.collect_output(
        "ssh",
        ssh_args(state) + ["-S", control_socket(state, directory), "-O", "exit"],
      ),
    )
  }) catch {
    _ => ()
  }
  if field(state, "socketDirectory") is Some(Json::String(socket_directory)) {
    if @fs.exists(socket_directory + "/credential-socket") {
      @fs.remove(socket_directory + "/credential-socket")
    }
    if @fs.exists(socket_directory + "/socket") {
      @fs.remove(socket_directory + "/socket")
    }
    wait_ssh_proxy(state, "primary")
    for role in ["primary", "management"] {
      let lease = socket_directory + "/" + role + "-proxy.lock"
      if @fs.exists(lease) {
        @fs.remove(lease)
      }
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
  wait_for_git~ : Bool = true,
) -> Unit {
  let base = adapter_state_home() + "/tunnels"
  @fs.mkdir(base, recursive=true, permission=0o700, allow_exist=true)
  let directory = match field(state, "tunnelDirectory") {
    Some(Json::String(old)) if old.has_prefix(base + "/") && @fs.exists(old) =>
      old
    _ => {
      close_tunnel(state)
      let temporary = @fs.tmpdir(prefix="oe")
      let name = temporary.split("/").to_array().last().unwrap().to_owned()
      @fs.rmdir(temporary)
      let directory = base + "/" + name
      @fs.mkdir(directory, permission=0o700)
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
    let saved = @json.parse(@fs.read_file(directory + "/state.json").text())
    guard field(saved, "workspaceUid") == field(state, "workspaceUid") &&
      field(saved, "localPort") ==
      port.map(value => Json::number(value.to_double())) else {
      raise AdapterError("Tunnel ownership changed")
    }
    if worker_alive(directory) {
      wait_tunnel(directory, wait_for_git~)
      return
    }
    // A dead supervisor does not invalidate its still-live SSH transport.
    // Reuse it so Devsy's old service cleanup cannot remove a new owner's helper.
    let reusable = try {
      check_tunnel(saved, directory)
      true
    } catch {
      _ => false
    }
    if reusable {
      for name in ["status.json", "git-status"] {
        if @fs.exists(directory + "/" + name) {
          @fs.remove(directory + "/" + name)
        }
      }
      spawn_tunnel_worker(directory)
      wait_tunnel(directory, wait_for_git~)
      return
    }
    stop_tunnel_master(saved, directory)
  }
  let socket_directory = @fs.tmpdir(prefix="oe")
  let saved = Json::empty_object()
  for
    name in [
      "workspaceId", "workspaceUid", "user", "command", "devsyEnv", "home", "context",
      "connection", "ghAuth",
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
  spawn_tunnel_worker(directory)
  wait_tunnel(directory, wait_for_git~)
}

///|
async fn spawn_tunnel_worker(directory : String) -> Unit {
  let sink = @process.redirect_to_file("/dev/null", shared=true)
  defer sink.close()
  ignore(
    @process.spawn_orphan(
      saved_proxy_executable(),
      ["--tunnel-worker", directory],
      stdin=@process.redirect_from_file("/dev/null"),
      stdout=sink,
      stderr=sink,
    ),
  )
}

///|
pub async fn reconnect_all() -> Unit {
  reconnect_all_inner() catch {
    AdapterError(message) => {
      @stdio.stderr.write("orca-env-devsy: " + message + "\n")
      save_diagnostic("reconnect", "failed")
      raise AdapterError(message)
    }
    _ => {
      @stdio.stderr.write(
        "orca-env-devsy: bulk reconnect failed; inspect local diagnostics\n",
      )
      save_diagnostic("reconnect", "failed")
      raise AdapterError("Bulk reconnect failed")
    }
  }
}

///|
async fn reconnect_all_inner() -> Unit {
  notify("reconnect")
  let base = adapter_state_home() + "/tunnels"
  if !@fs.exists(base) {
    save_diagnostic("reconnect", "success")
    return
  }
  ignore(saved_proxy_executable())
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
          if worker_alive(directory) {
            let current = worker_workspace(state, directory)
            guard current is Some(current) &&
              field(current, "uid") == field(state, "workspaceUid") else {
              @fs.remove(directory + "/enabled")
              save_diagnostic("reconnect", "ownership-error")
              return
            }
            if field(current, "running") != Some(Json::boolean(true)) {
              save_diagnostic("reconnect", "workspace-stopped")
              return
            }
          }
          let port = match field(state, "localPort") {
            Some(Json::Number(value, ..)) if value >= 1 &&
              value <= 65535 &&
              value == value.to_int().to_double() => Some(value.to_int())
            None if field(state, "connection") == Some(Json::string("ssh")) =>
              None
            _ => raise AdapterError("Invalid saved tunnel port")
          }
          set_field(state, "tunnelDirectory", Json::string(directory))
          ensure_ssh_worker(state, port)
          gh_addon(state)
          save_diagnostic("reconnect", "success")
        } catch {
          AdapterError("Tunnel workspace ownership changed") =>
            save_diagnostic("reconnect", "ownership-error")
          AdapterError("Tunnel workspace stopped") =>
            save_diagnostic("reconnect", "workspace-stopped")
          _ =>
            if @fs.exists(directory) {
              failures += 1
              save_diagnostic("reconnect", "failed")
            } else {
              save_diagnostic("reconnect", "target-removed")
            }
        }
      })
    }
  })
  guard failures == 0 else {
    raise AdapterError(
      "Some tunnels could not be restored; other targets were attempted",
    )
  }
  save_diagnostic("reconnect", "success")
}

///|
async fn workspace_running(state : Json) -> Bool {
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
        ],
        "workspace-status",
      )
    }),
  )
  match field(result, "state") {
    Some(Json::String("Running")) => true
    Some(Json::String("Stopped" | "Busy" | "NotFound")) => false
    _ => raise AdapterError("Invalid workspace status")
  }
}

///|
async fn wait_tunnel(directory : String, wait_for_git~ : Bool = true) -> Unit {
  let started = @env.now()
  progress_message("ssh-tunnel: connecting…")
  errdefer progress_message(
    "ssh-tunnel: failed (" + progress_timing(started) + ")",
  )
  @async.with_timeout(30000, async fn() {
    while true {
      if @fs.exists(directory + "/status.json") {
        let status = @json.parse(
          @fs.read_file(directory + "/status.json").text(),
        )
        if field(status, "status") == Some(Json::string("ownership-error")) {
          raise AdapterError("Tunnel workspace ownership changed")
        }
        if field(status, "status") == Some(Json::string("workspace-stopped")) {
          raise AdapterError("Tunnel workspace stopped")
        }
        if field(status, "status") == Some(Json::string("connected")) &&
          worker_alive(directory) {
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
      }
      @async.sleep(100)
    }
  })
  progress_message("ssh-tunnel: connected (" + progress_timing(started) + ")")
  guard wait_for_git else { return }
  @async.with_timeout(5000, async fn() { wait_git_relay(directory) }) catch {
    _ => ()
  }
  let git_status = if @fs.exists(directory + "/git-status") {
    @fs.read_file(directory + "/git-status").text()
  } else {
    "pending"
  }
  if git_status != "ready" && git_status != "disabled" {
    @stdio.stderr.write(
      "orca-env-devsy: Git credential relay readiness is unavailable; Orca remains connected. Recovery will retry; inspect local git-relay diagnostics.\n",
    ) catch {
      _ => ()
    }
    save_diagnostic("git-relay", "warning", error_type="readiness_unavailable")
  }
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
    // Only remove this worker's files; retain unexpected directory contents.
    for
      name in [
        "state.json", "state.tmp", "status.json", "status.tmp", "worker.lock", "startup.lock",
        "socket", "git-status", "git-established",
      ] {
      if @fs.exists(directory + "/" + name) {
        @fs.remove(directory + "/" + name)
      }
    }
  } else {
    // Saved receipts from before the recovery worker own an SSH master only.
    ignore(
      @process.collect_output(
        "ssh",
        ssh_args(state) + ["-S", control_socket(state, directory), "-O", "exit"],
      ),
    )
  }
  @fs.rmdir(directory) catch {
    _ => ()
  }
  progress_message("ssh-tunnel-close: done (" + progress_timing(started) + ")")
}

///|
pub async fn tunnel_worker(directory : String) -> Unit {
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
  let state = @json.parse(@fs.read_file(directory + "/state.json").text())
  validate_state(state)
  let forwarding = match field(state, "localPort") {
    Some(Json::Number(value, ..)) =>
      ["-L", "127.0.0.1:\{value.to_int()}:127.0.0.1:47121"]
    None if field(state, "connection") == Some(Json::string("ssh")) => []
    _ => raise AdapterError("Missing tunnel port")
  }
  let enabled = directory + "/enabled"
  let adopted = try {
    check_tunnel(state, directory)
    true
  } catch {
    _ => false
  }
  if adopted {
    errdefer stop_tunnel_master(state, directory)
    stop_git_management(state)
    let mut terminal = false
    @async.with_task_group(async fn(group) {
      // Both reads use the saved context; neither changes transport ownership.
      let current = worker_workspace(state, directory)
      guard current is Some(current) &&
        field(current, "uid") == field(state, "workspaceUid") else {
        if @fs.exists(enabled) {
          @fs.remove(enabled)
        }
        stop_tunnel_master(state, directory)
        terminal = true
        tunnel_status(directory, "ownership-error")
        return
      }
      if field(current, "running") != Some(Json::boolean(true)) {
        stop_tunnel_master(state, directory)
        terminal = true
        tunnel_status(directory, "workspace-stopped")
        return
      }
      save_diagnostic("orca-tunnel", "adopted")
      tunnel_status(directory, "connected")
      let options = group.spawn(
        async fn() {
          Some(
            @async.with_timeout(10000, async fn() {
              git_forwarding_enabled(state)
            }),
          )
        },
        allow_failure=true,
        no_wait=true,
      )
      group.spawn_bg(no_wait=true, async fn() {
        let initial_enabled = options.wait() catch { _ => None }
        monitor_git_relay(state, directory, initial_enabled~) catch {
          _ => git_relay_status(directory, "unavailable")
        }
      })
      while @fs.exists(enabled) {
        check_tunnel(state, directory) catch {
          _ => break
        }
        @async.sleep(1000)
      }
    })
    if terminal {
      return
    }
    if !@fs.exists(enabled) {
      stop_tunnel_master(state, directory)
      tunnel_status(directory, "stopped")
      return
    }
    stop_tunnel_master(state, directory)
    @fs.mkdir(
      required(state, "socketDirectory"),
      permission=0o700,
      allow_exist=true,
    )
  }
  let mut attempt = 0
  while @fs.exists(enabled) {
    if @fs.exists(directory + "/git-established") {
      @fs.remove(directory + "/git-established")
    }
    git_relay_status(directory, "pending")
    tunnel_status(directory, "connecting")
    let mut terminal = false
    @async.with_task_group(async fn(group) {
      let sink = @process.redirect_to_file("/dev/null", shared=true)
      defer sink.close()
      // A saved ID alone must not reconnect into a replacement workspace.
      guard worker_workspace(state, directory) is Some(current) &&
        field(current, "uid") == field(state, "workspaceUid") else {
        if @fs.exists(enabled) {
          @fs.remove(enabled)
        }
        terminal = true
        tunnel_status(directory, "ownership-error")
        return
      }
      if field(current, "running") != Some(Json::boolean(true)) {
        terminal = true
        tunnel_status(directory, "workspace-stopped")
        return
      }
      // The worker owns this master and reaps it before reconnecting.
      let (errors, stderr) = @process.read_from_process()
      defer errors.close()
      let classified = group.spawn(
        async fn() { tunnel_errors(errors) },
        no_wait=true,
      )
      let child = @process.spawn(
        group,
        "ssh",
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
      )
      let mut connected = false
      let mut monitoring_git = false
      while @fs.exists(enabled) && child.try_wait() is None {
        if !connected {
          try {
            check_tunnel(state, directory)
            connected = true
            attempt = 0
            tunnel_status(directory, "connected")
          } catch {
            _ => ()
          }
        }
        if connected && !monitoring_git {
          monitoring_git = true
          group.spawn_bg(no_wait=true, async fn() {
            monitor_git_relay(state, directory) catch {
              _ => git_relay_status(directory, "unavailable")
            }
          })
        }
        @async.sleep(100)
      }
      if !@fs.exists(enabled) {
        @async.with_timeout(2000, async fn() {
          ignore(
            @process.collect_output(
              "ssh",
              ssh_args(state) +
              ["-S", control_socket(state, directory), "-O", "exit"],
            ),
          )
        }) catch {
          _ => ()
        }
        child.cancel()
      } else {
        let code = child.wait()
        save_diagnostic(
          "orca-tunnel",
          "disconnected",
          exit_code=code,
          error_type=@async.with_timeout(1000, async fn() { classified.wait() }) catch {
            _ => "process_exit"
          },
        )
      }
    }) catch {
      _ => save_diagnostic("orca-tunnel", "process-error")
    }
    if terminal {
      return
    }
    if @fs.exists(enabled) {
      tunnel_status(directory, "disconnected")
      attempt = if attempt < 6 { attempt + 1 } else { 6 }
      let delay = if attempt < 6 { 500 * (1 << attempt) } else { 30000 }
      save_diagnostic("orca-tunnel", "retry", attempt~, retry_delay_ms=delay)
      for elapsed = 0
          elapsed < delay && @fs.exists(enabled)
          elapsed = elapsed + 100 {
        @async.sleep(100)
      }
    }
  }
  tunnel_status(directory, "stopped")
}

///|
async fn check_tunnel(state : Json, directory : String) -> Unit {
  @async.with_timeout(2000, async fn() {
    let (status, _, _) = @process.collect_output(
      "ssh",
      ssh_args(state) + ["-S", control_socket(state, directory), "-O", "check"],
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
        async fn() { workspace_running(state) },
        allow_failure=true,
        no_wait=true,
      )
      let query = group.spawn(async fn() {
        let current = workspace(state)
        if current is Some(value) &&
          field(value, "uid") == field(state, "workspaceUid") {
          set_field(value, "running", Json::boolean(running.wait()))
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
