///|
extern "C" fn proxy_process_group(pid : Int32, group : Int32) -> Int32 = "setpgid"

///|
extern "C" fn proxy_pid() -> Int32 = "getpid"

///|
extern "C" fn proxy_group() -> Int32 = "getpgrp"

///|
extern "C" fn proxy_signal(pid : Int32, signal : Int32) -> Int32 = "kill"

///|
extern "C" fn process_start(pid : Int32) -> Int64 = "orca_process_start"

///|
extern "C" fn process_group(pid : Int32) -> Int32 = "getpgid"

///|
extern "C" fn group_exists(pid : Int32) -> Int32 = "orca_group_exists"

///|
fn transport_group_alive(pid : Int32, start : Int64) -> Bool raise {
  let current = process_start(pid)
  guard current >= 0 else {
    raise AdapterError("Cannot inspect transport process identity")
  }
  if current > 0 && current != start {
    return false
  }
  if current > 0 && process_group(pid) != pid {
    return false
  }
  let present = group_exists(pid)
  guard present >= 0 else {
    raise AdapterError("Cannot inspect transport process group")
  }
  present == 1
}

///|
#borrow(path)
extern "C" fn transport_open(path : Bytes, flags : Int32) -> Int32 = "open"

///|
extern "C" fn transport_flock(fd : Int32, operation : Int32) -> Int32 = "flock"

///|
extern "C" fn transport_close(fd : Int32) -> Int32 = "close"

///|
#borrow(path)
extern "C" fn transport_access(path : Bytes, mode : Int32) -> Int32 = "access"

///|
#borrow(command, args)
extern "C" fn proxy_exec(command : Bytes, args : FixedArray[Bytes?]) -> Int32 = "execvp"

///|
pub fn ssh_transport(args : Array[String], lease : String) -> Int32 {
  if args.is_empty() || !prepare_ssh_proxy() {
    return 127
  }
  let owner = transport_open(@utf8.encode(lease + "\u0000"), 0)
  if owner < 0 {
    return 127
  }
  if transport_flock(owner, 1) != 0 ||
    transport_access(@utf8.encode(lease + ".ready\u0000"), 0) != 0 {
    ignore(transport_close(owner))
    return 127
  }
  ignore(transport_close(owner))
  let encoded : FixedArray[Bytes?] = FixedArray::makei(args.length() + 1, i => {
    if i == args.length() {
      None
    } else {
      Some(@utf8.encode(args[i] + "\u0000"))
    }
  })
  ignore(proxy_exec(encoded[0].unwrap(), encoded))
  127
}

///|
pub fn prepare_ssh_proxy() -> Bool {
  proxy_group() == proxy_pid() || proxy_process_group(0, 0) == 0
}

