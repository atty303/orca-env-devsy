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
async fn git_relay_ready(state : Json, directory : String) -> Bool {
  // ProxyCommand=false prevents OpenSSH's mux fallback from opening a new
  // Devsy connection and concealing the loss under test.
  let script =
    #|# orca-git-readiness
    #|set -eu
    #|helper=$(git config --global --get credential.helper) || exit 1
    #|case "$helper" in *'internal agent git-credentials'*) ;; *) exit 1 ;; esac
    #|port=12049
    #|previous=
    #|for word in $helper; do
    #|  if test "$previous" = --port; then port=$word; fi
    #|  previous=$word
    #|done
    #|case "$port" in ''|*[!0-9]*) exit 1 ;; esac
    #|test "$port" -ge 1 && test "$port" -le 65535
    #|curl --noproxy '*' -fsS --max-time 2 "http://localhost:$port/" >/dev/null
  let script = script +
    "\ntest \"$(curl --noproxy '*' -fsS --max-time 2 \"http://localhost:$port/owner\")\" = " +
    quote(required(state, "user"))
  @async.with_timeout(4000, async fn() {
    let (code, _, _) = @process.collect_output(
      "ssh",
      ["-o", "ProxyCommand=false", "-o", "ControlMaster=no"] +
      ssh_args(state) +
      ["-S", control_socket(state, directory), script],
    )
    code == 0
  }) catch {
    _ => false
  }
}

///|
async fn monitor_git_relay(
  state : Json,
  directory : String,
  initial_enabled~ : Bool? = None,
) -> Unit {
  let enabled = directory + "/enabled"
  match initial_enabled {
    Some(false) => {
      git_relay_status(directory, "disabled")
      return
    }
    Some(true) => ()
    None =>
      while @fs.exists(enabled) {
        try {
          if !@async.with_timeout(10000, async fn() {
              git_forwarding_enabled(state)
            }) {
            git_relay_status(directory, "disabled")
            return
          }
          break
        } catch {
          _ => {
            git_relay_status(directory, "unavailable")
            save_diagnostic("git-relay-options", "retry", retry_delay_ms=10000)
            @async.sleep(10000)
          }
        }
      }
  }
  let mut last = ""
  let mut was_ready = false
  while @fs.exists(enabled) {
    let status = if git_relay_ready(state, directory) {
      was_ready = true
      "ready"
    } else if was_ready {
      "unavailable"
    } else {
      "pending"
    }
    if status != last {
      git_relay_status(directory, status)
      last = status
    }
    @async.sleep(500)
  }
}
