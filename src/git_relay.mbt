///|
async fn git_relay_status(
  directory : String,
  status : String,
  recording? : Bool,
) -> Unit {
  @fs.write_file(directory + "/git-status", status, permission=0o600) catch {
    _ =>
      save_diagnostic(
        "git-relay-recording",
        "degraded",
        tunnel_directory=directory,
        recording?,
      )
  }
  save_diagnostic(
    "git-relay",
    status,
    error_type?=if status == "unavailable" {
      Some("readiness_unavailable")
    } else {
      None
    },
    tunnel_directory=directory,
    recording?,
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
  WaitingForGitHelper
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
  let environment = workspace_environment(state)
  let mut phase = "readiness"
  let mut exit_code = None
  let mut detail = None
  let result = @async.with_timeout(3000, async fn() {
    let (code, output, stderr) = @process.collect_output(
      workspace_program(state, "ssh"),
      extra_env=environment,
      cwd?=workspace_directory(state).map(path => path[:]),
      inherit_env=false,
      ssh_mux_options(state, directory) + [script],
    )
    exit_code = Some(code)
    if code != 0 {
      if stderr.binary().length() > 0 {
        detail = Some(
          diagnostic_error(
            AdapterError(@utf8.decode_lossy(stderr.binary())),
            environment~,
          ),
        )
      }
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
    let body = text[:text.length() - status.length()]
      .to_owned()
      .trim()
      .to_owned()
    if status == "404" {
      return RelayReadiness::Unsupported
    }
    if status != "200" {
      if body != "" {
        detail = Some(diagnostic_error(AdapterError(body), environment~))
      }
      return RelayReadiness::Retry(
        if status == "503" {
          "http_503"
        } else {
          "http_error"
        },
      )
    }
    let value = @json.parse(body) catch {
      error => {
        detail = Some(diagnostic_error(error, environment~))
        return RelayReadiness::Retry("schema_invalid")
      }
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
      phase = "git-helper"
      exit_code = None
      let helper = "git config --global --get credential.helper | grep -F 'internal agent git-credentials' >/dev/null"
      let (code, _, stderr) = @process.collect_output(
        workspace_program(state, "ssh"),
        extra_env=environment,
        cwd?=workspace_directory(state).map(path => path[:]),
        inherit_env=false,
        ssh_mux_options(state, directory) + [helper],
      )
      exit_code = Some(code)
      if code != 0 && stderr.binary().length() > 0 {
        detail = Some(
          diagnostic_error(
            AdapterError(@utf8.decode_lossy(stderr.binary())),
            environment~,
          ),
        )
      }
      if code == 1 {
        return RelayReadiness::WaitingForGitHelper
      }
      if code != 0 {
        return RelayReadiness::Retry("transport_error")
      }
    }
    RelayReadiness::Ready
  }) catch {
    @async.TimeoutError => RelayReadiness::Retry("ssh_timeout")
    error => {
      detail = Some(diagnostic_error(error, environment~))
      RelayReadiness::Retry("transport_error")
    }
  }
  match result {
    Ready => ()
    WaitingForGitHelper =>
      save_diagnostic(
        "relay-probe",
        "pending",
        error_type="git_helper_unavailable",
        phase~,
        exit_code?,
        error_message?=detail,
        duration_ms=(@env.now() - started).to_double(),
        tunnel_directory=directory,
        recording=workspace_recording(state),
      )
    Retry(reason) =>
      save_diagnostic(
        "relay-probe",
        "failed",
        error_type=reason,
        phase~,
        exit_code?,
        error_message?=detail,
        duration_ms=(@env.now() - started).to_double(),
        tunnel_directory=directory,
        recording=workspace_recording(state),
      )
    Unsupported =>
      save_diagnostic(
        "relay-probe",
        "unsupported",
        error_type="readiness_unsupported",
        phase~,
        exit_code?,
        error_message?=detail,
        tunnel_directory=directory,
        recording=workspace_recording(state),
      )
  }
  result
}
