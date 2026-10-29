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
  timeout_ms? : Int32,
  os_errno? : Int32,
  source? : CreateEvidence,
  error_message? : String,
  details_truncated~ : Bool = false,
  tunnel_directory? : String,
  expected_workspace_uid? : String,
  observed_workspace_uid? : String,
  evidence? : Json,
  recording? : Bool,
) -> Unit {
  if !recording.unwrap_or(
      @env.get_env_var("ORCA_ENV_DEVSY_RECORDING") != Some("0"),
    ) {
    return
  }
  try {
    let dir = adapter_state_home()
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
    if create_recording.attempt > 0 {
      set_field(
        event,
        "createAttempt",
        Json::number(create_recording.attempt.to_double()),
      )
      set_field(event, "createPhase", Json::string(create_recording.phase))
    }
    if error_message is Some(message) {
      set_field(event, "errorMessage", Json::string(message))
      set_field(event, "detailsTruncated", Json::boolean(details_truncated))
    }
    if tunnel_directory is Some(directory) {
      set_field(event, "tunnelDirectory", Json::string(directory))
    }
    for
      pair in [
        ("expectedWorkspaceUid", expected_workspace_uid),
        ("observedWorkspaceUid", observed_workspace_uid),
      ] {
      if pair.1 is Some(value) {
        set_field(event, pair.0, Json::string(redact_credentials(value)))
      }
    }
    if source is Some(evidence) {
      set_field(event, "source", evidence.to_json())
    }
    if evidence is Some(value) {
      if value.stringify().length() <= 65536 {
        set_field(event, "evidence", value)
      } else {
        set_field(event, "evidenceTruncated", Json::boolean(true))
        set_field(event, "completeness", Json::string("partial"))
      }
    }
    if os_errno is Some(code) && code > 0 && code < 4096 {
      set_field(event, "osErrno", Json::number(code.to_double()))
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
    if timeout_ms is Some(value) {
      set_field(event, "timeoutMs", Json::number(value.to_double()))
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
fn diagnostic_error(
  error : Error,
  environment? : Map[String, String],
) -> String {
  let message = match error {
    AdapterError(detail) => detail
    InvalidConfig(detail) => detail
    _ => error.to_string()
  }
  let progress = Progress::new("diagnostic-error", environment?)
  message
  .split("\n")
  .map(line => progress.safe_message(line.to_owned()).unwrap_or("[unavailable]"))
  .join("\n")
}

///|
fn process_error_type(output : String) -> String {
  let text = output.to_lower()
  if text.contains("out of memory") || text.contains("cannot allocate memory") {
    "memory_exhausted"
  } else if text.contains("no space left on device") {
    "disk_exhausted"
  } else if text.contains("address already in use") ||
    text.contains("addrinuse") {
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
  } else if text.contains("build_vm:") {
    "vm_boot"
  } else if text.contains("create microsandbox vm") && text.contains("network:") {
    "vm_network"
  } else if text.contains("create microsandbox vm") && text.contains("mount:") {
    "vm_mount"
  } else if text.contains("ensure microsandbox final image") ||
    text.contains("prepare microsandbox final image") {
    "vm_image"
  } else if text.contains("create microsandbox vm") {
    "vm_create"
  } else if text.contains("start microsandbox vm") {
    "vm_start"
  } else if text.contains("no such file or directory") ||
    text.contains("not found") {
    "missing_resource"
  } else if text.contains("permission denied") {
    "permission_denied"
  } else if text.contains("database is locked") ||
    text.contains("database locked") {
    "database_locked"
  } else if text.contains("too many open files") {
    "file_limit"
  } else {
    "process_exit"
  }
}

///|
async fn tunnel_errors(
  reader : @process.ReadFromProcess,
  environment : Map[String, String],
) -> (String, String, Bool) {
  defer reader.close()
  let progress = Progress::new("ssh-tunnel", environment~)
  let tail = progress.read_output(reader, capture=false, raw_messages=true)
  (
    process_error_type(tail),
    progress.failure_detail(),
    progress.details_truncated,
  )
}

///|
priv struct CreateRecording {
  mut attempt : Int32
  mut phase : String
}

///|
let create_recording : CreateRecording = {
  attempt: 0,
  phase: "input-validation",
}

///|
priv enum CreateEvidence {
  Inputs
  IdentitySelection(String, String)
  Storage(String, String)
  VolumeCleanup(String, Json)
  Configuration(String, String, String?)
  Request(String, Bool)
  Lookup(String)
  Selection(String, String, String?, String, String)
  Clone(String?, String, Array[String], String?)
  TaskHeadRetry(String)
  AcquiredCommit(String)
  Checkout(String, String, Bool)
}

///|
priv enum DiagnosticValueKind {
  Identity
  Workspace
  RefName
  Commit
}

///|
fn diagnostic_value(value : String?, kind : DiagnosticValueKind) -> Json {
  match value {
    None => { "state": "unset" }
    Some("") => { "state": "empty" }
    Some(text) => {
      let valid = match kind {
        Commit => valid_commit(text)
        Workspace => valid_workspace_id(text)
        Identity => text.length() <= 128 && valid_context(text)
        RefName => diagnostic_ref(text)
      }
      let credential_form = text
        .split("/")
        .iter()
        .any(part => {
          [
            "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "sk-",
            "eyJ",
          ]
          .iter()
          .any(prefix => part.has_prefix(prefix))
        })
      if valid && !credential_form {
        { "state": "valid", "value": text }
      } else {
        { "state": "invalid" }
      }
    }
  }
}

///|
// A recording grammar, never a replacement for checkout validation. Excludes
// URLs, credential forms, control characters and Git's invalid ref syntax.
fn diagnostic_ref(text : String) -> Bool {
  text.length() <= 1024 &&
  !text.has_prefix("-") &&
  !text.contains("..") &&
  text
  .split("/")
  .iter()
  .all(part => {
    part != "" &&
    !part.has_prefix(".") &&
    !part.has_suffix(".") &&
    !part.has_suffix(".lock")
  }) &&
  text
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '/' ||
    c == '-' ||
    c == '_' ||
    c == '.'
  })
}

///|
fn CreateEvidence::to_json(self : CreateEvidence) -> Json {
  match self {
    VolumeCleanup(volume, plan) => { "volume": volume, "cleanup": plan }
    IdentitySelection(slug, id) =>
      { "repositorySlug": redact_credentials(slug), "workspaceId": id }
    Storage(volume, root) =>
      {
        "projectRoot": if root == "" {
          Json::null()
        } else {
          Json::string(redact_credentials(root))
        },
        "volume": volume,
        "mountPath": "/worktrees",
        "profilePath": "/worktrees/.orca",
        "worktreeBasePath": "/worktrees",
      }
    Inputs => {
      let inputs = Json::empty_object()
      for
        (name, kind) in [
          ("ORCA_VM_INSTANCE_ID", Workspace),
          ("ORCA_RECIPE_ID", Identity),
          ("ORCA_REPO_REF", RefName),
          ("ORCA_REPO_REF_HEAD", Commit),
          ("ORCA_REPO_BRANCH", RefName),
        ] {
        set_field(inputs, name, diagnostic_value(@env.get_env_var(name), kind))
      }
      inputs
    }
    Configuration(mode, connection, build_ref) =>
      {
        "checkoutMode": if mode == "orca-worktree" || mode == "provisioned-root" {
          Json::string(mode)
        } else {
          Json::string("invalid")
        },
        "connection": connection,
        "configuredBuildRef": diagnostic_value(build_ref, RefName),
      }
    Request(build_ref, task_build) =>
      {
        "buildRef": diagnostic_value(Some(build_ref), RefName),
        "selectionReason": if task_build {
          "orca-input"
        } else {
          "configured-build-ref"
        },
      }
    Lookup(lookup_ref) =>
      { "lookupRef": diagnostic_value(Some(lookup_ref), RefName) }
    Selection(build_ref, lookup_ref, branch, commit, reason) =>
      {
        "buildRef": diagnostic_value(Some(build_ref), RefName),
        "lookupRef": diagnostic_value(Some(lookup_ref), RefName),
        "resolvedBranch": diagnostic_value(branch, RefName),
        "resolvedCommit": diagnostic_value(Some(commit), Commit),
        "selectionReason": reason,
      }
    Clone(branch, commit, args, reason) => {
      let (strategy, origin) = diagnostic_clone_strategy(args)
      {
        "sourceKind": if branch is Some(_) {
          "branch"
        } else {
          "commit"
        },
        "branch": diagnostic_value(branch, RefName),
        "commit": diagnostic_value(Some(commit), Commit),
        "cloneStrategy": strategy,
        "strategySource": origin,
        "fallback": reason is Some(_),
        "fallbackReason": match reason {
          Some(value) => Json::string(value)
          None => Json::null()
        },
      }
    }
    TaskHeadRetry(commit) =>
      {
        "commit": diagnostic_value(Some(commit), Commit),
        "fallback": true,
        "fallbackReason": "task-head-mismatch",
      }
    AcquiredCommit(actual) =>
      {
        "scope": "build-checkout",
        "actualCommit": diagnostic_value(Some(actual), Commit),
      }
    Checkout(actual, expected, matches) =>
      {
        "scope": "build-checkout",
        "actualCommit": diagnostic_value(Some(actual), Commit),
        "expectedCommit": diagnostic_value(Some(expected), Commit),
        "matches": matches,
      }
  }
}

///|
// Inspect only the strategy flags in the actual invocation. Other arguments
// never enter the diagnostic record. Devsy uses the last valid repeated flag.
fn diagnostic_clone_strategy(args : Array[String]) -> (String, String) {
  let mut strategy = "full"
  let mut count = 0
  let mut invalid = false
  let mut index = 0
  while index < args.length() {
    let argument = args[index]
    let value = if argument == "--git-clone-strategy" {
      count += 1
      index += 1
      if index < args.length() {
        Some(args[index])
      } else {
        None
      }
    } else if argument.has_prefix("--git-clone-strategy=") {
      count += 1
      Some(argument[21:].to_owned())
    } else {
      None
    }
    if count > 0 &&
      (
        argument == "--git-clone-strategy" ||
        argument.has_prefix("--git-clone-strategy=")
      ) {
      match value {
        Some("") => strategy = "full"
        Some("shallow" | "blobless" | "treeless" | "bare" as known) =>
          strategy = known
        _ => invalid = true
      }
    }
    index += 1
  }
  (
    if invalid {
      "invalid"
    } else {
      strategy
    },
    if count > 1 {
      "upArgs"
    } else {
      "adapter"
    },
  )
}
