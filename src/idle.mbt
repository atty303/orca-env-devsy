///|
fn parse_idle_timeout(value : String) -> Int64 raise ConfigError {
  let (digits, scale) = if value.has_suffix("s") {
    (value[:value.length() - 1].to_owned(), 1000L)
  } else if value.has_suffix("m") {
    (value[:value.length() - 1].to_owned(), 60000L)
  } else if value.has_suffix("h") {
    (value[:value.length() - 1].to_owned(), 3600000L)
  } else if value.has_suffix("d") {
    (value[:value.length() - 1].to_owned(), 86400000L)
  } else {
    raise InvalidConfig(
      "idleTimeout must be a positive integer followed by s, m, h or d",
    )
  }
  guard digits != "" && digits.to_array().iter().all(c => c >= '0' && c <= '9') else {
    raise InvalidConfig("Invalid idleTimeout duration")
  }
  let amount = @string.parse_int64(digits) catch {
    _ => raise InvalidConfig("idleTimeout is too large")
  }
  guard amount > 0 && amount <= 9007199254740991L / scale else {
    raise InvalidConfig(
      "idleTimeout must be positive and exactly representable",
    )
  }
  amount * scale
}

///|
fn idle_timeout(state : Json) -> Int64? raise {
  match field(state, "idleTimeoutMs") {
    None => None
    Some(Json::Number(n, ..)) if n > 0 &&
      n <= 9007199254740991.0 &&
      n == n.to_int64().to_double() => Some(n.to_int64())
    _ => raise AdapterError("Invalid saved idle timeout")
  }
}

///|
priv struct IdleTimer {
  mut elapsed : Int64
  mut seen : Bool
  mut previous : Int64?
  mut epoch : Int64
}

///|
fn IdleTimer::advance(
  self : IdleTimer,
  activity : String,
  now : Int64,
) -> Unit raise {
  guard now >= 0 else { raise AdapterError("Idle clock unavailable") }
  let delta = match self.previous {
    Some(last) if now >= last => now - last
    _ => 0L
  }
  if activity == "active" {
    self.elapsed = 0
    self.seen = false
  } else if activity == "idle" || (activity == "unknown" && self.seen) {
    if self.seen {
      self.elapsed = if self.elapsed + delta > 9007199254740991L {
        9007199254740991L
      } else {
        self.elapsed + delta
      }
    }
    self.seen = true
  }
  self.previous = Some(now)
}

