///|
suberror AdapterError {
  AdapterError(String)
} derive(@debug.Debug)

///|
fn required(value : Json, name : String) -> String raise {
  match field(value, name) {
    Some(Json::String(text)) if text != "" => text
    _ => raise AdapterError("Missing or invalid \{name}")
  }
}

///|
fn environment(name : String) -> String raise {
  match @env.get_env_var(name) {
    Some(value) if value != "" => value
    _ => raise AdapterError("Missing \{name}")
  }
}

///|
fn quote(text : String) -> String {
  let escaped_quote =
    #|'"'"'
  "'" + text.replace_all(old="'", new=escaped_quote) + "'"
}

///|
async fn command_result(
  program : String,
  args : Array[String],
  stage : String,
  environment? : Map[String, String],
) -> (Int32, String, String) {
  save_diagnostic(stage, "started")
  let started = @env.now()
  let progress = Progress::new(stage)
  progress_message(stage + ": running…")
  let mut failure_kind = "process_api"
  let mut failure_errno = None
  let mut failure_phase = None
  let (status, output, errors) = {
    errdefer {
      save_diagnostic(
        stage,
        if @async.is_being_cancelled() {
          "cancelled"
        } else {
          "process-error"
        },
        error_type=failure_kind,
        os_errno?=failure_errno,
        phase?=failure_phase,
        error_message=progress.failure_detail(),
        details_truncated=progress.details_truncated,
      )
      progress_message(stage + ": failed (" + progress_timing(started) + ")")
    }
    try {
      let (out, stdout) = @process.read_from_process()
      defer out.close()
      let (err, stderr) = @process.read_from_process()
      defer err.close()
      @async.with_task_group(async fn(group) {
        let child = @process.spawn(
          group,
          program,
          args,
          extra_env?=environment,
          inherit_env=environment is None,
          stdout~,
          stderr~,
        )
        let output = group.spawn(async fn() {
          progress.read_output(
            out,
            capture=true,
            statuses=devsy_progress_stage(stage),
            messages=stage == "orca-install" || stage == "checkout-workspace",
          )
        })
        let errors = group.spawn(async fn() {
          progress.read_output(
            err,
            capture=false,
            messages=devsy_progress_stage(stage) ||
              stage == "orca-install" ||
              stage == "checkout-workspace",
          )
        })
        (child.wait(), output.wait(), errors.wait())
      })
    } catch {
      @os_error.OSError(code, ..) as error => {
        failure_kind = "process_os"
        failure_errno = Some(code)
        let message = progress
          .safe_message(program + ": " + error.to_string())
          .unwrap_or("subprocess OS error \{code}")
        progress.remember(message, warning=true)
        raise AdapterError(
          "\{stage} failed (OS error \{code}); diagnostic run \{recording_run_id}:\n" +
          message,
        )
      }
      @utf8.Malformed(_) => {
        failure_kind = "process_utf8"
        failure_phase = Some("read")
        progress.remember("subprocess output is not valid UTF-8", warning=true)
        raise AdapterError(
          "\{stage} failed: subprocess output is not valid UTF-8; diagnostic run \{recording_run_id}",
        )
      }
      error => raise error
    }
  }
  progress_message(
    stage +
    ": " +
    (if status == 0 { "done" } else { "failed (exit \{status})" }) +
    " (" +
    progress_timing(started) +
    ")",
  )
  save_diagnostic(
    stage,
    if status == 0 {
      "success"
    } else {
      "exit-error"
    },
    exit_code=status,
    duration_ms=(@env.now() - started).to_double(),
    error_message?=if status == 0 {
      None
    } else {
      Some(progress.failure_detail())
    },
    details_truncated=progress.details_truncated,
    error_type?=if status == 0 ||
      @env.get_env_var("ORCA_ENV_DEVSY_RECORDING") == Some("0") {
      None
    } else {
      Some(process_error_type(output + "\n" + errors))
    },
  )
  (status, output, progress.failure_detail())
}

///|
fn command_failure(stage : String, status : Int32, detail : String) -> String {
  "\{stage} failed (exit \{status}); diagnostic run \{recording_run_id}:\n" +
  detail
}

///|
async fn command(
  program : String,
  args : Array[String],
  stage : String,
  environment? : Map[String, String],
) -> String {
  let (status, output, detail) = command_result(
    program,
    args,
    stage,
    environment?,
  )
  guard status == 0 else {
    raise AdapterError(command_failure(stage, status, detail))
  }
  output
}

///|
fn devsy_args(state : Json) -> Array[String] {
  let args = []
  for name in ["home", "context", "provider"] {
    if field(state, name) is Some(Json::String(value)) {
      args.push("--" + name)
      args.push(value)
    }
  }
  args
}

