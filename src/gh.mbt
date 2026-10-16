///|
fn gh_preflight_script() -> String {
  let script =
    #|set -eu
    #|command -v gh >/dev/null 2>&1 || exit 20
    #|test -z "${GH_TOKEN:-}" || exit 10
    #|test -z "${GITHUB_TOKEN:-}" || exit 13
    #|home="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
    #|hosts="$home/hosts.yml"
    #|marker="$home/.orca-env-devsy-gh-auth"
    #|test ! -L "$hosts" && test ! -L "$marker" || exit 12
    #|before=missing
    #|if test -e "$hosts"; then
    #|  test -f "$hosts" || exit 12
    #|  before=$(sha256sum < "$hosts")
    #|fi
    #|ownership=install
    #|if test -e "$marker"; then
    #|  test -f "$marker" && test "$before" = "$(cat "$marker")" || exit 12
    #|  ownership=update
    #|else
    #|  if gh auth token --hostname github.com >/dev/null 2>&1 || gh config get user --host github.com >/dev/null 2>&1 || gh config get users --host github.com >/dev/null 2>&1; then exit 11; fi
    #|fi
  script
}

///|
fn gh_snapshot_script() -> String {
  "# orca-gh-auth-snapshot\n" +
  gh_preflight_script() +
  "\nprintf '%s\\000%s\\000%s\\000' \"$before\" \"$home\" \"$ownership\"\nif test \"$before\" != missing; then cat \"$hosts\"; fi"
}

///|
// Never call gh auth login/switch/logout: even --insecure-storage mutates shared
// keyring slots. Merge with the existing YAML library and publish only the file.
fn gh_delivery_script() -> String {
  let setup =
    #|set -eu
    #|# orca-gh-auth-publish
    #|IFS= read -r expected
    #|IFS= read -r size
    #|home="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
    #|umask 077
    #|mkdir -p "$home"
    #|lock="$home/.orca-env-devsy-gh-lock"
    #|mkdir "$lock" 2>/dev/null || exit 21
    #|temporary=
    #|trap 'test -z "$temporary" || rm -rf "$temporary"; rmdir "$lock"' EXIT
    #|trap 'exit 1' HUP INT TERM
  let publish =
    #|test "$before" = "$expected" || exit 12
    #|temporary=$(mktemp -d "$home/.orca-gh.XXXXXX")
    #|cat > "$temporary/hosts.yml"
    #|test "$(wc -c < "$temporary/hosts.yml")" -eq "$size" || exit 23
    #|chmod 600 "$temporary/hosts.yml"
    #|sha256sum < "$temporary/hosts.yml" > "$temporary/marker"
    #|test ! -L "$hosts" && test ! -L "$marker" || exit 12
    #|if test "$before" = missing; then
    #|  test ! -e "$hosts" || exit 12
    #|else
    #|  test -f "$hosts" && test "$before" = "$(sha256sum < "$hosts")" || exit 12
    #|fi
    #|# A failed final rename preserves the old auth and fails closed next time.
    #|mv "$temporary/marker" "$marker"
    #|mv "$temporary/hosts.yml" "$hosts"
  setup + "\n" + gh_preflight_script() + "\n" + publish
}

///|
async fn gh_capture(
  program : String,
  args : Array[String],
  environment? : Map[String, String],
) -> (Int32, String) {
  let sink = @process.redirect_to_file("/dev/null", shared=true)
  defer sink.close()
  let (reader, output) = @process.read_from_process()
  defer reader.close()
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      program,
      args,
      extra_env?=environment,
      stdin=@process.redirect_from_file("/dev/null"),
      stdout=output,
      stderr=sink,
    )
    let bytes = @buffer.Buffer(size_hint=4096)
    while reader.read_some(max_len=4096) is Some(chunk) {
      guard bytes.length() + chunk.length() <= 1048576 else {
        raise AdapterError("GitHub auth output too large")
      }
      bytes.write_bytes(chunk)
    }
    (child.wait(), @utf8.decode(bytes.to_bytes()))
  })
}

