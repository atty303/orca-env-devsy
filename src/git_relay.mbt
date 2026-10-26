///|
async fn git_relay_status(directory : String, status : String) -> Unit {
  @fs.write_file(directory + "/git-status", status, permission=0o600) catch {
    _ => save_diagnostic("git-relay-recording", "degraded")
  }
  save_diagnostic(
    "git-relay",
    status,
    error_type?=if status == "unavailable" {
      Some("readiness_unavailable")
    } else {
      None
    },
  )
}

///|
async fn git_forwarding_enabled(state : Json) -> Bool {
  let options = @json.parse(
    devsy(
      state,
      ["--result-format", "json", "context", "get"],
      "git-relay-options",
    ),
  )
  let option = field(options, "SSH_INJECT_GIT_CREDENTIALS").unwrap_or(
    Json::null(),
  )
  match field(option, "value") {
    Some(Json::String("false")) => false
    Some(Json::String("true")) => true
    _ => field(option, "default") != Some(Json::string("false"))
  }
}

///|
priv enum RelayReadiness {
  Ready
  Retry(String)
  Unsupported
}

///|
async fn relay_readiness(
  state : Json,
  directory : String,
  git_enabled : Bool,
) -> RelayReadiness {
  let script =
    #|# orca-relay-readiness
    #|set -eu
    #|curl --disable --noproxy '*' --silent --max-time 1 --max-filesize 4096 --write-out '\n%{http_code}' http://localhost:12049/ready
  let started = @env.now()
  let result = @async.with_timeout(3000, async fn() {
    let (code, output, _) = @process.collect_output(
      "ssh",
      ["-o", "ProxyCommand=false", "-o", "ControlMaster=no"] +
      ssh_args(state) +
      ["-S", control_socket(state, directory), script],
    )
    if code != 0 {
      return RelayReadiness::Retry(
        if code == 28 {
          "http_timeout"
        } else {
          "transport_error"
        },
      )
    }
    let text = output.text().trim().to_owned()
    let lines = text.split("\n").to_array()
    let status = lines.last().unwrap_or("").to_owned()
    if status == "404" {
      return RelayReadiness::Unsupported
    }
    if status != "200" {
      return RelayReadiness::Retry(
        if status == "503" {
          "http_503"
        } else {
          "http_error"
        },
      )
    }
    let body = text[:text.length() - status.length()]
      .to_owned()
      .trim()
      .to_owned()
    let value = @json.parse(body) catch {
      _ => return RelayReadiness::Retry("schema_invalid")
    }
    if field(value, "version") != Some(Json::number(1)) {
      return RelayReadiness::Unsupported
    }
    if field(value, "owner") != field(state, "user") {
      return RelayReadiness::Retry("owner_mismatch")
    }
    for name in ["host_owner", "instance"] {
      if field(value, name) is Some(Json::String(value)) && value != "" {
        continue
      }
      return RelayReadiness::Retry("schema_invalid")
    }
    if git_enabled {
      let helper = "git config --global --get credential.helper | grep -F 'internal agent git-credentials' >/dev/null"
      let (code, _, _) = @process.collect_output(
        "ssh",
        ["-o", "ProxyCommand=false", "-o", "ControlMaster=no"] +
        ssh_args(state) +
        ["-S", control_socket(state, directory), helper],
      )
      if code != 0 {
        return RelayReadiness::Retry("git_helper_unavailable")
      }
    }
    RelayReadiness::Ready
  }) catch {
    @async.TimeoutError => RelayReadiness::Retry("ssh_timeout")
    _ => RelayReadiness::Retry("transport_error")
  }
  match result {
    Ready => ()
    Retry(reason) =>
      save_diagnostic(
        "relay-probe",
        "failed",
        error_type=reason,
        duration_ms=(@env.now() - started).to_double(),
        tunnel_directory=directory,
      )
    Unsupported =>
      save_diagnostic(
        "relay-probe",
        "unsupported",
        error_type="readiness_unsupported",
        tunnel_directory=directory,
      )
  }
  result
}