///|
async fn devsy_result(
  state : Json,
  args : Array[String],
  stage : String,
) -> (Int32, String, String) {
  let environment = @env.get_env_vars()
  for name in location_variables {
    match field(field(state, "devsyEnv").unwrap(), name) {
      Some(Json::String(value)) => environment.set(name, value)
      _ => environment.remove(name)
    }
  }
  let invocation = saved_command(state)
  let logging = if devsy_progress_stage(stage) {
    ["--log-level", "debug", "--log-output", "json"]
  } else {
    []
  }
  let result = command_result(
    invocation[0],
    invocation[1:].to_owned() + devsy_args(state) + logging + args,
    stage,
    environment~,
  )
  result
}

///|
async fn devsy(state : Json, args : Array[String], stage : String) -> String {
  let (status, output, detail) = devsy_result(state, args, stage)
  guard status == 0 else {
    raise AdapterError(command_failure(stage, status, detail))
  }
  output
}

///|
fn saved_command(state : Json) -> Array[String] raise ConfigError {
  command_field(state, "recipeResult.userData").unwrap_or(["devsy"])
}

///|
fn proxy(
  state : Json,
  executable : String,
  services~ : Bool = true,
  lease~ : String = "",
) -> String raise {
  let args = ["env"]
  for name in location_variables {
    args.push("-u")
    args.push(name)
  }
  for name in location_variables {
    if field(field(state, "devsyEnv").unwrap(), name)
      is Some(Json::String(value)) {
      args.push(name + "=" + value)
    }
  }
  (args +
  [executable, "--ssh-proxy", lease] +
  saved_command(state) +
  devsy_args(state) +
  [
    "workspace",
    "ssh",
    required(state, "workspaceId"),
    "--stdio",
    "--user",
    required(state, "user"),
  ] +
  (if services { [] } else { ["--start-services=false"] }))
  .map(quote)
  .join(" ")
  .replace_all(old="%", new="%%")
}

///|
async fn ssh_args(
  state : Json,
  services~ : Bool = true,
  lease~ : String = "",
) -> Array[String] {
  [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=15",
    "-o",
    "ProxyCommand=" + proxy(state, adapter_executable(), services~, lease~),
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "LogLevel=ERROR",
    required(state, "user") + "@" + required(state, "workspaceId") + ".devsy",
  ]
}

///|
async fn remote(state : Json, script : String, stage : String) -> String {
  if field(state, "tunnelDirectory") is Some(Json::String(directory)) &&
    @fs.exists(directory + "/state.json") {
    let saved = @json.parse(@fs.read_file(directory + "/state.json").text())
    let reusable = try {
      check_tunnel(saved, directory)
      true
    } catch {
      _ => false
    }
    if reusable {
      return command(
        "ssh",
        ["-o", "ProxyCommand=false", "-o", "ControlMaster=no"] +
        ssh_args(state, services=false) +
        ["-S", control_socket(saved, directory), script],
        stage,
      )
    }
  }
  command("ssh", ssh_args(state, services=false) + [script], stage)
}

///|
fn up_result(output : String) -> Json raise {
  let results = []
  for line in output.split("\n") {
    if line.trim() != "" {
      let parsed = @json.parse(line.to_owned())
      if field(parsed, "kind") == Some(Json::string("result")) {
        results.push(parsed)
      }
    }
  }
  guard results.length() == 1 &&
    field(results[0], "outcome") == Some(Json::string("success")) else {
    raise AdapterError(
      "Devsy did not return exactly one successful workspace result",
    )
  }
  results[0]
}

///|
async fn read_document(path : String) -> Json {
  let data = @fs.read_file(path)
  let docs = @yaml.Yaml::load_from_string(data.text())
  guard docs.length() == 1 else {
    raise AdapterError("orca.yaml must contain exactly one YAML document")
  }
  docs[0].to_json()
}

///|
async fn notify(stage : String) -> Unit {
  progress_message(stage + ": running…")
  save_diagnostic(stage, "started")
}