///|
async fn idle_state_lock(state : Json) -> @fs.File {
  let lock = @fs.open(
    required(state, "tunnelDirectory") + "/idle-state.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  errdefer lock.close()
  @async.with_timeout(2000, async fn() {
    while !lock.try_lock(Exclusive) {
      @async.sleep(10)
    }
  })
  lock
}

///|
async fn idle_record(state : Json) -> Json {
  let path = required(state, "tunnelDirectory") + "/idle.json"
  if !@fs.exists(path) {
    return {
      "uid": required(state, "workspaceUid"),
      "elapsedMs": 0,
      "seenIdle": false,
      "epoch": 0,
      "reason": "awaiting_idle",
      "activity": "unknown",
    }
  }
  let record = @json.parse(@fs.read_file(path).text())
  guard field(record, "uid") == field(state, "workspaceUid") &&
    field(record, "elapsedMs") is Some(Json::Number(elapsed, ..)) &&
    elapsed >= 0 &&
    elapsed <= 9007199254740991.0 &&
    elapsed == elapsed.to_int64().to_double() &&
    field(record, "epoch") is Some(Json::Number(epoch, ..)) &&
    epoch >= 0 &&
    epoch <= 9007199254740991.0 &&
    epoch == epoch.to_int64().to_double() &&
    (
      field(record, "seenIdle") == Some(Json::boolean(true)) ||
      field(record, "seenIdle") == Some(Json::boolean(false))
    ) else {
    raise AdapterError("Invalid saved idle timer")
  }
  record
}

///|
async fn idle_write(state : Json, record : Json) -> Unit {
  let path = required(state, "tunnelDirectory") + "/idle"
  @fs.write_file(path + ".tmp", record.stringify(), permission=0o600)
  @fs.rename(path + ".tmp", path + ".json", replace=true)
}

///|
async fn idle_reset(state : Json, reason : String) -> Unit {
  if idle_timeout(state) is None {
    return
  }
  let lock = idle_state_lock(state)
  defer lock.close()
  let old = idle_record(state)
  if field(old, "elapsedMs") == Some(Json::number(0)) &&
    field(old, "seenIdle") == Some(Json::boolean(false)) &&
    field(old, "reason") == Some(Json::string(reason)) {
    return
  }
  let epoch = match field(old, "epoch") {
    Some(Json::Number(n, ..)) => n.to_int64() + 1
    _ => 1L
  }
  let record : Json = {
    "uid": required(state, "workspaceUid"),
    "elapsedMs": 0,
    "seenIdle": false,
    "epoch": Json::number(epoch.to_double()),
    "activity": "unknown",
    "reason": reason,
    "observedAt": @env.now().to_string(),
  }
  idle_write(state, record)
  save_diagnostic(
    "idle-reset",
    reason,
    tunnel_directory=required(state, "tunnelDirectory"),
    evidence=record,
  )
}

///|
async fn idle_tick(
  state : Json,
  timer : IdleTimer,
  activity : String,
  reason : String,
  now : Int64,
  observation? : Json,
) -> Unit {
  let lock = idle_state_lock(state)
  defer lock.close()
  let old = idle_record(state)
  let epoch = match field(old, "epoch") {
    Some(Json::Number(n, ..)) => n.to_int64()
    _ => 0L
  }
  if epoch != timer.epoch {
    timer.elapsed = match field(old, "elapsedMs") {
      Some(Json::Number(n, ..)) => n.to_int64()
      _ => 0L
    }
    timer.seen = field(old, "seenIdle") == Some(Json::boolean(true))
    timer.previous = None
    timer.epoch = epoch
  }
  timer.advance(activity, now)
  let record : Json = {
    "uid": required(state, "workspaceUid"),
    "epoch": Json::number(epoch.to_double()),
    "elapsedMs": Json::number(timer.elapsed.to_double()),
    "seenIdle": timer.seen,
    "activity": activity,
    "reason": if reason != "stop_failed" &&
      activity == "unknown" &&
      timer.seen &&
      timer.elapsed >= idle_timeout(state).unwrap() {
      "awaiting_idle_confirmation"
    } else {
      reason
    },
    "observedAt": @env.now().to_string(),
  }
  idle_write(state, record)
  save_diagnostic(
    "idle-observation",
    reason,
    tunnel_directory=required(state, "tunnelDirectory"),
    evidence={
      "timeoutMs": field(state, "idleTimeoutMs").unwrap(),
      "before": old,
      "after": record,
      "observation": observation.unwrap_or(Json::null()),
    },
  )
}

///|
async fn idle_status(state : Json) -> Json {
  guard idle_timeout(state) is Some(timeout) else {
    return { "enabled": false }
  }
  let result : Json = {
    "enabled": true,
    "timeoutMs": Json::number(timeout.to_double()),
    "elapsedMs": 0,
    "reason": "initializing",
  }
  try {
    let record = idle_record(state)
    for name in ["elapsedMs", "reason", "activity", "observedAt"] {
      if field(record, name) is Some(value) {
        set_field(result, name, value)
      }
    }
  } catch {
    error => {
      set_field(result, "reason", Json::string("timer_unavailable"))
      set_field(
        result,
        "error",
        Json::string(redact_credentials(error.to_string())),
      )
    }
  }
  result
}

///|
async fn stop_workspace(state : Json) -> Unit {
  ignore(
    devsy(
      state,
      ["workspace", "stop", required(state, "workspaceId")],
      "workspace-stop",
    ),
  )
  idle_reset(state, "workspace_stopped")
}

///|
priv struct IdleSession {
  child : @process.Process
  writer : @process.WriteToProcess
  reader : @process.ReadFromProcess
  stderr : @process.ReadFromProcess
  errors : Ref[String]
  mut closed : Bool
}

///|
async fn IdleSession::read(self : IdleSession) -> Json {
  let buffer = @buffer.Buffer()
  let bytes = FixedArray::make(4096, b'\x00')
  while true {
    let count = self.reader.read(bytes)
    guard count > 0 else {
      raise AdapterError("Idle observer disconnected: " + self.errors.val)
    }
    guard buffer.length() + count <= 4194304 else {
      raise AdapterError("Idle observer response too large")
    }
    buffer.write_bytes(Bytes::from_array(bytes[:count].to_owned()))
    if bytes[count - 1] == b'\n' {
      break
    }
  }
  @json.parse(@utf8.decode(buffer.to_bytes()))
}

///|
async fn IdleSession::observe(self : IdleSession) -> Json {
  @async.with_timeout(30000, async fn() {
    self.writer.write("observe\n")
    let value = self.read()
    guard field(value, "schemaVersion") == Some(Json::number(1)) &&
      ["idle", "active", "unknown"].contains(required(value, "activity")) else {
      raise AdapterError("Invalid idle observer result")
    }
    value
  })
}

///|
async fn IdleSession::close(self : IdleSession) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.writer.close()
  self.reader.close()
  self.stderr.close()
  self.child.cancel()
  @async.with_timeout(2000, async fn() { ignore(self.child.wait()) }) catch {
    _ => ()
  }
}

