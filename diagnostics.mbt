///|
async fn save_diagnostic(
  stage : String,
  status : String,
  exit_code? : Int32,
  error_type? : String,
  phase? : String,
  duration_ms? : Double,
  attempt? : Int32,
  retry_delay_ms? : Int32,
) -> Unit {
  if @env.get_env_var("ORCA_ENV_DEVSY_RECORDING") == Some("0") {
    return
  }
  try {
    let home = environment("HOME")
    let dir = home + "/.local/state/orca-env-devsy"
    @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true)
    @fs.chmod(dir, 0o700)
    let path = dir + "/events.jsonl"
    if @fs.exists(path) &&
      @fs.kind(path, follow_symlink=false) != @fs.FileKind::Regular {
      return
    }
    if @fs.exists(path) && @fs.file_size(path) > 262144L {
      @fs.remove(path)
    }
    let event : Json = {
      "stage": stage,
      "status": status,
      "time": @env.now().to_string(),
      "runId": recording_run_id,
      "adapterVersion": version,
    }
    if exit_code is Some(code) {
      set_field(event, "exitCode", Json::number(code.to_double()))
    }
    for pair in [("errorType", error_type), ("phase", phase)] {
      if pair.1 is Some(text) {
        set_field(event, pair.0, Json::string(text))
      }
    }
    if duration_ms is Some(value) {
      set_field(event, "durationMs", Json::number(value))
    }
    if attempt is Some(value) {
      set_field(event, "attempt", Json::number(value.to_double()))
    }
    if retry_delay_ms is Some(value) {
      set_field(event, "retryDelayMs", Json::number(value.to_double()))
    }
    @fs.write_file(
      path,
      event.stringify() + "\n",
      permission=0o600,
      append=true,
      create_mode=@fs.OpenOrCreate,
    )
  } catch {
    _ => ()
  }
}

///|
let recording_run_id : String = @env.now().to_string()

///|
fn process_error_type(output : String) -> String {
  let text = output.to_lower()
  if text.contains("address already in use") || text.contains("addrinuse") {
    "address_in_use"
  } else if text.contains("permission denied (publickey") ||
    text.contains("authentication failed") {
    "authentication_failed"
  } else if text.contains("host key verification failed") {
    "host_key_failed"
  } else if text.contains("connection refused") {
    "connection_refused"
  } else if text.contains("connection timed out") ||
    text.contains("operation timed out") {
    "connection_timeout"
  } else if text.contains("could not resolve hostname") {
    "name_resolution"
  } else if text.contains("controlsocket") || text.contains("control socket") {
    "control_socket"
  } else if text.contains("no such file or directory") ||
    text.contains("not found") {
    "missing_resource"
  } else if text.contains("permission denied") {
    "permission_denied"
  } else {
    "process_exit"
  }
}

///|
async fn record_devsy_phases(output : String, stage : String) -> Unit {
  if @env.get_env_var("ORCA_ENV_DEVSY_RECORDING") == Some("0") {
    return
  }
  let mut count = 0
  for line in output.split("\n") {
    if line.length() > 65536 {
      continue
    }
    let event = @json.parse(line.to_owned()) catch { _ => continue }
    if field(event, "kind") != Some(Json::string("status")) {
      continue
    }
    let phase = match field(event, "phase") {
      Some(Json::String(value)) => value
      _ => continue
    }
    let status = match field(event, "state") {
      Some(Json::String(value)) => value
      _ => continue
    }
    if ![
        "cloning_repository", "resolving_config", "initialize_command", "preparing_devcontainer",
        "building_image", "starting_container", "injecting_agent", "running_lifecycle_hook",
        "waiting_for", "running_command", "configuring_workspace", "configuring_ssh",
        "starting_ssh_tunnel", "launching_ide", "stopping_workspace", "deleting_workspace",
        "rebuilding_workspace", "resetting_workspace", "importing_workspace", "ready",
        "failed", "installing_provider", "resolving_options", "running_init",
      ].contains(phase) ||
      !["started", "succeeded", "failed", "skipped"].contains(status) {
      continue
    }
    if count == 128 {
      save_diagnostic(stage, "diagnostics-truncated", error_type="phase_limit")
      break
    }
    count += 1
    save_diagnostic(
      stage,
      status,
      phase~,
      error_type?=if status == "failed" { Some("backend_phase") } else { None },
    )
  }
}

///|
async fn tunnel_errors(reader : @process.ReadFromProcess) -> String {
  defer reader.close()
  let mut tail = ""
  while reader.read_some(max_len=4096) is Some(bytes) {
    // Decode chunks lossy: arbitrary process stderr need not be valid UTF-8.
    let chunk = @utf8.decode_lossy(bytes)
    tail += chunk
    if tail.length() > 8192 {
      tail = tail[tail.length() - 8192:].to_owned()
    }
  }
  process_error_type(tail)
}