///|
async fn create_state(pinned_commit? : String) -> (Json, UInt64) {
  create_recording.attempt += 1
  create_recording.phase = "input-validation"
  save_diagnostic("create-input", "received", source=Inputs)
  let mut attempt_complete = false
  errdefer (if !attempt_complete {
    save_diagnostic(
      "create-attempt",
      "failed",
      error_type="create_stage_failed",
    )
  })
  let document = read_document(environment("ORCA_REPO_PATH") + "/orca.yaml")
  let id = environment("ORCA_RECIPE_ID")
  let config = resolve_settings(document, id, name => @env.get_env_var(name))
  let recipes = match field(document, "environmentRecipes") {
    Some(Json::Array(items)) => items
    _ => []
  }
  let recipe = recipes.filter(item => {
      field(item, "id") == Some(Json::string(id))
    })[0]
  let mode = string_field(recipe, "checkoutMode", "recipe").unwrap_or(
    "orca-worktree",
  )
  save_diagnostic(
    "create-configuration",
    "received",
    source=Configuration(
      mode,
      if config.connection == Server {
        "orca-server"
      } else {
        "ssh"
      },
      config.build_ref,
    ),
  )
  guard mode == "orca-worktree" || mode == "provisioned-root" else {
    raise AdapterError("Invalid checkoutMode")
  }
  guard !(mode == "provisioned-root" && config.connection == Server) else {
    raise AdapterError("provisioned-root requires SSH")
  }
  guard valid_workspace_id(environment("ORCA_VM_INSTANCE_ID")) else {
    raise AdapterError("Invalid workspace identity")
  }
  if config.home is Some(home) {
    guard home.has_prefix("/") else {
      raise AdapterError("devsy.home must be absolute")
    }
  }
  if config.context is Some(context) {
    guard valid_context(context) else {
      raise AdapterError("Invalid devsy.context")
    }
  }
  if mode == "provisioned-root" {
    guard valid_commit(environment("ORCA_REPO_REF_HEAD")) else {
      raise AdapterError("Invalid provisioned-root commit")
    }
    let branch = environment("ORCA_REPO_BRANCH")
    guard !branch.has_prefix("-") else {
      raise AdapterError("Invalid provisioned-root branch")
    }
    ignore(
      command(
        "git",
        ["check-ref-format", "refs/heads/" + branch],
        "validate-branch",
      ),
    )
  }
  let build_ref = match config.build_ref {
    Some(value) if value != "" => value
    None if mode == "provisioned-root" =>
      @env.get_env_var("ORCA_REPO_REF")
      .filter(value => value != "")
      .unwrap_or(environment("ORCA_REPO_REF_HEAD"))
    _ => raise AdapterError("devsy.buildRef is required for orca-worktree")
  }
  let task_build = mode == "provisioned-root" && config.build_ref is None
  save_diagnostic(
    "build-request",
    "selected",
    source=Request(build_ref, task_build),
  )
  let state : Json = {
    "adapterVersion": 1,
    "orcaInstanceId": environment("ORCA_VM_INSTANCE_ID"),
    "connection": if config.connection == Server {
      "orca-server"
    } else {
      "ssh"
    },
    "checkoutMode": mode,
    "codexAuth": config.codex_auth,
  }
  let locations = Json::empty_object()
  for name in location_variables {
    set_field(
      locations,
      name,
      match @env.get_env_var(name) {
        Some(value) => Json::string(value)
        None => Json::null()
      },
    )
  }
  set_field(state, "command", Json::array(config.command.map(Json::string)))
  set_field(state, "devsyEnv", locations)
  if config.home is Some(value) {
    set_field(state, "home", Json::string(value))
  }
  if config.context is Some(value) {
    set_field(state, "context", Json::string(value))
  }
  save_diagnostic("create-input", "success")
  create_recording.phase = "ref-resolution"
  let contexts = @json.parse(
    devsy(
      state,
      ["--result-format", "json", "context", "list"],
      "resolve-context",
    ),
  )
  guard contexts is Json::Array(context_items) else {
    raise AdapterError("Invalid Devsy context list")
  }
  let defaults = context_items.filter(item => {
    field(item, "default") == Some(Json::boolean(true))
  })
  guard defaults.length() == 1 else {
    raise AdapterError("No unique effective Devsy context")
  }
  set_field(state, "context", Json::string(required(defaults[0], "name")))
  let repository = match @env.get_env_var("ORCA_REPO_URL") {
    Some(url) if url != "" => url
    _ =>
      command(
        "git",
        ["-C", environment("ORCA_REPO_PATH"), "remote", "get-url", "origin"],
        "repository-remote",
      )
      .trim()
      .to_owned()
  }
  guard !repository.contains("?") && !repository.contains("#") else {
    raise AdapterError(
      "Repository URL must not contain credentials or query parameters",
    )
  }
  if repository.has_prefix("ssh://") {
    let authority = repository.split("/").to_array()[2]
    if authority.split_once("@") is Some((userinfo, _)) {
      guard !userinfo.contains(":") else {
        raise AdapterError("Repository URL must not contain credentials")
      }
    }
  }
  if repository.has_prefix("https://") || repository.has_prefix("http://") {
    guard !repository.split("/").to_array()[2].contains("@") else {
      raise AdapterError("Repository URL must not contain credentials")
    }
  }
  let default_output = command(
    "git",
    ["ls-remote", "--symref", "--", repository, "HEAD"],
    "resolve-default-branch",
  )
  let mut default_ref = None
  for line in default_output.split("\n") {
    if line.split_once("\t") is Some((reference, "HEAD")) &&
      reference.has_prefix("ref: refs/heads/") {
      default_ref = Some(reference[5:].to_owned())
    }
  }
  let lookup_ref = if build_ref.has_prefix("refs/remotes/origin/") {
    "refs/heads/" + build_ref[20:].to_owned()
  } else if build_ref.has_prefix("origin/") {
    "refs/heads/" + build_ref[7:].to_owned()
  } else if build_ref == "HEAD" {
    default_ref.unwrap_or("HEAD")
  } else {
    build_ref
  }
  save_diagnostic("build-lookup", "selected", source=Lookup(lookup_ref))
  let mut resolved_branch = None
  let mut hash = if valid_commit(lookup_ref) {
    lookup_ref
  } else {
    let resolved = command(
        "git",
        ["ls-remote", "--", repository, lookup_ref, lookup_ref + "^{}"],
        "resolve-build-ref",
      )
      .trim()
      .to_owned()
    let lines = resolved.split("\n").to_array()
    let peeled = lines.filter(line => line.has_suffix("^{}"))
    let selected = if peeled.length() == 1 && lines.length() <= 2 {
      peeled
    } else {
      lines
    }
    guard selected.length() == 1 &&
      selected[0].split_once("\t") is Some((commit, resolved_ref)) else {
      raise AdapterError("buildRef must resolve to one remote ref or commit")
    }
    if resolved_ref.has_prefix("refs/heads/") {
      resolved_branch = shallow_branch(resolved_ref.to_owned())
    }
    commit.to_owned()
  }
  guard valid_commit(hash) else {
    raise AdapterError("Invalid remote build commit")
  }
  if task_build && resolved_branch is None && default_ref is Some(reference) {
    let tip = command(
        "git",
        ["ls-remote", "--", repository, reference],
        "resolve-build-ref",
      )
      .trim()
      .to_owned()
    if tip.has_prefix(hash + "\t") {
      resolved_branch = shallow_branch(reference)
    }
  }
  save_diagnostic(
    "build-resolution",
    "success",
    source=Selection(
      build_ref,
      lookup_ref,
      resolved_branch,
      hash,
      if valid_commit(lookup_ref) {
        "literal-commit"
      } else {
        "remote-ref"
      },
    ),
  )
  let mut selection_reason = if task_build {
    "orca-input"
  } else {
    "configured-build-ref"
  }
  if task_build && hash != environment("ORCA_REPO_REF_HEAD") {
    selection_reason = "task-head-differs-from-ref"
    hash = environment("ORCA_REPO_REF_HEAD")
    resolved_branch = None
  }
  if pinned_commit is Some(commit) {
    selection_reason = "checkout-mismatch-retry"
    hash = commit
    resolved_branch = None
  }
  save_diagnostic(
    "build-selection",
    "success",
    source=Selection(
      build_ref, lookup_ref, resolved_branch, hash, selection_reason,
    ),
  )
  create_recording.phase = "build"
  set_field(state, "buildCommit", Json::string(hash))
  set_field(state, "buildRef", Json::string(build_ref))
  let creation_lock = workspace_creation_lock()
  let mut creation_reserved = true
  defer (if creation_reserved { creation_lock.close() })
  select_workspace_name(state, repository)
  for argument in config.up_args {
    guard ![
        "--id", "--uid", "--home", "--context", "--result-format", "--ide-launch",
        "--",
      ]
      .iter()
      .any(flag => argument == flag || argument.has_prefix(flag + "=")) else {
      raise AdapterError("upArgs cannot override adapter-owned options")
    }
  }
  let reservation = @fs.tmpdir(prefix="oe-create-")
  let uid = reservation.split("/").to_array().last().unwrap().to_owned() +
    "-" +
    @env.now().to_string()
  @fs.rmdir(reservation)
  set_field(state, "workspaceUid", Json::string(uid))
  if config.connection == Server {
    let volume = "orca-env-devsy-" + uid
    set_field(state, "orcaVolume", Json::string(volume))
    save_diagnostic("orca-volume", "selected", source=Storage(volume, ""))
  }
  errdefer discard_created_workspace(state)
  let create_args = fn(source : String, strategy : String) raise {
    [
      "--result-format",
      "json",
      "--uid",
      required(state, "workspaceUid"),
      "workspace",
      "up",
      source,
      "--id",
      required(state, "workspaceId"),
      "--ide-launch",
      "skip",
      "--git-clone-strategy=" + strategy,
    ] +
    config.up_args +
    orca_storage_args(state)
  }
  let pinned_args = create_args(repository + "@sha256:" + hash, "")
  let native_source = match resolved_branch {
    Some(branch) => {
      ignore(
        command(
          "git",
          ["check-ref-format", "refs/heads/" + branch],
          "validate-build-branch",
        ),
      )
      repository + "@" + branch
    }
    None => repository + "@sha256:" + hash
  }
  let automatic_shallow = resolved_branch is Some(branch) &&
    (task_build || default_ref == Some("refs/heads/" + branch))
  let overridden = config.up_args
    .iter()
    .any(arg => {
      arg == "--git-clone-strategy" || arg.has_prefix("--git-clone-strategy=")
    })
  let strategy = if automatic_shallow && !overridden { "shallow" } else { "" }
  let initial_args = create_args(native_source, strategy)
  save_diagnostic(
    if overridden {
      "clone-override"
    } else if strategy == "shallow" {
      "clone-shallow"
    } else {
      "clone-full"
    },
    "started",
    source=Clone(resolved_branch, hash, initial_args, None),
  )
  let (status, initial_output, detail) = devsy_result(
    state, initial_args, "workspace-create",
  )
  let mut pinned_build = resolved_branch is None
  let output = if status != 0 &&
    strategy == "shallow" &&
    missing_shallow_commit(initial_output, hash) {
    save_diagnostic(
      "clone-fallback",
      "started",
      source=Clone(None, hash, pinned_args, Some("missing-shallow-commit")),
    )
    pinned_build = true
    devsy(state, pinned_args, "workspace-create-full")
  } else {
    guard status == 0 else {
      raise AdapterError(command_failure("workspace-create", status, detail))
    }
    initial_output
  }
  let deadline = connection_deadline()
  let retry = connection_timeout(deadline, async fn() {
    let created = workspace(state).unwrap()
    guard required(created, "uid") == uid else {
      raise AdapterError("Created workspace identity does not match request")
    }
    remember_volume_cleanup(state, created)
    creation_lock.close()
    creation_reserved = false
    let result = up_result(output)
    set_field(state, "user", Json::string(required(result, "remoteUser")))
    validate_state(state)
    let root = required(result, "remoteWorkspaceFolder")
    guard root.has_prefix("/") && !root.contains("\n") && !root.contains("\r") else {
      raise AdapterError("Invalid remote workspace folder")
    }
    set_field(state, "projectRoot", Json::string(root))
    // Transient probes must not own the shared credential relay. Establish the
    // persistent owner before checkout commands can need private Git access.
    let port = if required(state, "connection") == "orca-server" {
      Some(reserve_server_port(state))
    } else {
      None
    }
    ensure_ssh_worker(state, port, deadline~)
    ignore(remote(state, git_object_storage_script(root), "git-object-storage"))
    create_recording.phase = "checkout-verification"
    let actual_commit = remote(
        state,
        "git -C " + quote(root) + " rev-parse HEAD",
        "verify-build-commit",
      )
      .trim()
      .to_owned()
    save_diagnostic(
      "build-checkout-head",
      "observed",
      source=AcquiredCommit(actual_commit),
    )
    if !pinned_build && resolved_branch is Some(branch) {
      hash = remote(
          state,
          "git -C " +
          quote(root) +
          " rev-parse " +
          quote("refs/remotes/origin/" + branch + "^{commit}"),
          "verify-build-source",
        )
        .trim()
        .to_owned()
    }
    let build_matches = valid_commit(hash) && actual_commit == hash
    save_diagnostic(
      "build-checkout",
      if build_matches {
        "success"
      } else {
        "mismatch"
      },
      source=Checkout(actual_commit, hash, build_matches),
    )
    if task_build &&
      actual_commit != environment("ORCA_REPO_REF_HEAD") &&
      pinned_commit is None {
      save_diagnostic(
        "clone-fallback",
        "started",
        source=TaskHeadRetry(environment("ORCA_REPO_REF_HEAD")),
      )
      return true
    }
    guard build_matches else {
      raise AdapterError(
        "Remote build checkout does not match resolved build commit",
      )
    }
    set_field(state, "buildCommit", Json::string(actual_commit))
    if mode == "provisioned-root" {
      create_recording.phase = "task-checkout"
      let head = environment("ORCA_REPO_REF_HEAD")
      let branch = environment("ORCA_REPO_BRANCH")
      guard valid_commit(head) && !branch.has_prefix("-") else {
        raise AdapterError("Invalid provisioned-root checkout identity")
      }
      let present = remote(
        state,
        "cd " +
        quote(root) +
        " && if git cat-file -e " +
        quote(head + "^{commit}") +
        " 2>/dev/null; then printf present; else printf missing; fi",
        "task-commit-presence",
      )
      match present {
        "present" => ()
        "missing" => wait_git_relay(required(state, "tunnelDirectory"))
        _ => raise AdapterError("Invalid task commit presence result")
      }
      ignore(
        remote(state, checkout_script(root, head, branch), "checkout-workspace"),
      )
    }
    false
  })
  if retry {
    discard_created_workspace(state)
    save_diagnostic("create-attempt", "retry")
    attempt_complete = true
    create_state(pinned_commit=environment("ORCA_REPO_REF_HEAD"))
  } else {
    attempt_complete = true
    save_diagnostic("create-attempt", "success")
    (state, deadline)
  }
}