///|
async fn gh_host_token() -> String {
  let (code, output) = gh_capture("gh", [
    "auth", "token", "--hostname", "github.com",
  ])
  let token = output.trim().to_owned()
  guard code == 0 &&
    token != "" &&
    token.length() <= 65536 &&
    token.to_array().all(c => c >= '!' && c <= '~') else {
    raise AdapterError("Host GitHub authentication unavailable")
  }
  token
}

///|
async fn gh_host_login(token : String) -> String {
  let (code, output) = gh_capture(
    "gh",
    ["api", "user", "--hostname", "github.com", "--jq", ".login"],
    environment={ "GH_TOKEN": token },
  )
  let login = output.trim().to_owned()
  guard code == 0 &&
    login != "" &&
    login.length() <= 256 &&
    login.to_array().all(c => c >= '!' && c <= '~') else {
    raise AdapterError("Host GitHub account unavailable")
  }
  login
}

///|
fn gh_snapshot_parts(
  snapshot : String,
) -> (String, String, String, String) raise {
  match snapshot.split("\u0000").to_array() {
    [before, directory, ownership, yaml] if ownership == "install" ||
      ownership == "update" =>
      (
        before.to_owned(),
        directory.to_owned(),
        ownership.to_owned(),
        yaml.to_owned(),
      )
    _ => raise AdapterError("Invalid GitHub auth snapshot")
  }
}

///|
fn gh_token_source() -> String {
  for name in ["GH_TOKEN", "GITHUB_TOKEN"] {
    if @env.get_env_var(name) is Some(value) && value != "" {
      return name
    }
  }
  "gh-config-or-keyring"
}

///|
fn gh_document(
  snapshot : String,
  login : String,
  token : String,
) -> String raise {
  let (before, _, _, yaml) = gh_snapshot_parts(snapshot)
  let document = if yaml.trim() == "" {
    Json::empty_object()
  } else {
    let docs = @yaml.Yaml::load_from_string(yaml)
    guard docs.length() == 1 else {
      raise AdapterError("Invalid GitHub auth document")
    }
    docs[0].to_json()
  }
  guard document is Json::Object(_) else {
    raise AdapterError("Invalid GitHub auth mapping")
  }
  let users = Json::empty_object()
  set_field(users, login, { "oauth_token": token })
  let host = match field(document, "github.com") {
    None => Json::empty_object()
    Some(Json::Object(_) as host) => host
    _ => raise AdapterError("Invalid GitHub host mapping")
  }
  // Drop stale managed accounts while retaining unrelated per-host settings.
  set_field(host, "user", Json::string(login))
  set_field(host, "oauth_token", Json::string(token))
  set_field(host, "users", users)
  set_field(document, "github.com", host)
  let content = document.stringify() + "\n"
  before + "\n" + @utf8.encode(content).length().to_string() + "\n" + content
}

///|
async fn gh_deliver(state : Json, payload : String) -> Int32 {
  let sink = @process.redirect_to_file("/dev/null", shared=true)
  defer sink.close()
  let (input, writer) = @process.write_to_process()
  defer writer.close()
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      "ssh",
      ssh_args(state, services=false) + [gh_delivery_script()],
      stdin=input,
      stdout=sink,
      stderr=sink,
    )
    writer.write(payload)
    writer.close()
    child.wait()
  })
}

///|
priv struct GhSequence {
  mut value : Int32
}

///|
let gh_sequence : GhSequence = { value: 0, }

///|
priv struct GhOperation {
  id : String
  workspace : String
}

///|
async fn GhOperation::record(
  self : GhOperation,
  status : String,
  phase? : String,
  code? : Int32,
  error_type? : String,
  duration_ms? : Double,
  inputs? : Json,
) -> Unit {
  save_diagnostic(
    "gh-auth",
    status,
    operation_id=self.id,
    workspace_id=self.workspace,
    phase?,
    exit_code?=code,
    error_type?,
    duration_ms?,
    gh_input?=inputs,
  )
}

///|
fn gh_delivery_status(code : Int32) -> String {
  match code {
    0 => "success"
    10 | 13 => "preserved-environment"
    11 => "preserved-authentication"
    12 => "preserved-modified"
    _ => "warning"
  }
}