///|
async fn[X] open_idle_session(
  group : @async.TaskGroup[X],
  state : Json,
) -> IdleSession {
  let directory = required(state, "tunnelDirectory")
  guard @fs.exists(directory + "/pairing-code") else {
    raise AdapterError("Native access unavailable for idle observer")
  }
  let pairing = @fs.read_file(directory + "/pairing-code").text()
  let (input, writer) = @process.write_to_process()
  errdefer writer.close()
  let (reader, output) = @process.read_from_process()
  errdefer reader.close()
  let (stderr, sink) = @process.read_from_process()
  errdefer stderr.close()
  let errors : Ref[String] = { val: "", }
  group.spawn_bg(no_wait=true, async fn() {
    let buffer = @buffer.Buffer()
    let chunk = FixedArray::make(2048, b'\x00')
    let mut truncated = false
    try {
      while true {
        let count = stderr.read(chunk)
        if count == 0 {
          break
        }
        let available = 8192 - buffer.length()
        let keep = if count > available { available } else { count }
        if keep > 0 {
          buffer.write_bytes(Bytes::from_array(chunk[:keep].to_owned()))
        }
        if keep < count {
          truncated = true
        }
        errors.val = redact_credentials(@utf8.decode_lossy(buffer.to_bytes())) +
          (if truncated { " [stderr truncated]" } else { "" })
      }
    } catch {
      _ => ()
    }
  })
  let script = "ORCA_ENV_DEVSY_OBSERVER=1 " + activity_command(state)
  let child = @process.spawn(
    group,
    "ssh",
    ["-o", "ProxyCommand=false", "-o", "ControlMaster=no"] +
    ssh_args(state, services=false) +
    ["-S", control_socket(state, directory), script],
    stdin=input,
    stdout=output,
    stderr=sink,
    no_wait=true,
  )
  let session = { child, writer, reader, stderr, errors, closed: false, }
  errdefer @async.protect_from_cancel(async fn() { session.close() })
  @async.with_timeout(30000, async fn() {
    writer.write(({ "pairingCode": pairing } : Json).stringify() + "\n")
    let ready = session.read()
    guard field(ready, "ready") == Some(Json::boolean(true)) else {
      let codes = match field(ready, "errors") {
        Some(Json::Array(items)) =>
          Json::array(
            items.map(item => {
              field(item, "code").unwrap_or(Json::string("unknown"))
            }),
          ).stringify()
        _ => "unknown"
      }
      raise AdapterError(
        "Idle observer initialization failed: " + redact_credentials(codes),
      )
    }
  })
  save_diagnostic("idle-connection", "connected", tunnel_directory=directory)
  session
}

