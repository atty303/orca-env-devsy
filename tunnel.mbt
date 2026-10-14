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
async fn ensure_tunnel(state : Json, port : Int32) -> Unit {
  if field(state, "tunnelDirectory") is Some(Json::String(directory)) {
    if @fs.exists(directory + "/state.json") && worker_alive(directory) {
      let saved = @json.parse(@fs.read_file(directory + "/state.json").text())
      guard field(saved, "workspaceUid") == field(state, "workspaceUid") &&
        field(saved, "localPort") == Some(Json::number(port.to_double())) else {
        raise AdapterError("Tunnel ownership changed")
      }
      wait_tunnel(directory)
      return
    }
    close_tunnel(state)
  }
  let directory = @fs.tmpdir(prefix="oe")
  set_field(state, "tunnelDirectory", Json::string(directory))
  let saved = Json::empty_object()
  for
    name in [
      "workspaceId", "workspaceUid", "user", "command", "devsyEnv", "home", "context",
    ] {
    if field(state, name) is Some(value) {
      set_field(saved, name, value)
    }
  }
  set_field(saved, "localPort", Json::number(port.to_double()))
  @fs.write_file(directory + "/state.json", saved.stringify(), permission=0o600)
  errdefer close_tunnel(state)
  @fs.write_file(directory + "/enabled", "", permission=0o600)
  let sink = @process.redirect_to_file("/dev/null", shared=true)
  defer sink.close()
  ignore(
    @process.spawn_orphan(
      adapter_executable(),
      ["--tunnel-worker", directory],
      stdin=@process.redirect_from_file("/dev/null"),
      stdout=sink,
      stderr=sink,
    ),
  )
  wait_tunnel(directory)
}

///|
async fn wait_tunnel(directory : String) -> Unit {
  @async.with_timeout(30000, async fn() {
    while true {
      if @fs.exists(directory + "/status.json") && worker_alive(directory) {
        let status = @json.parse(
          @fs.read_file(directory + "/status.json").text(),
        )
        if field(status, "status") == Some(Json::string("connected")) {
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
}

///|
async fn close_tunnel(state : Json) -> Unit {
  guard field(state, "tunnelDirectory") is Some(Json::String(directory)) else {
    return
  }
  if !@fs.exists(directory) {
    return
  }
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
    // Only remove this worker's files; retain unexpected directory contents.
    for
      name in [
        "state.json", "status.json", "status.tmp", "worker.lock", "socket",
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
        ssh_args(state) + ["-S", directory + "/socket", "-O", "exit"],
      ),
    )
  }
  @fs.rmdir(directory) catch {
    _ => ()
  }
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
  let port = match field(state, "localPort") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => raise AdapterError("Missing tunnel port")
  }
  let enabled = directory + "/enabled"
  let mut attempt = 0
  while @fs.exists(enabled) {
    tunnel_status(directory, "connecting")
    @async.with_task_group(async fn(group) {
      let sink = @process.redirect_to_file("/dev/null", shared=true)
      defer sink.close()
      // A saved ID alone must not reconnect into a replacement workspace.
      guard worker_workspace(state, directory) is Some(current) &&
        field(current, "uid") == field(state, "workspaceUid") else {
        if @fs.exists(enabled) {
          @fs.remove(enabled)
        }
        tunnel_status(directory, "ownership-error")
        return
      }
      // The worker owns this master and reaps it before reconnecting.
      let child = @process.spawn(
        group,
        "ssh",
        ssh_args(state) +
        [
          "-M",
          "-S",
          directory + "/socket",
          "-N",
          "-o",
          "ExitOnForwardFailure=yes",
          "-o",
          "ServerAliveInterval=10",
          "-o",
          "ServerAliveCountMax=3",
          "-L",
          "127.0.0.1:\{port}:127.0.0.1:47121",
        ],
        stdin=@process.redirect_from_file("/dev/null"),
        stdout=sink,
        stderr=sink,
        no_wait=true,
      )
      let mut connected = false
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
        @async.sleep(100)
      }
      if !@fs.exists(enabled) {
        @async.with_timeout(2000, async fn() {
          ignore(
            @process.collect_output(
              "ssh",
              ssh_args(state) + ["-S", directory + "/socket", "-O", "exit"],
            ),
          )
        }) catch {
          _ => ()
        }
        child.cancel()
      } else {
        let code = child.wait()
        save_diagnostic("orca-tunnel", "disconnected", exit_code=code)
      }
    }) catch {
      _ => save_diagnostic("orca-tunnel", "process-error")
    }
    if @fs.exists(enabled) {
      tunnel_status(directory, "disconnected")
      attempt = if attempt < 6 { attempt + 1 } else { 6 }
      let delay = if attempt < 6 { 500 * (1 << attempt) } else { 30000 }
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
      ssh_args(state) + ["-S", directory + "/socket", "-O", "check"],
    )
    guard status == 0 else { raise AdapterError("Tunnel not ready") }
    let port = match field(state, "localPort") {
      Some(Json::Number(value, ..)) => value.to_int()
      _ => raise AdapterError("Missing tunnel port")
    }
    let socket = @socket.Tcp::connect(
      @socket.Addr::parse("127.0.0.1:" + port.to_string()),
    )
    socket.close()
  })
}

///|
async fn worker_workspace(state : Json, directory : String) -> Json? {
  @async.with_timeout(10000, async fn() {
    @async.with_task_group(async fn(group) {
      let query = group.spawn(async fn() { workspace(state) })
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