///|
async fn gh_addon(state : Json) -> Unit {
  gh_sequence.value += 1
  let operation : GhOperation = {
    id: recording_run_id + ":gh:" + gh_sequence.value.to_string(),
    workspace: required(state, "workspaceId"),
  }
  let enabled = field(state, "ghAuth") == Some(Json::boolean(true))
  let inputs : Json = { "enabled": enabled, "hostname": "github.com" }
  if enabled && @env.get_env_var("ORCA_ENV_DEVSY_RECORDING") != Some("0") {
    for name in ["GH_CONFIG_DIR", "XDG_CONFIG_HOME", "HOME"] {
      set_field(
        inputs,
        name,
        match @env.get_env_var(name) {
          Some(value) => Json::string(value)
          None => Json::null()
        },
      )
    }
    for name in ["GH_TOKEN", "GITHUB_TOKEN"] {
      set_field(
        inputs,
        name,
        Json::string(
          match @env.get_env_var(name) {
            None => "unset"
            Some("") => "empty"
            Some(_) => "present-value-withheld"
          },
        ),
      )
    }
  }
  operation.record(if enabled { "started" } else { "disabled" }, inputs~)
  if !enabled {
    return
  }
  let started = @env.now()
  let mut phase = "host-token"
  progress_message("gh-auth: running…")
  try {
    let code = @async.with_timeout(45000, async fn() {
      operation.record("started", phase~)
      let token = gh_host_token()
      operation.record("success", phase~)
      phase = "snapshot"
      operation.record("started", phase~)
      let (code, snapshot) = gh_capture(
        "ssh",
        ssh_args(state, services=false) + [gh_snapshot_script()],
      )
      operation.record(gh_delivery_status(code), phase~, code~)
      if code != 0 {
        if code == 10 || code == 13 {
          operation.record("preserved-environment", phase~, inputs={
            "remoteAuthenticationSource": if code == 10 {
              "GH_TOKEN"
            } else {
              "GITHUB_TOKEN"
            },
          })
        }
        return code
      }
      let (_, directory, ownership, _) = gh_snapshot_parts(snapshot)
      operation.record("selected", phase~, inputs={
        "remoteConfigDirectory": directory,
        "delivery": ownership,
      })
      phase = "host-account"
      operation.record("started", phase~)
      let login = gh_host_login(token)
      operation.record("success", phase~, inputs={
        "login": login,
        "authenticationSource": gh_token_source(),
      })
      phase = "merge"
      let payload = gh_document(snapshot, login, token)
      operation.record("success", phase~)
      phase = "delivery"
      operation.record("started", phase~)
      gh_deliver(state, payload)
    })
    let status = gh_delivery_status(code)
    operation.record(
      status,
      phase="complete",
      code~,
      duration_ms=(@env.now() - started).to_double(),
      error_type?=match code {
        0 | 10 | 11 | 12 | 13 => None
        20 => Some("remote_gh_missing")
        21 => Some("delivery_locked")
        23 => Some("incomplete_payload")
        _ => Some("delivery_failed")
      },
    )
    if status == "warning" {
      progress_message(
        "warning: GitHub authentication addon failed at " +
        phase +
        "; continuing",
      )
    } else {
      progress_message(
        "gh-auth: " + status + " (" + progress_timing(started) + ")",
      )
    }
  } catch {
    error => {
      let status = if error is @async.TimeoutError {
        "timeout"
      } else if @async.is_being_cancelled() {
        "cancelled"
      } else {
        "warning"
      }
      operation.record(
        status,
        phase~,
        error_type=match phase {
          "host-token" => "host_auth_unavailable"
          "host-account" => "host_account_unavailable"
          "merge" => "invalid_auth_document"
          _ => "delivery_failed"
        },
        duration_ms=(@env.now() - started).to_double(),
      )
      if status == "cancelled" {
        raise error
      }
      progress_message(
        "warning: GitHub authentication addon failed at " +
        phase +
        "; continuing",
      )
    }
  }
}