///|
async fn idle_supervisor(
  state : Json,
  timer : IdleTimer,
  busy : Ref[Bool],
  done : Ref[Bool],
) -> Unit {
  let timeout = idle_timeout(state).unwrap()
  let interval = configured_timing_ms("ORCA_ENV_DEVSY_TEST_IDLE_POLL_MS", 30000)
  let mut attempt = 0
  let mut retry_reason = "observer_reconnecting"
  while @fs.exists(required(state, "tunnelDirectory") + "/enabled") &&
        @fs.exists(required(state, "tunnelDirectory") + "/idle-enabled") {
    retry_reason = "observer_reconnecting"
    let outcome = @async.with_task_group(async fn(group) {
      let session = open_idle_session(group, state)
      defer @async.protect_from_cancel(async fn() { session.close() })
      group.spawn_bg(no_wait=true, async fn() {
        while @fs.exists(required(state, "tunnelDirectory") + "/idle-enabled") {
          @async.sleep(100)
        }
        raise AdapterError("Idle monitoring disabled")
      })
      while true {
        let started = @async.now()
        let evidence = session.observe()
        let activity = required(evidence, "activity")
        attempt = 0
        idle_tick(
          state,
          timer,
          activity,
          if activity == "unknown" {
            "observation_unknown"
          } else {
            "monitoring"
          },
          @async.now(),
          observation=evidence,
        )
        if timer.elapsed >= timeout && activity == "idle" {
          let lock = connection_operation_lock(state)
          defer lock.close()
          guard !@fs.exists(required(state, "tunnelDirectory") + "/paused") else {
            return false
          }
          let (scope, identity) = bulk_identity(
            state,
            required(state, "idleProvider"),
          )
          guard scope && identity && workspace_status(state) == "Running" else {
            raise AdapterError("Idle stop identity or running state changed")
          }
          let fresh = session.observe()
          let current = required(fresh, "activity")
          idle_tick(
            state,
            timer,
            current,
            if current == "unknown" {
              "awaiting_idle_confirmation"
            } else {
              "monitoring"
            },
            @async.now(),
            observation=fresh,
          )
          if current == "idle" {
            busy.val = true
            defer {
              busy.val = false
            }
            save_diagnostic(
              "idle-stop",
              "started",
              tunnel_directory=required(state, "tunnelDirectory"),
              evidence=fresh,
            )
            session.close()
            let failure = try {
              stop_workspace(state)
              None
            } catch {
              error => Some(redact_credentials(error.to_string()))
            }
            if failure is Some(message) {
              retry_reason = "stop_failed"
              save_diagnostic(
                "idle-stop",
                "failed",
                error_type="workspace_stop_failed",
                error_message=message,
                tunnel_directory=required(state, "tunnelDirectory"),
              )
              raise AdapterError(message)
            }
            save_diagnostic(
              "idle-stop",
              "success",
              tunnel_directory=required(state, "tunnelDirectory"),
            )
            done.val = true
            return true
          }
        }
        let elapsed = @async.now() - started
        @async.sleep(
          if elapsed >= interval.to_int64() {
            0
          } else {
            interval - elapsed.to_int()
          },
        )
      } nobreak {
        false
      }
    }) catch {
      error => {
        save_diagnostic(
          "idle-connection",
          "failed",
          error_type="observer_unavailable",
          error_message=redact_credentials(error.to_string()),
          tunnel_directory=required(state, "tunnelDirectory"),
        )
        false
      }
    }
    if outcome ||
      !@fs.exists(required(state, "tunnelDirectory") + "/idle-enabled") {
      return
    }
    let cycles = 1 << attempt
    attempt = if attempt < 4 { attempt + 1 } else { 4 }
    save_diagnostic(
      "idle-connection",
      "retry",
      attempt~,
      retry_delay_ms=interval * cycles,
      tunnel_directory=required(state, "tunnelDirectory"),
    )
    for _ in 0..<cycles {
      idle_tick(state, timer, "unknown", retry_reason, @async.now())
      @async.sleep(interval)
    }
  }
}

///|
async fn idle_retry_wait(
  state : Json,
  timer : IdleTimer?,
  delay : Int32,
) -> Unit {
  let directory = required(state, "tunnelDirectory")
  let interval = configured_timing_ms("ORCA_ENV_DEVSY_TEST_IDLE_POLL_MS", 30000)
  let mut remaining = delay
  while remaining > 0 && @fs.exists(directory + "/enabled") {
    if @fs.exists(directory + "/paused") ||
      @fs.exists(directory + "/probe-request") {
      return
    }
    if timer is Some(timer) && @fs.exists(directory + "/idle-enabled") {
      let stopped = try
        field(
          @json.parse(@fs.read_file(directory + "/status.json").text()),
          "status",
        ) ==
        Some(Json::string("workspace-stopped"))
      catch {
        _ => false
      }
      if stopped {
        timer.previous = None
      } else {
        idle_tick(state, timer, "unknown", "tunnel_reconnecting", @async.now()) catch {
          error =>
            save_diagnostic(
              "idle-monitor",
              "failed",
              error_type="timer_unavailable",
              error_message=redact_credentials(error.to_string()),
              tunnel_directory=directory,
            )
        }
      }
    }
    let step = if remaining > interval { interval } else { remaining }
    monitor_wait(directory, step)
    remaining -= step
  }
}
