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
async fn stop_git_management(state : Json) -> Unit {
  @async.protect_from_cancel(async fn() {
    @async.with_timeout(2000, async fn() {
      ignore(
        @process.collect_output(
          "ssh",
          ["-o", "ProxyCommand=false"] +
          ssh_args(state) +
          [
            "-S",
            required(state, "socketDirectory") + "/credential-socket",
            "-O",
            "exit",
          ],
        ),
      )
    }) catch {
      _ => ()
    }
    save_diagnostic("git-relay-management", "stopped")
  })
}

///|
async fn monitor_git_relay(state : Json, directory : String) -> Unit {
  let enabled = directory + "/enabled"
  let mut git_enabled = false
  while @fs.exists(enabled) {
    try {
      git_enabled = @async.with_timeout(10000, async fn() {
        git_forwarding_enabled(state)
      })
      if !git_enabled {
        git_relay_status(directory, "disabled")
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
  let mut last = ""
  let mut attempt = 0
  while @fs.exists(enabled) {
    if git_enabled && git_relay_ready(state, directory) {
      if last != "ready" {
        git_relay_status(directory, "ready")
        last = "ready"
      }
      attempt = 0
      @async.sleep(2000)
      continue
    }
    if git_enabled {
      git_relay_status(directory, "unavailable")
      last = "unavailable"
    }
    @async.with_task_group(async fn(group) {
      let sink = @process.redirect_to_file("/dev/null", shared=true)
      defer sink.close()
      let child = @process.spawn(
        group,
        "ssh",
        ssh_args(state) +
        [
          "-M",
          "-S",
          required(state, "socketDirectory") + "/credential-socket",
          "-N",
          "-o",
          "ServerAliveInterval=10",
          "-o",
          "ServerAliveCountMax=3",
        ],
        stdin=@process.redirect_from_file("/dev/null"),
        stdout=sink,
        stderr=sink,
        no_wait=true,
      )
      defer child.cancel()
      defer stop_git_management(state)
      save_diagnostic("git-relay-management", "started")
      let deadline = @env.now() + 10000
      let mut recovered = false
      while @fs.exists(enabled) && child.try_wait() is None {
        let ready = git_enabled && git_relay_ready(state, directory)
        if ready && !recovered {
          recovered = true
          attempt = 0
          last = "ready"
          git_relay_status(directory, "ready")
        }
        // 1.23.0 stops the losing service. Recreate only the management
        // connection when the relay vanishes, never the Orca master.
        if git_enabled &&
          ((!ready && recovered) || (!recovered && @env.now() >= deadline)) {
          break
        }
        @async.sleep(if recovered || !git_enabled { 1000 } else { 250 })
      }
    }) catch {
      _ => save_diagnostic("git-relay-management", "process-error")
    }
    if @fs.exists(enabled) {
      attempt = if attempt < 5 { attempt + 1 } else { 5 }
      let delay = if attempt < 5 { 250 * (1 << (attempt - 1)) } else { 30000 }
      if git_enabled {
        git_relay_status(directory, "unavailable")
        last = "unavailable"
      }
      save_diagnostic("git-relay", "retry", attempt~, retry_delay_ms=delay)
      @async.sleep(delay)
    }
  }
}