///|
fn git_object_storage_script(root : String) -> String {
  // FUSE filesystems can transiently hide objects created via link/unlink. Git's rename
  // mode avoids that sequence; retain an explicit user configuration.
  "cd " +
  quote(root) +
  " && " +
  (
    #|filesystem=$(stat -f -c %T .) || exit
    #|case "$filesystem" in virtiofs|fuseblk) ;; *) exit 0 ;; esac
    #|for attempt in 1 2 3 4 5; do
    #|  git config --global --includes --get core.createObject >/dev/null && exit 0
    #|  status=$?
    #|  test "$status" -eq 1 || exit "$status"
    #|  git config --global core.createObject rename && exit 0
    #|  status=$?
    #|  test "$status" -eq 255 || exit "$status"
    #|  test "$attempt" -lt 5 || exit "$status"
    #|  sleep 1
    #|done
  )
}

///|
fn checkout_script(root : String, head : String, branch : String) -> String {
  "cd " +
  quote(root) +
  " && (git cat-file -e " +
  quote(head + "^{commit}") +
  " 2>/dev/null || git fetch origin " +
  quote(head) +
  ") && git checkout -B " +
  quote(branch) +
  " " +
  quote(head)
}

///|
async fn lifecycle_state(mode : String) -> (Json, Json) {
  let input = @stdio.stdin.read_all()
  let payload = @json.parse(input.text())
  guard field(payload, "schemaVersion") == Some(Json::number(1)) else {
    raise AdapterError("Invalid lifecycle payload schema")
  }
  let result = match field(payload, "recipeResult") {
    Some(value) => value
    None => raise AdapterError("Missing recipeResult")
  }
  let state = match field(result, "userData") {
    Some(value) => value
    None => raise AdapterError("Missing saved adapter state")
  }
  guard field(state, "adapterVersion") == Some(Json::number(1)) else {
    raise AdapterError("Unsupported adapter state")
  }
  validate_state(state)
  match workspace(state) {
    Some(current) if field(current, "uid") == field(state, "workspaceUid") => ()
    None if mode == "destroy" => ()
    _ => raise AdapterError("Workspace missing or replaced")
  }
  (state, result)
}

