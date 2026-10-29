///|
pub let usage : String = "Usage: orca-env-devsy <status|stop [--force]|resume> --provider <name> [--jobs <n>]\n       orca-env-devsy recipe <create|resume|suspend|destroy|recover|restart>\n       orca-env-devsy <recover|restart>\n       orca-env-devsy update [--provider <name> [--workspace <id>]] [--force]\n"

///|
priv struct BulkOptions {
  provider : String
  jobs : Int32
  force : Bool
}

///|
fn bulk_options(mode : String, args : Array[String]) -> BulkOptions raise {
  let mut provider = None
  let mut jobs = 4
  let mut force = false
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--provider" if i + 1 < args.length() && provider is None => {
        i += 1
        provider = Some(args[i])
      }
      "--jobs" if i + 1 < args.length() => {
        i += 1
        jobs = @string.parse_int(args[i])
      }
      "--force" if mode == "stop" && !force => force = true
      _ => raise AdapterError("Invalid bulk option: " + args[i])
    }
    i += 1
  }
  guard provider is Some(provider) &&
    valid_context(provider) &&
    jobs > 0 &&
    jobs <= 64 else {
    raise AdapterError(
      "--provider is required; --jobs must be between 1 and 64",
    )
  }
  { provider, jobs, force, }
}

///|
async fn observe_activity(state : Json) -> Json {
  let directory = required(state, "tunnelDirectory")
  let pairing = if @fs.exists(directory + "/pairing-code") {
    @fs.read_file(directory + "/pairing-code").text()
  } else {
    ""
  }
  let script = activity_command(state)
  let (input, writer) = @process.write_to_process()
  defer writer.close()
  let (output, reader) = @process.read_from_process()
  defer output.close()
  let (errors, stderr) = @process.read_from_process()
  defer errors.close()
  let progress = Progress::new(
    "activity-probe",
    environment=workspace_environment(state),
  )
  let mut phase = "master"
  let mut exit_code = None
  let mut failure_codes : Array[Json] = []
  errdefer save_diagnostic(
    "activity-probe",
    "failed",
    error_type="observation_failed",
    phase~,
    exit_code?,
    evidence={ "errors": Json::array(failure_codes) },
    error_message=progress.failure_detail(),
    details_truncated=progress.details_truncated,
    tunnel_directory=directory,
    recording=workspace_recording(state),
  )
  @async.with_timeout(30000, async fn() {
    let args = mux_ssh_args(state)
    phase = "spawn"
    @async.with_task_group(async fn(group) {
      let child = @process.spawn(
        group,
        workspace_program(state, "ssh"),
        extra_env=workspace_environment(state),
        inherit_env=false,
        cwd?=workspace_directory(state).map(path => path[:]),
        args + [script],
        stdin=input,
        stdout=reader,
        stderr~,
      )
      let collected_errors = group.spawn(async fn() {
        ignore(progress.read_output(errors, capture=false))
      })
      let reading = group.spawn(async fn() {
        let buffer = @buffer.Buffer()
        let bytes = FixedArray::make(4096, b'\x00')
        while true {
          let count = output.read(bytes)
          if count == 0 {
            break
          }
          guard buffer.length() + count <= 4194304 else {
            raise AdapterError("Activity response too large")
          }
          buffer.write_bytes(Bytes::from_array(bytes[:count].to_owned()))
        }
        @utf8.decode(buffer.to_bytes())
      })
      let payload : Json = { "pairingCode": pairing }
      writer.write(payload.stringify())
      writer.close()
      phase = "result"
      let code = child.wait()
      exit_code = Some(code)
      collected_errors.wait()
      phase = "schema"
      let raw = reading.wait()
      let parsed = Some(@json.parse(raw)) catch { _ => None }
      if parsed is Some(value) &&
        field(value, "errors") is Some(Json::Array(errors)) {
        failure_codes = errors.filter_map(error => {
          match field(error, "code") {
            Some(Json::String(code)) if code.length() > 0 &&
              code.length() <= 80 &&
              code.iter().all(c => (c >= 'a' && c <= 'z') || c == '_') =>
              Some(Json::string(code))
            _ => None
          }
        })
      }
      guard code == 0 else {
        raise AdapterError(
          "Remote activity probe failed (exit \{code}; errors " +
          Json::array(failure_codes).stringify() +
          ")",
        )
      }
      guard parsed is Some(value) else {
        raise AdapterError("Invalid activity JSON")
      }
      guard field(value, "schemaVersion") == Some(Json::number(1)) &&
        ["idle", "active", "unknown"].contains(required(value, "activity")) else {
        raise AdapterError("Invalid activity response")
      }
      value
    })
  })
}

