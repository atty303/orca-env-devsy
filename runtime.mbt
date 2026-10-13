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
async fn command(
  program : String,
  args : Array[String],
  stage : String,
  environment? : Map[String, String],
) -> String {
  save_diagnostic(stage, "started")
  let (status, output, _) = {
    errdefer save_diagnostic(stage, "process-error")
    @process.collect_output(
      program,
      args,
      extra_env?=environment,
      inherit_env=environment is None,
    )
  }
  save_diagnostic(
    stage,
    if status == 0 {
      "success"
    } else {
      "exit-error"
    },
    exit_code=status,
  )
  guard status == 0 else {
    raise AdapterError(
      "\{stage} failed (exit \{status}); command output withheld",
    )
  }
  output.text()
}

///|
fn devsy_args(state : Json) -> Array[String] {
  let args = []
  for name in ["home", "context"] {
    if field(state, name) is Some(Json::String(value)) {
      args.push("--" + name)
      args.push(value)
    }
  }
  args
}

///|
async fn devsy(state : Json, args : Array[String], stage : String) -> String {
  let environment = @env.get_env_vars()
  for name in location_variables {
    match field(field(state, "devsyEnv").unwrap(), name) {
      Some(Json::String(value)) => environment.set(name, value)
      _ => environment.remove(name)
    }
  }
  let invocation = saved_command(state)
  command(
    invocation[0],
    invocation[1:].to_owned() + devsy_args(state) + args,
    stage,
    environment~,
  )
}

///|
fn saved_command(state : Json) -> Array[String] raise ConfigError {
  command_field(state, "recipeResult.userData").unwrap_or(["devsy"])
}

///|
fn proxy(state : Json) -> String raise {
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
  // A constant shell trampoline preserves executable names that env would
  // otherwise interpret as options or assignments. Configuration stays argv.
  (args +
  ["/bin/sh", "-c", "exec -- \"$@\"", "sh"] +
  saved_command(state) +
  devsy_args(state) +
  [
    "workspace",
    "ssh",
    required(state, "workspaceId"),
    "--stdio",
    "--user",
    required(state, "user"),
  ])
  .map(quote)
  .join(" ")
  .replace_all(old="%", new="%%")
}

///|
fn ssh_args(state : Json) -> Array[String] raise {
  [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=15",
    "-o",
    "ProxyCommand=" + proxy(state),
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "LogLevel=ERROR",
    required(state, "user") + "@devsy-workspace",
  ]
}