///|
async fn emit_connection(
  state : Json,
  install : Bool,
  existing? : Json,
  deadline? : UInt64,
) -> Unit {
  let connection = if required(state, "connection") == "ssh" {
    ensure_ssh_worker(state, None, deadline?)
    let target : Json = {
      "label": "Devsy",
      "host": required(state, "workspaceId") + ".devsy",
      "port": 22,
      "username": required(state, "user"),
      "proxyCommand": proxy(state, saved_proxy_executable(), services=false),
    }
    let output : Json = {
      "type": "ssh",
      "projectRoot": required(state, "projectRoot"),
      "target": target,
    }
    output
  } else if existing is Some(result) {
    let port = match field(state, "localPort") {
      Some(Json::Number(port, ..)) => port.to_int()
      _ => raise AdapterError("Missing saved tunnel port")
    }
    ensure_ssh_worker(state, Some(port), deadline?)
    match field(result, "connection") {
      Some(value) => value
      None => raise AdapterError("Missing saved connection")
    }
  } else {
    server_connection(state, install, deadline?)
  }
  write_connection(state, connection)
}

///|
async fn write_connection(state : Json, connection : Json) -> Unit {
  let version = if required(state, "checkoutMode") == "provisioned-root" {
    2
  } else {
    1
  }
  let output : Json = {
    "schemaVersion": version,
    "connection": connection,
    "userData": state,
  }
  if version == 2 {
    set_field(output, "checkoutMode", Json::string("provisioned-root"))
  }
  @stdio.stdout.write(output.stringify() + "\n")
}

