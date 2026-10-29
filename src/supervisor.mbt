///|
async fn publish_file(path : String, content : String) -> Unit {
  @fs.write_file(path + ".tmp", content, permission=0o600)
  @fs.rename(path + ".tmp", path, replace=true)
}

///|
async fn supervisor_alive(directory : String) -> Bool {
  let lock = @fs.open(
    directory + "/supervisor.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  !lock.try_lock(Exclusive)
}

///|
async fn ensure_supervisor(initial_workspace? : String) -> Unit {
  let directory = adapter_state_home()
  @fs.mkdir(directory, recursive=true, permission=0o700, allow_exist=true)
  let startup = @fs.open(
    directory + "/supervisor-startup.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer startup.close()
  @async.with_timeout(10000, async fn() {
    while !startup.try_lock(Exclusive) {
      @async.sleep(10)
    }
    if @fs.exists(directory + "/shutdown") {
      @fs.remove(directory + "/shutdown")
    }
    if supervisor_alive(directory) {
      save_diagnostic("supervisor-launch", "reused", evidence={
        "stateDirectory": directory,
      })
      return
    }
    launch_supervisor(directory, initial_workspace?)
  })
}

///|
async fn launch_supervisor(
  directory : String,
  initial_workspace? : String,
) -> Unit {
  let sink = @process.redirect_to_file("/dev/null", shared=true)
  defer sink.close()
  ignore(
    @process.spawn_orphan(
      saved_proxy_executable(),
      ["--supervisor", directory] +
      initial_workspace.map(value => [value]).unwrap_or([]),
      stdin=@process.redirect_from_file("/dev/null"),
      stdout=sink,
      stderr=sink,
    ),
  )
  while !supervisor_alive(directory) {
    @async.sleep(10)
  }
}

///|
async fn restart_supervisor() -> Int32 {
  let directory = adapter_state_home()
  save_diagnostic("supervisor-launch", "restart", evidence={
    "stateDirectory": directory,
  })
  errdefer save_diagnostic(
    "supervisor-launch",
    "failed",
    error_type="restart_failed",
    evidence={ "stateDirectory": directory },
  )
  @fs.mkdir(directory, recursive=true, permission=0o700, allow_exist=true)
  let startup = @fs.open(
    directory + "/supervisor-startup.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer startup.close()
  @async.with_timeout(30000, async fn() {
    while !startup.try_lock(Exclusive) {
      @async.sleep(10)
    }
    defer (@fs.remove(directory + "/shutdown") catch { _ => () })
    if supervisor_alive(directory) {
      @fs.write_file(directory + "/shutdown", "", permission=0o600)
      while supervisor_alive(directory) {
        @async.sleep(10)
      }
    }
    if @fs.exists(directory + "/shutdown") {
      @fs.remove(directory + "/shutdown")
    }
    let failures : Ref[Int32] = { val: 0, }
    let transports = directory + "/transports"
    if @fs.exists(transports) {
      @async.with_task_group(async fn(group) {
        let permits = @async.Semaphore(16)
        for name in @fs.readdir(transports) {
          let transport = transports + "/" + name
          if @fs.exists(transport + "/state.json") &&
            !@fs.exists(transport + "/done") {
            permits.acquire()
            group.spawn_bg(async fn() {
              defer permits.release()
              supervise_transport(transport, force=true) catch {
                error => {
                  failures.val += 1
                  save_diagnostic(
                    "supervisor-transport",
                    "failed",
                    error_type="transport_cleanup_failed",
                    error_message=diagnostic_error(error),
                    evidence={ "transport": transport },
                  )
                  progress_message("SSH transport cleanup failed: " + transport)
                }
              }
            })
          }
        }
      })
    }
    launch_supervisor(directory)
    failures.val
  })
}

///|
pub async fn supervisor(
  directory : String,
  initial_workspace? : String,
) -> Unit {
  guard directory == adapter_state_home() else {
    raise AdapterError("Supervisor state directory mismatch")
  }
  let lock = @fs.open(
    directory + "/supervisor.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    return
  }
  publish_file(directory + "/supervisor.pid", proxy_pid().to_string())

  let mut released = false
  defer (if !released {
    @fs.remove(directory + "/supervisor.pid") catch {
      _ => ()
    }
  })
  save_diagnostic("supervisor", "started", evidence={
    "stateDirectory": directory,
  })
  defer save_diagnostic("supervisor", "stopped")
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let identity : Json = {
    "protocol": 1,
    "pid": proxy_pid().to_string(),
    "start": process_start(proxy_pid()).to_string(),
  }
  let descriptor : Json = {
    "pid": required(identity, "pid"),
    "start": required(identity, "start"),
    "port": listener.addr.port().to_string(),
  }
  publish_file(directory + "/supervisor.json", descriptor.stringify())
  let environments : Map[String, Map[String, String]] = Map([])
  if initial_workspace is Some(workspace) {
    let canonical = @fs.realpath(workspace)
    guard canonical.has_prefix(@fs.realpath(directory) + "/tunnels/") else {
      raise AdapterError("Initial workspace is outside the state directory")
    }
    let saved = @json.parse(
      @fs.read_file(workspace + "/environment.json").text(),
    )
    guard saved is Json::Object(values) else {
      raise AdapterError("Invalid saved workspace environment")
    }
    let environment : Map[String, String] = Map([])
    for (name, value) in values {
      guard value is Json::String(value) else {
        raise AdapterError("Invalid saved workspace environment")
      }
      environment.set(name, value)
    }
    environments.set(canonical, environment)
    @fs.write_file(workspace + "/request", "", permission=0o600)
  }
  let registrations : Ref[Int32] = { val: 0, }
  let active : Map[String, Bool] = Map([])
  let transports : Map[String, Bool] = Map([])
  let mut idle_since = @env.now()
  @async.with_task_group(async fn(group) {
    let registration_slots = @async.Semaphore(16)
    group.spawn_bg(no_wait=true, async fn() {
      while true {
        registration_slots.acquire()
        let (socket, _) = listener.accept()
        registrations.val += 1
        group.spawn_bg(no_wait=true, async fn() {
          defer {
            registrations.val -= 1
            registration_slots.release()
          }
          accept_registration(socket, directory, environments, identity) catch {
            error =>
              save_diagnostic(
                "supervisor-registration",
                "failed",
                error_type="registration_failed",
                error_message=diagnostic_error(error),
              )
          }
        })
      }
    })
    while @fs.exists(directory) {
      if @fs.exists(directory + "/shutdown") {
        return
      }
      for workspace in environments.keys().to_array() {
        if !@fs.exists(workspace) {
          environments.remove(workspace)
        }
      }
      let base = directory + "/tunnels"
      if @fs.exists(base) {
        for name in @fs.readdir(base) {
          let workspace = base + "/" + name
          try {
            let requested = @fs.exists(workspace + "/request")
            if !requested {
              continue
            }
            let canonical = @fs.realpath(workspace)
            guard environments.get(canonical) is Some(environment) else {
              continue
            }
            if active.contains(workspace) ||
              !@fs.exists(workspace + "/enabled") ||
              !@fs.exists(workspace + "/state.json") {
              continue
            }
            if requested {
              @fs.remove(workspace + "/request")
            }
            active.set(workspace, true)
            group.spawn_bg(no_wait=true, async fn() {
              defer active.remove(workspace)
              try {
                save_diagnostic(
                  "supervisor-workspace",
                  "started",
                  tunnel_directory=workspace,
                  recording=environment.get("ORCA_ENV_DEVSY_RECORDING") !=
                    Some("0"),
                )
                if !worker_alive(workspace) {
                  tunnel_status(
                    workspace,
                    "connecting",
                    recording=environment.get("ORCA_ENV_DEVSY_RECORDING") !=
                      Some("0"),
                  )
                  git_relay_status(
                    workspace,
                    "pending",
                    recording=environment.get("ORCA_ENV_DEVSY_RECORDING") !=
                      Some("0"),
                  )
                }
                tunnel_worker(workspace, environment)
                save_diagnostic(
                  "supervisor-workspace",
                  "stopped",
                  tunnel_directory=workspace,
                  recording=environment.get("ORCA_ENV_DEVSY_RECORDING") !=
                    Some("0"),
                )
              } catch {
                error => {
                  save_diagnostic(
                    "supervisor-workspace",
                    "failed",
                    tunnel_directory=workspace,
                    error_type="workspace_task_failed",
                    error_message=diagnostic_error(error, environment~),
                    recording=environment.get("ORCA_ENV_DEVSY_RECORDING") !=
                      Some("0"),
                  )
                  @async.sleep(1000)
                }
              }
            })
          } catch {
            error =>
              save_diagnostic(
                "supervisor-workspace",
                "failed",
                tunnel_directory=workspace,
                error_type="workspace_registration_failed",
                error_message=diagnostic_error(error),
              )
          }
        }
      }
      let base = directory + "/transports"
      if @fs.exists(base) {
        for name in @fs.readdir(base) {
          let transport = base + "/" + name
          if transports.contains(transport) ||
            !@fs.exists(transport + "/state.json") ||
            @fs.exists(transport + "/done") {
            continue
          }
          transports.set(transport, true)
          group.spawn_bg(no_wait=true, async fn() {
            defer transports.remove(transport)
            supervise_transport(transport) catch {
              error =>
                save_diagnostic(
                  "supervisor-transport",
                  "failed",
                  error_type="transport_cleanup_failed",
                  error_message=diagnostic_error(error),
                )
            }
          })
        }
      }
      if !active.is_empty() || !transports.is_empty() || registrations.val > 0 {
        idle_since = @env.now()
      } else if @env.now() - idle_since >= 1000 {
        let startup = @fs.open(
          directory + "/supervisor-startup.lock",
          mode=ReadWrite,
          create_mode=OpenOrCreate,
          permission=0o600,
        )
        defer startup.close()
        if startup.try_lock(Exclusive) &&
          !supervisor_pending(directory, environments) {
          listener.close()
          @fs.remove(directory + "/supervisor.json")
          @fs.remove(directory + "/supervisor.pid")
          released = true
          lock.unlock()
          return
        }
      }
      @async.sleep(100)
    }
  })
}

///|
async fn supervise_transport(directory : String, force~ : Bool = false) -> Unit {
  let state = @json.parse(@fs.read_file(directory + "/state.json").text())
  let recording = field(state, "recording") != Some(Json::boolean(false))
  let pid = @string.parse_int(required(state, "pid"))
  guard pid > 1 else { raise AdapterError("Invalid transport owner") }
  let owner = @string.parse_int(required(state, "ownerPid"))
  let owner_start = @string.parse_int64(required(state, "ownerStart"))
  guard owner > 1 && owner_start > 0 else {
    raise AdapterError("Invalid SSH owner identity")
  }
  let start = @string.parse_int64(required(state, "start"))
  save_diagnostic(
    "supervisor-transport",
    "started",
    evidence={
      "pid": pid,
      "start": start.to_string(),
      "ownerPid": owner,
      "ownerStart": owner_start.to_string(),
      "lease": field(state, "lease").unwrap_or(Json::null()),
    },
    recording~,
  )
  let reason : Ref[String] = { val: "supervisor_shutdown", }
  let mut detached = false
  defer @async.protect_from_cancel(async fn() {
    guard reason.val != "inspection_failed" else { return }
    if transport_group_alive(pid, start) {
      if reason.val != "transport_exited" {
        ignore(proxy_signal(-pid, 15))
        @async.sleep(500)
      }
      if transport_group_alive(pid, start) {
        ignore(proxy_signal(-pid, 9))
        @async.with_timeout(2000, async fn() {
          while transport_group_alive(pid, start) {
            @async.sleep(10)
          }
        })
      }
    }
    save_diagnostic(
      "ssh-proxy",
      "cleaned",
      evidence={ "pid": pid, "transport": directory, "reason": reason.val },
      recording~,
    )
    publish_file(directory + "/done", reason.val)
    @fs.rmdir(directory, recursive=true)
    save_diagnostic(
      "supervisor-transport",
      "stopped",
      evidence={ "pid": pid, "reason": reason.val },
      recording~,
    )
  })
  if force {
    return
  }
  while true {
    let owner_current = process_start(owner)
    let transport_current = process_start(pid)
    guard owner_current >= 0 && transport_current >= 0 else {
      raise AdapterError("Cannot inspect SSH transport identity")
    }
    if transport_current != start {
      reason.val = "transport_exited"
      return
    }
    if owner_current != owner_start {
      let closed = if field(state, "lease") != Some(Json::string("")) {
        1
      } else {
        transport_input_closed(pid)
      }
      guard closed >= 0 else {
        reason.val = "inspection_failed"
        let failure = match -closed / 65536 {
          1 => "pipe_info"
          2 => "pipe_info_short"
          3 => "input_open"
          4 => "input_stat"
          5 => "input_not_pipe"
          6 => "input_poll"
          _ => "input_poll_invalid"
        }
        save_diagnostic(
          "supervisor-transport",
          "inspection_failed",
          evidence={
            "pid": pid,
            "transport": directory,
            "failure": failure,
            "errno": -closed % 65536,
          },
          recording~,
        )
        return
      }
      if closed == 1 {
        reason.val = "owner_exited"
        return
      }
      if !detached {
        detached = true
        save_diagnostic(
          "supervisor-transport",
          "adopted",
          evidence={ "pid": pid, "reason": "ssh_owner_detached" },
          recording~,
        )
      }
    }
    @async.sleep(100)
  }
}

///|
async fn supervisor_pending(
  directory : String,
  environments : Map[String, Map[String, String]],
) -> Bool {
  let base = directory + "/tunnels"
  if @fs.exists(base) {
    for name in @fs.readdir(base) {
      let workspace = base + "/" + name
      if environments.contains(@fs.realpath(workspace)) &&
        @fs.exists(workspace + "/enabled") &&
        @fs.exists(workspace + "/state.json") &&
        @fs.exists(workspace + "/request") {
        return true
      }
    }
  }
  let base = directory + "/transports"
  if @fs.exists(base) {
    for name in @fs.readdir(base) {
      if @fs.exists(base + "/" + name + "/state.json") &&
        !@fs.exists(base + "/" + name + "/done") {
        return true
      }
    }
  }
  false
}