///|
pub async fn ssh_proxy(args : Array[String], lease~ : String = "") -> Int32 {
  guard args.length() > 0 else { raise AdapterError("Missing SSH transport") }
  ensure_supervisor()
  let base = adapter_state_home() + "/transports"
  @fs.mkdir(base, recursive=true, permission=0o700, allow_exist=true)
  let directory = base +
    "/" +
    proxy_pid().to_string() +
    "." +
    @env.now().to_string()
  @fs.mkdir(directory, permission=0o700)
  defer @async.protect_from_cancel(async fn() {
    if !@fs.exists(directory + "/state.json") && @fs.exists(directory) {
      @fs.rmdir(directory, recursive=true)
    }
  })
  let owner = @fs.open(
    directory + "/owner.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer owner.close()
  guard owner.try_lock(Exclusive) else {
    raise AdapterError("Transport owner is busy")
  }
  let lock = if lease == "" {
    None
  } else {
    Some(
      @fs.open(
        lease,
        mode=ReadWrite,
        create_mode=OpenOrCreate,
        permission=0o600,
      ),
    )
  }
  defer (if lock is Some(file) { file.close() })
  if lock is Some(file) {
    guard file.try_lock(Shared) else {
      raise AdapterError("SSH proxy is closing")
    }
  }
  let code = @async.with_task_group(async fn(group) {
    let (input, writer) = @process.write_to_process()
    defer writer.close()
    let startup = @fs.open(
      directory + "/group.lock",
      mode=ReadWrite,
      create_mode=OpenOrCreate,
      permission=0o600,
    )
    defer startup.close()
    guard startup.try_lock(Exclusive) else {
      raise AdapterError("Transport startup is busy")
    }
    let child = @process.spawn(
      group,
      adapter_executable(),
      ["--ssh-transport", directory + "/group.lock"] + args,
      stdin=input,
      cancel_handler=@process.CancellationHandler(async fn(pid) {
        if proxy_signal(-pid, 15) != 0 {
          ignore(proxy_signal(pid, 15))
        }
        @async.sleep(500)
        if proxy_signal(-pid, 9) != 0 {
          ignore(proxy_signal(pid, 9))
        }
      }),
    )
    @async.with_timeout(2000, async fn() {
      while process_group(child.pid) != child.pid {
        guard child.try_wait() is None else {
          raise AdapterError("Transport exited before group setup")
        }
        @async.sleep(1)
      }
    })
    let start = process_start(child.pid)
    guard start > 0 else {
      raise AdapterError("Transport exited before registration")
    }
    let state : Json = {
      "pid": child.pid.to_string(),
      "start": start.to_string(),
      "recording": @env.get_env_var("ORCA_ENV_DEVSY_RECORDING") != Some("0"),
      "lease": if lease == "" {
        ""
      } else {
        @fs.realpath(lease)
      },
    }
    @fs.write_file(
      directory + "/state.tmp",
      state.stringify(),
      permission=0o600,
    )
    @fs.rename(directory + "/state.tmp", directory + "/state.json")
    @fs.write_file(directory + "/group.lock.ready", "", permission=0o600)
    startup.unlock()
    ensure_supervisor()
    group.spawn_bg(no_wait=true, async fn() {
      while @stdio.stdin.read_some(max_len=65536) is Some(bytes) {
        writer.write(bytes) catch {
          _ => break
        }
      }
      writer.close()
      publish_file(directory + "/eof", @env.now().to_string())
    })
    let code = child.wait()
    publish_file(directory + "/exited", code.to_string())
    while !@fs.exists(directory + "/done") {
      @async.sleep(10)
    }
    let cancelled = @fs.read_file(directory + "/done").text() == "stdin_eof"
    @fs.rmdir(directory, recursive=true)
    if cancelled {
      0
    } else if code < 0 {
      128 - code
    } else {
      code
    }
  })
  code
}

///|
async fn wait_ssh_proxy(state : Json, role : String) -> Unit {
  let path = required(state, "socketDirectory") + "/" + role + "-proxy.lock"
  if !@fs.exists(path) {
    return
  }
  let canonical = @fs.realpath(path)
  let lock = @fs.open(path, mode=ReadWrite)
  defer lock.close()
  @async.with_timeout(5000, async fn() {
    while !lock.try_lock(Exclusive) {
      @async.sleep(25)
    }
    let pending = owned_transports(adapter_state_home(), canonical)
    if !pending.is_empty() {
      ensure_supervisor()
      wait_transport_cleanup(pending)
    }
  })
}

///|
async fn owned_transports(root : String, lease : String) -> Array[String] {
  let base = root + "/transports"
  let pending = []
  if !@fs.exists(base) {
    return pending
  }
  for name in @fs.readdir(base) {
    let directory = base + "/" + name
    let receipt = directory + "/state.json"
    let owned = try
      field(@json.parse(@fs.read_file(receipt).text()), "lease") ==
      Some(Json::string(lease))
    catch {
      error => if !@fs.exists(receipt) { false } else { raise error }
    }
    if owned {
      pending.push(directory)
    }
  }
  pending
}

///|
async fn wait_transport_cleanup(pending : Array[String]) -> Unit {
  for directory in pending {
    while @fs.exists(directory) && !@fs.exists(directory + "/done") {
      @async.sleep(25)
    }
  }
}