///|
fn activity_command(state : Json) -> String {
  (if field(state, "orcaVolume") is Some(_) {
    "ORCA_USER_DATA_PATH=/worktrees/.orca "
  } else {
    ""
  }) +
  "ELECTRON_RUN_AS_NODE=1 \"$HOME/.local/share/orca-env-devsy/orca/current/orca-ide\" -e " +
  quote(activity_probe_source())
}

///|
fn unknown_activity(reason : String) -> Json {
  { "activity": "unknown", "reason": redact_credentials(reason) }
}

///|
async fn bulk_context(state : Json) -> String {
  let selection = @json.parse(state.stringify())
  if selection is Json::Object(fields) {
    fields.remove("context")
  }
  let contexts = @json.parse(
    devsy(
      selection,
      ["--result-format", "json", "context", "list"],
      "bulk-context",
    ),
  )
  guard contexts is Json::Array(items) else {
    raise AdapterError("Invalid context list")
  }
  let selected = items.filter(item => {
    field(item, "default") == Some(Json::boolean(true))
  })
  guard selected.length() == 1 else {
    raise AdapterError("No unique effective Devsy context")
  }
  required(selected[0], "name")
}

///|
async fn bulk_identity(state : Json, provider : String) -> (Bool, Bool) {
  let current = workspace(state)
  match current {
    None => (true, false)
    Some(value) => {
      let actual_provider = field(value, "provider").bind(p => field(p, "name"))
      let in_scope = actual_provider == Some(Json::string(provider)) &&
        field(value, "context")
        .map(c => c == field(state, "context").unwrap())
        .unwrap_or(true)
      if !in_scope {
        save_diagnostic("bulk-workspace", "excluded", evidence={
          "id": required(state, "workspaceId"),
          "context": required(state, "context"),
          "observedContext": field(value, "context").unwrap_or(Json::null()),
          "requestedProvider": provider,
          "observedProvider": actual_provider.unwrap_or(Json::null()),
          "reason": "outside_scope",
        })
      }
      (
        in_scope,
        in_scope && field(value, "uid") == field(state, "workspaceUid"),
      )
    }
  }
}

///|
async fn bulk_one(mode : String, state : Json, options : BulkOptions) -> Json? {
  let id = required(state, "workspaceId")
  let result : Json = {
    "id": id,
    "uid": required(state, "workspaceUid"),
    "context": required(state, "context"),
    "provider": options.provider,
    "identityVerified": false,
    "vmStatus": "unknown",
    "activity": "unknown",
    "outcome": "skipped",
  }
  let mut mutating = false
  try {
    set_field(result, "autoStop", idle_status(state))
    let effective_context = bulk_context(state)
    guard required(state, "context") == effective_context else {
      save_diagnostic("bulk-workspace", "excluded", evidence={
        "id": id,
        "savedContext": required(state, "context"),
        "effectiveContext": effective_context,
        "reason": "context_mismatch",
      })
      return None
    }
    let lock = connection_operation_lock(state)
    defer lock.close()
    let (in_scope, matched) = bulk_identity(state, options.provider)
    guard in_scope else { return None }
    set_field(result, "identityVerified", Json::boolean(matched))
    guard matched else {
      set_field(
        result,
        "evidence",
        unknown_activity("workspace_missing_or_replaced"),
      )
      return Some(result)
    }
    let status = workspace_status(state)
    set_field(result, "vmStatus", Json::string(status))
    let evidence = if status != "Running" {
      unknown_activity("workspace_not_running")
    } else if options.force || mode == "resume" {
      unknown_activity(
        if options.force {
          "forced_without_activity_check"
        } else {
          "resume_does_not_require_activity"
        },
      )
    } else {
      observe_activity(state) catch {
        error => unknown_activity(error.to_string())
      }
    }
    set_field(result, "activity", field(evidence, "activity").unwrap())
    set_field(result, "evidence", evidence)
    save_diagnostic(
      "bulk-observation",
      mode,
      tunnel_directory=required(state, "tunnelDirectory"),
      evidence=result,
    )
    if mode == "status" {
      set_field(result, "outcome", Json::string("observed"))
      return Some(result)
    }
    if mode == "stop" {
      if status == "Stopped" {
        set_field(result, "reason", Json::string("already_stopped"))
      } else if !options.force &&
        (
          status != "Running" ||
          field(evidence, "activity") != Some(Json::string("idle"))
        ) {
        set_field(result, "reason", Json::string("not_idle"))
      } else {
        let (scope, valid) = bulk_identity(state, options.provider)
        guard scope && valid else {
          raise AdapterError("Workspace changed before stop")
        }
        mutating = true
        pause_tunnel(state)
        defer unpause_tunnel(state)
        stop_workspace(state)
        set_field(result, "outcome", Json::string("success"))
      }
    } else if status == "Running" {
      set_field(result, "reason", Json::string("already_running"))
    } else if status != "Stopped" {
      set_field(result, "reason", Json::string("workspace_not_stopped"))
    } else {
      let (scope, valid) = bulk_identity(state, options.provider)
      guard scope && valid else {
        raise AdapterError("Workspace changed before resume")
      }
      mutating = true
      unpause_tunnel(state)
      ignore(
        devsy(
          state,
          [
            "--result-format", "json", "workspace", "up", "--id", id, "--ide-launch",
            "skip",
          ] +
          orca_storage_args(state),
          "workspace-resume",
        ),
      )
      set_field(result, "outcome", Json::string("success"))
      idle_reset(state, "workspace_resumed")
    }
  } catch {
    error => {
      set_field(
        result,
        "outcome",
        Json::string(if mutating { "failed" } else { "skipped" }),
      )
      set_field(result, "evidence", unknown_activity(error.to_string()))
      set_field(
        result,
        "error",
        Json::string(redact_credentials(error.to_string())),
      )
    }
  }
  if mode == "resume" &&
    field(result, "outcome") == Some(Json::string("success")) {
    recover_connection(state) catch {
      error => {
        set_field(result, "outcome", Json::string("failed"))
        set_field(
          result,
          "error",
          Json::string(redact_credentials(error.to_string())),
        )
      }
    }
  }
  save_diagnostic("bulk-workspace", mode, evidence=result)
  Some(result)
}

