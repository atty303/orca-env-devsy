///|
extern "C" fn proxy_process_group(pid : Int32, group : Int32) -> Int32 = "setpgid"

///|
extern "C" fn proxy_pid() -> Int32 = "getpid"

///|
extern "C" fn proxy_parent() -> Int32 = "getppid"

///|
extern "C" fn proxy_group() -> Int32 = "getpgrp"

///|
extern "C" fn proxy_signal(pid : Int32, signal : Int32) -> Int32 = "kill"

///|
#borrow(command, args)
extern "C" fn proxy_exec(command : Bytes, args : FixedArray[Bytes?]) -> Int32 = "execvp"

///|
pub fn ssh_transport(args : Array[String]) -> Int32 {
  if args.is_empty() || !prepare_ssh_proxy() {
    return 127
  }
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
  @async.with_task_group(async fn(group) {
    let (input, writer) = @process.write_to_process()
    defer writer.close()
    // This guardian starts in a separate group. A caller's hard group stop
    // leaves transport cleanup alive even if data forwarding is blocked.
    let guardian = @process.spawn(
      group,
      adapter_executable(),
      ["--ssh-proxy-worker", lease, proxy_pid().to_string()] + args,
      stdin=input,
      cancel_handler=@process.graceful_cancel(timeout=3000),
    )
    group.spawn_bg(no_wait=true, async fn() {
      while @stdio.stdin.read_some(max_len=65536) is Some(bytes) {
        writer.write(bytes) catch {
          _ => break
        }
      }
      writer.close()
    })
    let code = guardian.wait()
    if code < 0 {
      128 - code
    } else {
      code
    }
  })
}

///|
pub async fn ssh_proxy_worker(
  args : Array[String],
  lease~ : String,
  parent~ : String,
) -> Int32 {
  guard args.length() > 0 else { raise AdapterError("Missing SSH transport") }
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
  save_diagnostic("ssh-proxy", "started")
  let mut cancelled = false
  let code = @async.with_task_group(async fn(group) {
    let (input, writer) = @process.write_to_process()
    defer writer.close()
    let (errors, stderr) = @process.read_from_process()
    defer errors.close()
    let child = @process.spawn(
      group,
      adapter_executable(),
      ["--ssh-transport"] + args,
      stdin=input,
      stderr~,
      cancel_handler=@process.CancellationHandler(async fn(pid) {
        if proxy_signal(-pid, 15) != 0 {
          ignore(proxy_signal(pid, 15))
        }
        @async.sleep(500)
        ignore(proxy_signal(-pid, 9))
        ignore(proxy_signal(pid, 9))
      }),
    )
    // The group outlives a launcher that exits before its own children.
    defer @async.protect_from_cancel(async fn() {
      if child.try_wait() is None {
        if proxy_signal(-child.pid, 15) != 0 {
          ignore(proxy_signal(child.pid, 15))
        }
        let deadline = @env.now() + 500
        while child.try_wait() is None && @env.now() < deadline {
          @async.sleep(10)
        }
      }
      ignore(proxy_signal(-child.pid, 9))
    })
    // Parent liveness is independent of the data pipe: a full transport
    // stdin must not prevent cleanup after the caller's process group dies.
    group.spawn_bg(no_wait=true, async fn() {
      while proxy_parent().to_string() == parent {
        @async.sleep(100)
      }
      if child.try_wait() is None {
        cancelled = true
        child.cancel()
      }
    })
    let error_forwarding = group.spawn(no_wait=true, async fn() {
      let mut forwarding = true
      while errors.read_some(max_len=4096) is Some(bytes) {
        if forwarding {
          @stdio.stderr.write(bytes) catch {
            _ => forwarding = false
          }
        }
      }
    })
    group.spawn_bg(no_wait=true, async fn() {
      while @stdio.stdin.read_some(max_len=65536) is Some(bytes) {
        writer.write(bytes) catch {
          _ => break
        }
      }
      writer.close()
      // Drain EOF before bounded shutdown of Devsy service channels that
      // stay alive after their SSH client has closed the transport.
      @async.sleep(1000)
      if child.try_wait() is None {
        cancelled = true
        child.cancel()
      }
    })
    let code = child.wait() catch {
      error => if cancelled { 0 } else { raise error }
    }
    ignore(proxy_signal(-child.pid, 9))
    @async.with_timeout(250, async fn() { error_forwarding.wait() }) catch {
      _ => ()
    }
    code
  })
  save_diagnostic(
    "ssh-proxy",
    if cancelled {
      "cancelled"
    } else {
      "stopped"
    },
    exit_code=code,
  )
  if cancelled {
    0
  } else if code < 0 {
    128 - code
  } else {
    code
  }
}

///|
async fn wait_ssh_proxy(state : Json, role : String) -> Unit {
  let path = required(state, "socketDirectory") + "/" + role + "-proxy.lock"
  if !@fs.exists(path) {
    return
  }
  let lock = @fs.open(path, mode=ReadWrite)
  defer lock.close()
  @async.with_timeout(2000, async fn() {
    while !lock.try_lock(Exclusive) {
      @async.sleep(25)
    }
  })
}