///|
async fn execute_inner(mode : String) -> Unit {
  notify(mode)
  if mode == "create" ||
    mode == "resume" ||
    mode == "recover" ||
    mode == "restart" {
    save_diagnostic(
      "connection-budget",
      "selected",
      timeout_ms=connection_timeout_ms(),
    )
  }
  let started = @env.now()
  let (state, previous, deadline) = if mode == "create" {
    let (state, expires) = create_state()
    (state, Json::null(), Some(expires))
  } else {
    let (state, previous) = if mode == "recover" || mode == "restart" {
      connection_timeout(started + connection_timeout_ms().to_uint64(), async fn() {
        lifecycle_state(mode)
      })
    } else {
      lifecycle_state(mode)
    }
    (
      state,
      previous,
      if mode == "recover" || mode == "restart" {
        Some(started + connection_timeout_ms().to_uint64())
      } else {
        None
      },
    )
  }
  let operation = if mode == "resume" || mode == "suspend" || mode == "destroy" {
    Some(connection_operation_lock(state))
  } else {
    None
  }
  defer (if operation is Some(lock) { lock.close() })
  if mode == "resume" {
    guard workspace(state) is Some(current) &&
      field(current, "uid") == field(state, "workspaceUid") else {
      raise AdapterError("Workspace missing or replaced before resume")
    }
    unpause_tunnel(state)
  }
  match mode {
    "create" => {
      create_recording.phase = "connection"
      errdefer discard_created_workspace(state)
      connection_timeout(deadline.unwrap(), async fn() {
        codex_addon(state)
        emit_connection(state, true, deadline?)
      })
    }
    "resume" => {
      ignore(
        devsy(
          state,
          [
            "--result-format",
            "json",
            "workspace",
            "up",
            required(state, "workspaceId"),
            "--ide-launch",
            "skip",
          ] +
          orca_storage_args(state),
          "workspace-resume",
        ),
      )
      let expires = connection_deadline()
      connection_timeout(expires, async fn() {
        let port = if required(state, "connection") == "orca-server" {
          Some(reserve_server_port(state))
        } else {
          None
        }
        ensure_ssh_worker(state, port, deadline=expires)
        codex_addon(state)
        if required(state, "connection") == "orca-server" {
          ignore(recover_server(state))
        }
        emit_connection(state, false, existing=previous, deadline=expires)
      })
    }
    "recover" | "restart" => {
      recover_connection(state, restart=mode == "restart", deadline?)
      let connection = field(previous, "connection").unwrap()
      write_connection(state, connection)
    }
    "suspend" => {
      pause_tunnel(state)
      defer unpause_tunnel(state)
      ignore(
        devsy(
          state,
          ["workspace", "stop", required(state, "workspaceId")],
          "workspace-stop",
        ),
      )
    }
    "destroy" => {
      pause_tunnel(state)
      errdefer unpause_tunnel(state)
      ignore(
        devsy(
          state,
          [
            "workspace",
            "delete",
            required(state, "workspaceId"),
            "--ignore-not-found",
          ],
          "workspace-delete",
        ),
      )
      cleanup_orca_volume(state)
      close_tunnel(state)
    }
    _ => raise AdapterError("Unknown command")
  }
  save_diagnostic(mode, "success")
  progress_message(mode + ": done (" + progress_timing(progress_started) + ")")
}

