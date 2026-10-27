///|
async fn read_registration(socket : @socket.Tcp, limit : Int32) -> Json {
  let header = @buffer.Buffer()
  while true {
    let byte = socket.read_exactly(1)
    if byte == b"\n" {
      break
    }
    guard header.length() < 8 else {
      raise AdapterError("Invalid registration length")
    }
    header.write_bytes(byte)
  }
  let length = @string.parse_int(@utf8.decode(header.to_bytes()))
  guard length > 0 && length <= limit else {
    raise AdapterError("Registration is too large")
  }
  @json.parse(@utf8.decode(socket.read_exactly(length))) catch {
    _ => raise AdapterError("Invalid registration JSON")
  }
}

///|
async fn write_registration(socket : @socket.Tcp, value : Json) -> Unit {
  let bytes = @utf8.encode(value.stringify())
  guard bytes.length() <= 4194304 else {
    raise AdapterError("Registration is too large")
  }
  socket.write(bytes.length().to_string() + "\n")
  socket.write(bytes)
}

///|
async fn register_workspace(directory : String, environment? : Json) -> Unit {
  let mut detail = "Supervisor registration endpoint is not ready"
  @async.with_timeout(10000, async fn() {
    while true {
      try {
        ensure_supervisor()
        register_workspace_inner(directory, environment?)
        return
      } catch {
        error => detail = redact_credentials(error.to_string())
      }
      @async.sleep(100)
    }
  }) catch {
    @async.TimeoutError =>
      raise AdapterError("Workspace registration timed out: " + detail)
    error => raise error
  }
}

///|
async fn register_workspace_inner(
  directory : String,
  environment? : Json,
) -> Unit {
  let path = adapter_state_home() + "/supervisor.json"
  let descriptor = @json.parse(@fs.read_file(path).text())
  let pid = @string.parse_int(required(descriptor, "pid"))
  let start = @string.parse_int64(required(descriptor, "start"))
  guard pid > 1 && start > 0 && process_start(pid) == start else {
    raise AdapterError("Supervisor registration endpoint is stale")
  }
  let port = @string.parse_int(required(descriptor, "port"))
  guard port > 0 && port <= 65535 else {
    raise AdapterError("Invalid supervisor port")
  }
  let socket = @socket.Tcp::connect(
    @socket.Addr::parse("127.0.0.1:" + port.to_string()),
  )
  defer socket.close()
  let peer = read_registration(socket, 4096)
  guard field(peer, "protocol") == Some(Json::number(1)) &&
    field(peer, "pid") == field(descriptor, "pid") &&
    field(peer, "start") == field(descriptor, "start") else {
    raise AdapterError("Supervisor registration endpoint changed")
  }
  let environment = environment.unwrap_or_else(() => {
    let values = Json::empty_object()
    for (name, value) in @env.get_env_vars() {
      set_field(values, name, Json::string(value))
    }
    values
  })
  write_registration(socket, {
    "directory": directory,
    "environment": environment,
  })
  let reply = read_registration(socket, 4096)
  guard field(reply, "accepted") == Some(Json::boolean(true)) else {
    raise AdapterError("Supervisor rejected workspace registration")
  }
}

///|
async fn accept_registration(
  socket : @socket.Tcp,
  root : String,
  environments : Map[String, Map[String, String]],
  identity : Json,
) -> Unit {
  defer socket.close()
  @async.with_timeout(10000, async fn() {
    write_registration(socket, identity)
    let request = read_registration(socket, 4194304)
    let directory = @fs.realpath(required(request, "directory"))
    guard directory.has_prefix(@fs.realpath(root) + "/tunnels/") &&
      @fs.exists(directory + "/state.json") else {
      raise AdapterError(
        "Workspace registration is outside the state directory",
      )
    }
    guard field(request, "environment") is Some(Json::Object(values)) else {
      raise AdapterError("Missing workspace execution environment")
    }
    let environment : Map[String, String] = Map([])
    for (name, value) in values {
      guard value is Json::String(value) else {
        raise AdapterError("Invalid workspace execution environment")
      }
      environment.set(name, value)
    }
    let lock = @fs.open(
      directory + "/environment.lock",
      mode=ReadWrite,
      create_mode=OpenOrCreate,
      permission=0o600,
    )
    defer lock.close()
    while !lock.try_lock(Exclusive) {
      @async.sleep(10)
    }
    let temporary = directory + "/environment.json.tmp"
    if @fs.exists(temporary) {
      @fs.remove(temporary)
    }
    defer (@fs.remove(temporary) catch { _ => () })
    @fs.write_file(
      temporary,
      field(request, "environment").unwrap().stringify(),
      create_mode=CreateNew,
      permission=0o600,
    )
    @fs.rename(temporary, directory + "/environment.json", replace=true)
    environments.set(directory, environment)
    if environment.get("ORCA_ENV_DEVSY_RECORDING") != Some("0") {
      save_diagnostic(
        "supervisor-registration",
        "success",
        tunnel_directory=directory,
        recording=true,
      )
    }
    write_registration(socket, { "accepted": true })
  })
}
