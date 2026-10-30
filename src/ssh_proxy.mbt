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
extern "C" fn transport_input_closed(pid : Int32) -> Int32 = "orca_transport_input_closed"

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
    let repeated = group_exists(pid)
    raise AdapterError(
      "Cannot inspect transport process group (errno " +
      (-present).to_string() +
      ", expected start " +
      start.to_string() +
      ", current start " +
      current.to_string() +
      ", current group " +
      process_group(pid).to_string() +
      ", repeated group result " +
      repeated.to_string() +
      ")",
    )
  }
  present == 1
}

///|
#borrow(path)
extern "C" fn transport_access(path : Bytes, mode : Int32) -> Int32 = "access"

///|
extern "C" fn proxy_parent() -> Int32 = "getppid"

///|
extern "C" fn prepare_proxy() -> Int32 = "orca_prepare_proxy"

///|
#borrow(command, args)
extern "C" fn proxy_exec(command : Bytes, args : FixedArray[Bytes?]) -> Int32 = "orca_transport_exec"

///|
pub fn prepare_ssh_proxy() -> Bool {
  prepare_proxy() == 0 &&
  (proxy_group() == proxy_pid() || proxy_process_group(0, 0) == 0)
}

///|
pub async fn ssh_proxy(args : Array[String], lease~ : String = "") -> Int32 {
  guard args.length() > 0 else { raise AdapterError("Missing SSH transport") }
  let pid = proxy_pid()
  let start = process_start(pid)
  let parent = proxy_parent()
  let parent_start = process_start(parent)
  guard parent > 1 && start > 0 && parent_start > 0 else {
    raise AdapterError("SSH transport owner is unavailable")
  }
  ensure_supervisor()
  let base = adapter_state_home() + "/transports"
  @fs.mkdir(base, recursive=true, permission=0o700, allow_exist=true)
  let directory = base + "/" + pid.to_string() + "." + start.to_string()
  @fs.mkdir(directory, permission=0o700)
  errdefer (if !@fs.exists(directory + "/state.json") {
    @fs.rmdir(directory, recursive=true)
  })
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
  let state : Json = {
    "pid": pid.to_string(),
    "start": start.to_string(),
    "ownerPid": parent.to_string(),
    "ownerStart": parent_start.to_string(),
    "recording": @env.get_env_var("ORCA_ENV_DEVSY_RECORDING") != Some("0"),
    "lease": if lease == "" {
      ""
    } else {
      @fs.realpath(lease)
    },
  }
  publish_file(directory + "/state.json", state.stringify())
  ensure_supervisor()
  guard proxy_parent() == parent && process_start(parent) == parent_start else {
    raise AdapterError("SSH owner exited before transport startup")
  }
  let encoded : FixedArray[Bytes?] = FixedArray::makei(args.length() + 1, i => {
    if i == args.length() {
      None
    } else {
      Some(@utf8.encode(args[i] + "\u0000"))
    }
  })
  ignore(proxy_exec(encoded[0].unwrap(), encoded))
  raise AdapterError("SSH transport exec failed")
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
      if !supervisor_alive(adapter_state_home()) {
        ensure_supervisor()
      }
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