///|
async fn remote(state : Json, script : String, stage : String) -> String {
  command("ssh", ssh_args(state) + [script], stage)
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
async fn save_diagnostic(
  stage : String,
  status : String,
  exit_code? : Int32,
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
    }
    if exit_code is Some(code) {
      set_field(event, "exitCode", Json::number(code.to_double()))
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
async fn notify(stage : String) -> Unit {
  @stdio.stderr.write("orca-env-devsy: " + stage + "\n")
  save_diagnostic(stage, "started")
}

///|
async fn create_state() -> Json {
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
  guard mode == "orca-worktree" || mode == "provisioned-root" else {
    raise AdapterError("Invalid checkoutMode")
  }
  guard !(mode == "provisioned-root" && config.connection == Server) else {
    raise AdapterError("provisioned-root requires SSH")
  }
  let state : Json = {
    "adapterVersion": 1,
    "workspaceId": environment("ORCA_VM_INSTANCE_ID"),
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
  let build_ref = config.build_ref.unwrap_or("HEAD")
  let hash = if valid_commit(build_ref) {
    build_ref
  } else {
    let resolved = command(
        "git",
        ["ls-remote", "--", repository, build_ref, build_ref + "^{}"],
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
      selected[0].split_once("\t") is Some((commit, _)) else {
      raise AdapterError("buildRef must resolve to one remote ref or commit")
    }
    commit.to_owned()
  }
  guard valid_commit(hash) else {
    raise AdapterError("Invalid remote build commit")
  }
  set_field(state, "buildRef", Json::string(build_ref))
  set_field(state, "buildCommit", Json::string(hash))
  notify("workspace-create")
  guard workspace(state) == None else {
    raise AdapterError("Workspace ID already exists")
  }
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
  errdefer discard_created_workspace(state)
  let args = [
      "--result-format",
      "json",
      "--uid",
      required(state, "workspaceUid"),
      "workspace",
      "up",
      repository + "@sha256:" + hash,
      "--id",
      required(state, "workspaceId"),
      "--ide-launch",
      "skip",
      "--git-clone-strategy=full",
    ] +
    config.up_args
  let output = devsy(state, args, "workspace-create")
  let created = workspace(state).unwrap()
  guard required(created, "uid") == uid else {
    raise AdapterError("Created workspace identity does not match request")
  }
  let result = up_result(output)
  set_field(state, "user", Json::string(required(result, "remoteUser")))
  validate_state(state)
  let root_script = match field(result, "remoteWorkspaceFolder") {
    Some(Json::String(folder)) => "cd " + quote(folder) + " && "
    _ => ""
  }
  let root = remote(
      state,
      root_script +
      "test \"$(pwd -P)\" = \"$(git rev-parse --show-toplevel)\" && pwd -P",
      "resolve-root",
    )
    .trim()
    .to_owned()
  guard root.has_prefix("/") && !root.contains("\n") else {
    raise AdapterError("Invalid remote project root")
  }
  let actual_commit = remote(
      state,
      "git -C " + quote(root) + " rev-parse HEAD",
      "verify-build-commit",
    )
    .trim()
    .to_owned()
  guard actual_commit == hash else {
    raise AdapterError(
      "Remote build checkout does not match resolved build commit",
    )
  }
  set_field(state, "buildCommit", Json::string(actual_commit))
  set_field(state, "projectRoot", Json::string(root))
  if mode == "provisioned-root" {
    let head = environment("ORCA_REPO_REF_HEAD")
    let branch = environment("ORCA_REPO_BRANCH")
    guard valid_commit(head) && !branch.has_prefix("-") else {
      raise AdapterError("Invalid provisioned-root checkout identity")
    }
    let script = "cd " +
      quote(root) +
      " && git fetch origin " +
      quote(head) +
      " && git checkout -B " +
      quote(branch) +
      " " +
      quote(head)
    ignore(remote(state, script, "checkout-workspace"))
  }
  state
}

///|
async fn lifecycle_state() -> (Json, Json) {
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
  guard workspace(state) is Some(current) &&
    field(current, "uid") == field(state, "workspaceUid") else {
    raise AdapterError("Workspace missing or replaced")
  }
  (state, result)
}

///|
async fn emit_connection(
  state : Json,
  install : Bool,
  existing? : Json,
) -> Unit {
  let connection = if required(state, "connection") == "ssh" {
    let target : Json = {
      "label": "Devsy",
      "host": "devsy-workspace",
      "port": 22,
      "username": required(state, "user"),
      "proxyCommand": proxy(state),
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
    ensure_tunnel(state, port)
    match field(result, "connection") {
      Some(value) => value
      None => raise AdapterError("Missing saved connection")
    }
  } else {
    server_connection(state, install)
  }
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
  let (state, previous) = if mode == "create" {
    (create_state(), Json::null())
  } else {
    lifecycle_state()
  }
  match mode {
    "create" => {
      errdefer discard_created_workspace(state)
      codex_addon(state)
      emit_connection(state, true)
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
          ],
          "workspace-resume",
        ),
      )
      codex_addon(state)
      emit_connection(state, false)
    }
    "reconnect" => emit_connection(state, false, existing=previous)
    "suspend" => {
      close_tunnel(state)
      ignore(
        devsy(
          state,
          ["workspace", "stop", required(state, "workspaceId")],
          "workspace-stop",
        ),
      )
    }
    "destroy" => {
      close_tunnel(state)
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
    }
    _ => raise AdapterError("Unknown command")
  }
  save_diagnostic(mode, "success")
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
      @stdio.stderr.write("orca-env-devsy: " + message + "\n")
      save_diagnostic(mode, "failed")
      raise InvalidConfig(message)
    }
    AdapterError(message) => {
      @stdio.stderr.write("orca-env-devsy: " + message + "\n")
      save_diagnostic(mode, "failed")
      raise AdapterError(message)
    }
    _ => {
      save_diagnostic(mode, "failed")
      raise AdapterError("Operation failed; private command output withheld")
    }
  }
}

///|
fn validate_state(state : Json) -> Unit raise {
  ignore(saved_command(state))
  let id = required(state, "workspaceId")
  let user = required(state, "user")
  guard id.length() <= 100 &&
    user.length() <= 64 &&
    !id.has_prefix("-") &&
    !user.has_prefix("-") &&
    [id, user]
    .iter()
    .all(text => {
      text
      .to_array()
      .iter()
      .all(c => {
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '-' ||
        c == '_'
      })
    }) else {
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
  @stdio.stderr.write(
    "Usage: orca-env-devsy <create|resume|suspend|destroy|reconnect>\n",
  )
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
        if field(state, "user") is Some(_) {
          close_tunnel(state)
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