///|
fn set_field(value : Json, key : String, item : Json) -> Unit {
  if value is Json::Object(map) {
    map.set(key, item)
  }
}

///|
pub extend AdapterError with @debug.Debug::{to_repr}

///|
pub async fn execute(mode : String) -> Unit {
  execute_inner(mode) catch {
    InvalidConfig(message) => {
      progress_message(message + " (" + progress_timing(progress_started) + ")")
      save_diagnostic(mode, "failed")
      raise InvalidConfig(message)
    }
    AdapterError(message) => {
      progress_message(message + " (" + progress_timing(progress_started) + ")")
      save_diagnostic(mode, "failed")
      raise AdapterError(message)
    }
    _ => {
      progress_message(
        mode + ": failed (" + progress_timing(progress_started) + ")",
      )
      save_diagnostic(mode, "failed")
      raise AdapterError(
        mode +
        " failed: unexpected runtime error; diagnostic run " +
        recording_run_id,
      )
    }
  }
}

///|
fn validate_state(state : Json) -> Unit raise {
  ignore(saved_command(state))
  guard valid_workspace_id(required(state, "workspaceId")) &&
    valid_user(required(state, "user")) else {
    raise AdapterError("Invalid workspace identity")
  }
}

///|
async fn workspace(state : Json) -> Json? {
  let listing = @json.parse(
    devsy(
      state,
      ["--result-format", "json", "workspace", "list", "--skip-pro"],
      "workspace-list",
    ),
  )
  guard listing is Json::Array(items) else {
    raise AdapterError("Invalid workspace list")
  }
  let matches = items.filter(item => {
    field(item, "id") == field(state, "workspaceId")
  })
  match matches {
    [] => None
    [single] => Some(single)
    _ => raise AdapterError("Duplicate workspace ID")
  }
}