///|
pub async fn bulk(mode : String, args : Array[String]) -> Unit {
  let options = bulk_options(mode, args)
  save_diagnostic("bulk", "started", evidence={
    "action": mode,
    "provider": options.provider,
    "jobs": options.jobs,
    "force": options.force,
  })
  let base = adapter_state_home() + "/tunnels"
  let states : Array[Json] = []
  let discovery_errors : Array[Json] = []
  if @fs.exists(base) {
    for name in @fs.readdir(base, sort=true) {
      let directory = base + "/" + name
      try {
        if @fs.kind(directory, follow_symlink=false) != @fs.FileKind::Directory ||
          !@fs.exists(directory + "/enabled") {
          continue
        }
        let state = @json.parse(@fs.read_file(directory + "/state.json").text())
        validate_state(state)
        guard field(state, "devsyEnv") is Some(Json::Object(_)) else {
          raise AdapterError("Missing saved Devsy environment")
        }
        ignore(required(state, "workspaceUid"))
        ignore(required(state, "context"))
        set_field(state, "tunnelDirectory", Json::string(directory))
        set_field(state, "provider", Json::string(options.provider))
        states.push(state)
      } catch {
        error =>
          discovery_errors.push({
            "savedState": directory,
            "reason": redact_credentials(error.to_string()),
          })
      }
    }
  }
  let keys : Map[String, Int32] = Map([])
  for state in states {
    let key = required(state, "context") + ":" + required(state, "workspaceUid")
    keys.set(key, keys.get(key).unwrap_or(0) + 1)
  }
  let results : Array[Json] = []
  let permits = @async.Semaphore(options.jobs)
  @async.with_task_group(async fn(group) {
    for state in states {
      let key = required(state, "context") +
        ":" +
        required(state, "workspaceUid")
      if keys.get(key) != Some(1) {
        discovery_errors.push({
          "savedState": required(state, "tunnelDirectory"),
          "reason": "duplicate_saved_identity",
        })
        continue
      }
      permits.acquire()
      group.spawn_bg(async fn() {
        defer permits.release()
        if bulk_one(mode, state, options) is Some(result) {
          results.push(result)
        }
      })
    }
  })
  results.sort_by((a, b) => {
    let a_id = match field(a, "id") {
      Some(Json::String(id)) => id
      _ => ""
    }
    let b_id = match field(b, "id") {
      Some(Json::String(id)) => id
      _ => ""
    }
    a_id.compare(b_id)
  })
  let failures = results
    .filter(r => field(r, "outcome") == Some(Json::string("failed")))
    .length()
  let output : Json = {
    "schemaVersion": 1,
    "action": mode,
    "provider": options.provider,
    "workspaces": results,
    "failed": failures,
    "discoveryErrors": discovery_errors,
  }
  @stdio.stdout.write(output.stringify(indent=2) + "\n")
  save_diagnostic(
    "bulk",
    if failures == 0 {
      "success"
    } else {
      "failed"
    },
    evidence=output,
  )
  guard failures == 0 else {
    raise AdapterError("Some workspace operations failed")
  }
}