///|
fn valid_commit(value : String) -> Bool {
  (value.length() == 40 || value.length() == 64) &&
  value
  .to_array()
  .iter()
  .all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
pub async fn usage_error() -> Unit {
  @stdio.stderr.write(usage)
  raise AdapterError("Invalid command")
}

///|
let location_variables : Array[String] = [
  "HOME", "DEVSY_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
  "XDG_RUNTIME_DIR",
]

///|
async fn discard_created_workspace(state : Json) -> Unit {
  @async.protect_from_cancel(async fn() {
    try {
      @async.with_timeout(45000, async fn() {
        guard workspace(state) is Some(current) &&
          field(current, "uid") == field(state, "workspaceUid") else {
          return
        }
        if field(state, "orcaVolumeCleanup") is None {
          remember_volume_cleanup(state, current)
        }
        if field(state, "user") is Some(_) {
          @async.with_timeout(15000, async fn() { close_tunnel(state) }) catch {
            _ => {
              save_diagnostic(
                "create-cleanup-tunnel",
                "warning",
                error_type="tunnel_cleanup",
              )
              @stdio.stderr.write(
                "orca-env-devsy: warning: tunnel cleanup failed; continuing workspace deletion\n",
              )
            }
          }
        }
        ignore(
          devsy(
            state,
            [
              "workspace",
              "delete",
              required(state, "workspaceId"),
              "--ignore-not-found",
            ],
            "create-cleanup",
          ),
        )
        cleanup_orca_volume(state)
      })
      save_diagnostic("create-cleanup", "success")
    } catch {
      _ => {
        @stdio.stderr.write(
          "orca-env-devsy: warning: create cleanup failed; inspect the workspace with Devsy\n",
        )
        save_diagnostic("create-cleanup", "warning")
      }
    }
  })
}

///|
fn valid_workspace_id(id : String) -> Bool {
  id.length() > 0 &&
  id.length() <= 48 &&
  ((id[0] >= 'a' && id[0] <= 'z') || (id[0] >= '0' && id[0] <= '9')) &&
  id
  .to_array()
  .iter()
  .all(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')
}

///|
fn valid_context(value : String) -> Bool {
  value != "" &&
  value
  .to_array()
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '_' ||
    c == '-'
  })
}

///|
fn valid_user(user : String) -> Bool {
  let name = if user.has_suffix("$") {
    user[:user.length() - 1].to_owned()
  } else {
    user
  }
  name != "" &&
  user.length() <= 64 &&
  (
    (name[0] >= 'a' && name[0] <= 'z') ||
    (name[0] >= 'A' && name[0] <= 'Z') ||
    name[0] == '_'
  ) &&
  name
  .to_array()
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '_' ||
    c == '-'
  })
}

///|
fn shallow_branch(build_ref : String) -> String? {
  if build_ref == "HEAD" ||
    valid_commit(build_ref) ||
    (build_ref.has_prefix("refs/") && !build_ref.has_prefix("refs/heads/")) {
    return None
  }
  let branch = if build_ref.has_prefix("refs/heads/") {
    build_ref[11:].to_owned()
  } else {
    build_ref
  }
  match branch.split("/").to_array() {
    ["pull" | "merge-requests", number, "head"] if number != "" &&
      number.iter().all(c => c >= '0' && c <= '9') => return None
    _ => ()
  }
  if branch != "" &&
    branch
    .to_array()
    .iter()
    .all(c => {
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '/' ||
      c == '.' ||
      c == '_' ||
      c == '-'
    }) {
    Some(branch)
  } else {
    None
  }
}

///|
fn missing_shallow_commit(output : String, commit : String) -> Bool {
  output
  .split("\n")
  .iter()
  .any(line => {
    if line.trim() == "" {
      return false
    }
    let event = @json.parse(line.to_owned())
    let missing = match
      field(field(event, "error").unwrap_or(Json::null()), "message") {
      Some(Json::String(message)) =>
        message.contains("Could not parse object '" + commit + "'")
      _ => false
    }
    field(event, "kind") == Some(Json::string("status")) &&
    field(event, "phase") == Some(Json::string("cloning_repository")) &&
    field(event, "state") == Some(Json::string("failed")) &&
    missing
  }) catch {
    _ => false
  }
}
