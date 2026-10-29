///|
fn integration_binary() -> String {
  @env.get_env_var("ORCA_ENV_DEVSY_TEST_BINARY").unwrap_or(
    @env.current_dir().unwrap() +
    "/_build/native/release/build/cmd/main/main.exe",
  )
}

///|
let fixture_permits : @async.Semaphore = @async.Semaphore(4)

///|
async fn fixture() -> (String, Map[String, String]) {
  fixture_permits.acquire()
  let directory = @fs.tmpdir(prefix="orca-env-devsy-test")
  @fs.write_file(directory + "/fixture-permit", "")
  @fs.mkdir(directory + "/bin")
  let devsy =
    #|#!/bin/sh
    #|set -eu
    #|printf '%s\n' "$@" >> "$HOME/args"
    #|if test -n "${FAKE_INVOCATION_LOG:-}"; then printf 'invoked\n' >> "$FAKE_INVOCATION_LOG"; fi
    #|previous=
    #|for arg in "$@"; do
    #|  if test "$previous" = --uid; then printf '%s' "$arg" > "$HOME/uid"; fi
    #|  if test "$previous" = --id; then printf '%s' "$arg" > "$HOME/workspace-id"; fi
    #|  previous="$arg"
    #|done
    #|case "$*" in
    #|  *'context list'*) printf '[{"name":"fixture-context","default":true}]\n' ;;
    #|  *'context get'*) printf '{"SSH_INJECT_GIT_CREDENTIALS":{"default":"true","value":"%s"}}\n' "${FAKE_GIT_FORWARDING:-true}" ;;
    #|  *'provider list'*) if test -f "$HOME/providers"; then cat "$HOME/providers"; else printf '{"fixture-provider":{"config":{"agent":{"local":"true","driver":"apple","apple":{"path":"%s/bin/runtime"}}}}}' "$HOME"; fi ;;
    #|  *'workspace list'*)
    #|    if test -f "$HOME/block-list"; then
    #|      printf '%s\n' "$$" > "$HOME/blocked-list-pid"
    #|      while test ! -f "$HOME/release-list"; do sleep 0.1; done
    #|    fi
    #|    if test -f "$HOME/created"; then printf '[{"id":"%s","uid":"%s","provider":{"name":"fixture-provider"}}]\n' "$(cat "$HOME/workspace-id")" "$(cat "$HOME/uid")"; else printf '[]\n'; fi ;;
    #|  *'workspace status'*) test ! -f "$HOME/fail-status"; if test -f "$HOME/busy"; then printf '{"state":"Busy"}\n'; elif test -f "$HOME/stopped"; then printf '{"state":"Stopped"}\n'; else printf '{"state":"Running"}\n'; fi ;;
    #|  *'workspace up'*) rm -f "$HOME/stopped"; touch "$HOME/created" "$HOME/volume-present"; test ! -f "$HOME/fail-up"
    #|    if test -f "$HOME/up-result"; then cat "$HOME/up-result"; else printf '{"kind":"result","outcome":"success","remoteUser":"developer","remoteWorkspaceFolder":"/workspace/repo"}\n'; fi ;;
    #|  *'workspace ssh'*'/proc/self/mountinfo'*) test ! -f "$HOME/fail-storage" ;;
    #|  *'workspace stop'*) test ! -f "$HOME/fail-stop"; touch "$HOME/stopped" ;;
    #|  *'workspace delete'*) test ! -f "$HOME/fail-delete"; rm -f "$HOME/created" ;;
    #|  *) exit 2 ;;
    #|esac
  let git =
    #|#!/bin/sh
    #|case "$*" in *--symref*) printf 'ref: refs/heads/main\tHEAD\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tHEAD\n'; exit 0 ;; esac
    #|remote=refs/heads/main
    #|for arg in "$@"; do case "$arg" in *'^{}') : ;; refs/heads/*) remote="$arg" ;; esac; done
    #|printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t%s\n' "$remote"
  let ssh =
    #|#!/bin/sh
    #|set -eu
    #|printf '%s\n' "$@" >> "$HOME/ssh-args"
    #|control=
    #|owner=developer
    #|previous=
    #|for arg in "$@"; do
    #|  if test "$previous" = -S; then control="$arg"; fi
    #|  case "$arg" in *@*.devsy) owner=${arg%%@*} ;; esac
    #|  previous="$arg"
    #|done
    #|case "$*" in
    #|  *'-N'*) if test -f "$HOME/recover-on-master"; then rm -f "$HOME/rpc-unavailable" "$HOME/recover-on-master"; fi; printf '%s\n' "$$" > "$HOME/master-pid"; case "$*" in *'--start-services=false'*) printf disabled > "$HOME/primary-services" ;; *) printf enabled > "$HOME/primary-services" ;; esac ;;
    #|esac
    #|case "$*" in
    #|  *'candidate="$base/update-$version"'* )
    #|    test ! -f "$HOME/fail-update-prepare"; printf 'prepare\n' >> "$HOME/update-steps" ;;
    #|  *'orca-server-relay-'*)
    #|    test ! -f "$HOME/fail-server-check" || { printf 'cannot inspect server environment token=ghp_fixtureprivatetoken123\n' >&2; exit 1; }
    #|    if test -f "$HOME/server-instance-secret"; then printf '{"outcome":"match","serverInstance":"ghp_fixtureprivatetoken123","relayInstance":"ghp_fixtureprivatetoken123"}';
    #|    elif test -f "$HOME/server-instance-unset"; then case "$*" in *'orca-server-relay-verify-required'*) printf '{"outcome":"skip","serverInstance":"","daemonInstance":null,"relayInstance":"current"}' ;; *) printf '{"outcome":"skip","serverInstance":"","relayInstance":null}' ;; esac;
    #|    elif test -f "$HOME/daemon-instance-stale"; then
    #|      case "$*" in *'orca-server-relay-verify'*) printf '{"outcome":"mismatch","serverInstance":"current","daemonInstance":"old","relayInstance":"current"}' ;; *) printf '{"outcome":"restart","serverInstance":"current","daemonInstance":"old","relayInstance":"current"}'; rm -f "$HOME/served" "$HOME/daemon-instance-stale"; printf 'relay-stop\n' >> "$HOME/update-steps" ;; esac
    #|    elif test -f "$HOME/server-instance-stale"; then
    #|      case "$*" in *'orca-server-relay-verify'*) printf '{"outcome":"mismatch","serverInstance":"old","relayInstance":"current"}' ;; *) printf '{"outcome":"restart","serverInstance":"old","relayInstance":"current"}'; rm -f "$HOME/served" "$HOME/server-instance-stale"; printf 'relay-stop\n' >> "$HOME/update-steps" ;; esac
    #|    elif test -f "$HOME/relay-instance-next"; then printf '{"outcome":"match","serverInstance":"next","daemonInstance":null,"relayInstance":"next"}';
    #|    else printf '{"outcome":"match","serverInstance":"current","relayInstance":"current"}'; fi ;;
    #|  *'const inodes = new Set'* )
    #|    case "$*" in *ORCA_ENV_DEVSY_UPDATE_*) test -f "$HOME/served"; printf 'owner-verified\n' >> "$HOME/update-steps" ;; *) test ! -f "$HOME/fail-update-stop"; printf 'stop\n' >> "$HOME/update-steps"; rm -f "$HOME/served" ;; esac ;;
    #|  *'candidate="$base/update-"'* )
    #|    test ! -f "$HOME/fail-update-switch"; printf 'switch\n' >> "$HOME/update-steps"; printf '1.4.242' > "$HOME/server-version" ;;
    #|  *'rm -rf'*'update-previous'* )
    #|    printf 'cleanup\n' >> "$HOME/update-steps" ;;
    #|  *'dir="$base/current"'*'--version'* | *'base="$HOME/.local/share/orca-env-devsy/orca/current"'*'--version'* )
    #|    if test -f "$HOME/server-version"; then cat "$HOME/server-version"; else printf '1.4.100'; fi ;;
    #|  *'-- import '* )
    #|    cat > "$HOME/delivered-settings"
    #|    if test -f "$HOME/fail-settings"; then printf '{"phase":"write","code":"ENOSPC"}' >&2; exit 1; fi ;;
    #|  *'const fs = require'* )
    #|    test -n "$control" && test -f "$control"
    #|    printf 'start\n' >> "$HOME/idle-starts"
    #|    printf '%s\n' "$$" > "$HOME/idle-pid"
    #|    trap 'printf "closed\n" >> "$HOME/idle-closed"' EXIT
    #|    cat >/dev/null
    #|    printf 'observe\n' >> "$HOME/idle-requests"
    #|    if test -f "$HOME/fail-idle-connect"; then exit 3; fi
    #|    if test -f "$HOME/drop-idle-once"; then rm "$HOME/drop-idle-once"; exit 4; fi
    #|    count=$(wc -l < "$HOME/idle-requests")
    #|    if test "$count" -ge 3 && test -f "$HOME/idle-final-active"; then printf '{"schemaVersion":1,"activity":"active"}\n';
    #|    elif test -f "$HOME/activity"; then cat "$HOME/activity"; printf '\n';
    #|    else printf '{"schemaVersion":1,"activity":"idle","terminals":[],"chats":[],"errors":[]}\n'; fi
    #|    if test -f "$HOME/activity-exit"; then exit "$(cat "$HOME/activity-exit")"; fi ;;
    #|  *'orca-relay-readiness'*)
    #|    touch "$HOME/relay-probed"
    #|    test -f "$control"
    #|    if test -f "$HOME/unsupported-ready"; then printf '\n404';
    #|    elif test -f "$HOME/rpc-unavailable"; then printf '\n503';
    #|    elif test -f "$HOME/flaky-ready"; then rm "$HOME/flaky-ready"; printf '\n503';
    #|    else printf '{"version":1,"owner":"%s","host_owner":"fixture-host","instance":"fixture-instance"}\n200' "$owner"; fi ;;
    #|  *'git config --global --get credential.helper'*)
    #|    touch "$HOME/git-probed"
    #|    if test -f "$HOME/git-invalid-stderr"; then printf '\377helper pending\n' >&2; fi
    #|    test ! -f "$HOME/git-unavailable" ;;
    #|  *'then printf present; else printf missing; fi'*) if test -f "$HOME/task-commit-missing"; then printf missing; else printf present; fi ;;
    #|  *'rev-parse'*'refs/remotes/origin/'*) printf '%s\n' "${FAKE_BUILD_COMMIT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
    #|  *'rev-parse HEAD'*) test ! -f "$HOME/fail-root"; printf '%s\n' "${FAKE_BUILD_COMMIT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
    #|  *'then printf installed; else printf missing; fi'*) if test -f "$HOME/missing-orca"; then printf missing; else printf installed; fi ;;
    #|  *'./orca.AppImage --appimage-extract'*) rm -f "$HOME/missing-orca" ;;
    #|  *'Sec-WebSocket-Version'*) if test -f "$HOME/served"; then printf 101; else printf 000; fi ;;
    #|  *'repo add --json'*) test ! -f "$HOME/fail-project"; printf '{"ok":true,"result":{}}\n' ;;
    #|  *'project setups'*) printf '{"ok":true,"result":{"setups":[{"id":"fixture-setup","path":"/workspace/repo"}]}}\n' ;;
    #|  *'project setup-update'*) test ! -f "$HOME/fail-project"; printf '{"ok":true,"result":{"result":{"setup":{"worktreeBasePath":"/worktrees"}}}}\n' ;;
    #|  *'--recipe-json'*)
    #|    if test -f "$HOME/real-serve"; then sh -c "$arg"; exit $?; fi
    #|    if test -f "$HOME/fail-tunnel-cleanup"; then
    #|      for state in "$XDG_STATE_HOME/orca-env-devsy/tunnels/"*/state.json; do printf '{invalid' > "$state"; done
    #|      exit 1
    #|    fi
    #|    test ! -f "$HOME/fail-serve"; printf 'serve\n' >> "$HOME/serve-count"; touch "$HOME/served"; if test -f "$HOME/relay-changes-on-start"; then rm "$HOME/relay-changes-on-start"; touch "$HOME/server-instance-stale"; fi; if test -f "$HOME/relay-changes-with-server"; then rm "$HOME/relay-changes-with-server"; touch "$HOME/relay-instance-next"; fi; printf '{"schemaVersion":1,"connection":{"type":"orca-server","pairingCode":"fixture-pairing","projectRoot":"/workspace/repo"}}\n' ;;
    #|  *'-O check'*)
    #|    test -f "$control" ;;
    #|  *'-O exit'*) rm -f "$control" ;;
    #|  *'cat >'* ) test ! -f "$HOME/fail-addon"; cat > "$HOME/delivered-auth" ;;
    #|  *'-L 127.0.0.1:'* )
    #|    while test "$1" != '-L'; do shift; done
    #|    port=${2#127.0.0.1:}; port=${port%%:*}
    #|    printf '%s\n' "$port" > "$HOME/listener-port.tmp"
    #|    mv "$HOME/listener-port.tmp" "$HOME/listener-port"
    #|    count=0
    #|    while ! test -f "$HOME/listener-ready"; do count=$((count+1)); test "$count" -lt 100; sleep 0.01; done
    #|    keeper=
    #|    trap 'rm -f "$control"; if test -n "$keeper"; then kill "$keeper" 2>/dev/null || true; wait "$keeper" 2>/dev/null || true; fi' EXIT HUP INT TERM
    #|    while test -f "$HOME/hold-proxy-setup"; do sleep 0.01; done
    #|    if test -f "$HOME/keep-proxy-stderr"; then
    #|      sleep 60 & keeper=$!
    #|      printf '%s\n' "$keeper" > "$HOME/keeper-pid"
    #|    fi
    #|    touch "$control"
    #|    while test -f "$control"; do
    #|      if test -f "$HOME/drop-tunnel"; then rm "$HOME/drop-tunnel"; printf "Permission denied (publickey). password=private-stderr-secret\n" >&2; exit 1; fi
    #|      sleep 0.01
    #|    done ;;
    #|  *'-N'* )
    #|    trap 'rm -f "$control"' EXIT HUP INT TERM
    #|    touch "$control"
    #|    while test -f "$control" && test -f "$HOME/created"; do sleep 0.01; done ;;
    #|  *) : ;;
    #|esac
  let runtime =
    #|#!/bin/sh
    #|set -eu
    #|printf '%s\n' "$@" >> "$HOME/volume-args"
    #|if test -f "$HOME/fail-volume-list"; then echo 'runtime unavailable' >&2; exit 9; fi
    #|case "$*" in
    #|  'volume ls --format json') if test -f "$HOME/volume-list"; then cat "$HOME/volume-list"; elif test -f "$HOME/volume-present"; then printf '[{"configuration":{"name":"orca-env-devsy-%s"}}]' "$(cat "$HOME/uid")"; else printf '[]'; fi ;;
    #|  'volume rm '*) test ! -f "$HOME/created"; if test -f "$HOME/fail-volume-remove"; then echo 'volume is in use' >&2; exit 7; fi; test "$3" = "orca-env-devsy-$(cat "$HOME/uid")"; rm -f "$HOME/volume-present" ;;
    #|  *) exit 2 ;;
    #|esac
  for
    pair in [("devsy", devsy), ("git", git), ("ssh", ssh), ("runtime", runtime)] {
    let (name, script) = pair
    @fs.write_file(directory + "/bin/" + name, script + "\n", permission=0o700)
  }
  let env = {
    "PATH": directory +
    "/bin:" +
    @env.get_env_var("PATH").unwrap_or("/usr/bin:/bin"),
    "HOME": directory,
    "XDG_STATE_HOME": directory + "/.local/state",
    "CODEX_HOME": directory + "/.codex",
    "FAKE_HOME": directory,
    "ORCA_REPO_PATH": directory,
    "ORCA_REPO_URL": "https://example.com/repo.git",
    "ORCA_RECIPE_ID": "test",
    "ORCA_VM_INSTANCE_ID": "test-id",
    "CTX": "fixture-context",
  }
  (directory, env)
}

///|
async fn invoke(
  mode : String,
  env : Map[String, String],
  directory : String,
  payload? : Json,
) -> (Int32, String, String) {
  if mode == "create" &&
    @fs.exists(directory + "/orca.yaml") &&
    @fs.read_file(directory + "/orca.yaml").text().contains("orca-server") {
    settings_fixture(directory, env)
  }
  let executable = integration_binary()
  let input = if payload is Some(value) {
    @fs.write_file(directory + "/stdin.json", value.stringify())
    Some(@process.redirect_from_file(directory + "/stdin.json"))
  } else {
    None
  }
  let (status, stdout, stderr) = @process.collect_output(
    executable,
    if (mode == "recover" || mode == "restart") && payload is None {
      [mode]
    } else {
      ["recipe", mode]
    },
    extra_env=env,
    stdin?=input,
  )
  let diagnostics = if status != 0 { fixture_process_errors(env) } else { "" }
  (status, stdout.text(), stderr.text() + diagnostics)
}

///|
async fn fixture_process_errors(env : Map[String, String]) -> String {
  let diagnostics = []
  try {
    let path = env.get("XDG_STATE_HOME").unwrap() +
      "/orca-env-devsy/events.jsonl"
    for line in @fs.read_file(path).text().split("\n") {
      if line == "" {
        continue
      }
      let event = @json.parse(line.to_owned())
      if field(event, "status") != Some(Json::string("process-error")) {
        continue
      }
      let safe = Json::empty_object()
      for name in ["process_os", "process_utf8", "process_api"] {
        if field(event, "errorType") == Some(Json::string(name)) {
          set_field(safe, "errorType", Json::string(name))
        }
      }
      for name in ["read"] {
        if field(event, "phase") == Some(Json::string(name)) {
          set_field(safe, "phase", Json::string(name))
        }
      }
      if field(event, "osErrno") is Some(Json::Number(code, ..)) &&
        code > 0 &&
        code < 4096 &&
        code == code.to_int().to_double() {
        set_field(safe, "osErrno", Json::number(code))
      }
      diagnostics.push(safe.stringify())
    }
  } catch {
    _ => ()
  }
  diagnostics.join("\n")
}

///|
async test "native CLI preserves creation settings across lifecycle and emits only recipe JSON" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let yaml =
    #|devsy:
    #|  connection: ssh
    #|  buildRef: refs/heads/main
    #|  profile: cloud
    #|  profiles:
    #|    cloud:
    #|      context: "${CTX?}"
    #|      upArgs: ["--provider", "docker"]
    #|environmentRecipes:
    #|  - id: test
    #|    devsy:
    #|      upArgs: ["--provider-option", "VALUE=two words; $(ignored)"]
  @fs.write_file(directory + "/orca.yaml", yaml)
  let (status, stdout, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(stdout)
  assert_eq(field(result, "schemaVersion"), Some(Json::number(1)))
  let state = field(result, "userData").unwrap()
  assert_eq(field(state, "context"), Some(Json::string("fixture-context")))
  assert_eq(field(state, "orcaInstanceId"), Some(Json::string("test-id")))
  assert_true(required(state, "workspaceId").has_suffix("-test-id"))
  assert_true(required(state, "workspaceId").has_prefix("repo-"))
  assert_true(valid_workspace_id(required(state, "workspaceId")))
  assert_true(required(state, "workspaceId") != "test-id")
  let events = fixture_events(directory)
  let selection = create_event(events, "workspace-name")
  assert_eq(field(selection, "status"), Some(Json::string("selected")))
  assert_eq(
    field(field(selection, "source").unwrap(), "workspaceId"),
    field(state, "workspaceId"),
  )
  assert_eq(
    field(state, "buildCommit"),
    Some(Json::string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
  )
  assert_eq(saved_command(state), ["devsy"])
  assert_eq(field(state, "upArgs"), None)
  let args = @fs.read_file(directory + "/args")
  assert_true(args.text().contains("\n--git-clone-strategy=shallow\n"))
  assert_true(args.text().contains("VALUE=two words; $(ignored)\n"))
  @fs.write_file(directory + "/orca.yaml", "deliberately invalid yaml: [")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  for mode in ["resume", "suspend", "destroy"] {
    let (status, output, errors) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    if mode == "resume" {
      assert_eq(field(@json.parse(output), "userData"), Some(state))
    } else {
      assert_eq(output, "")
    }
  }
}

///|
async test "required environment errors identify their setting and never invoke Devsy" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let yaml =
    #|devsy:
    #|  connection: ssh
    #|  buildRef: refs/heads/main
    #|  context: "${MISSING?}"
    #|environmentRecipes:
    #|  - id: test
  @fs.write_file(directory + "/orca.yaml", yaml)
  let (status, output, errors) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  assert_true(errors.contains("MISSING"))
  assert_true(errors.contains("devsy.context"))
  assert_false(@fs.exists(directory + "/args"))
}

///|
async test "YAML anchors and recipe profiles parse without shell evaluation" {
  let source =
    #|devsy:
    #|  connection: ssh
    #|  buildRef: refs/heads/main
    #|  profiles:
    #|    chosen: &chosen
    #|      context: "${CTX?}"
    #|      upArgs: ["--provider", "docker"]
    #|environmentRecipes:
    #|  - id: test
    #|    devsy: *chosen
  let docs = @yaml.Yaml::load_from_string(source)
  let settings = resolve_settings(docs[0].to_json(), "test", name => {
    if name == "CTX" {
      Some("fixture")
    } else {
      None
    }
  })
  assert_eq(settings.context, Some("fixture"))
}

///|
async test "server CLI emits pairing separately and recover reuses a responding server" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    let yaml =
      #|devsy:
      #|  connection: orca-server
      #|  buildRef: refs/heads/main
      #|  orca-server:
      #|    env:
      #|      PATH: "${DEVSY_REMOTE_WORKSPACE_FOLDER?}/.local/bin:${PATH?}"
      #|  addons:
      #|    codexAuth: true
      #|environmentRecipes:
      #|  - id: test
    let invocation = configured_launcher(directory)
    let document = @yaml.Yaml::load_from_string(yaml)[0].to_json()
    set_field(
      field(document, "devsy").unwrap(),
      "command",
      Json::array(invocation.map(Json::string)),
    )
    @fs.write_file(directory + "/orca.yaml", document.stringify())
    let (status, output, warnings) = invoke("create", env, directory)
    assert_eq(status, 0, msg=warnings)
    let result = @json.parse(output)
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("suspend", env, directory, payload~))
    assert_true(warnings.contains("addon failed at"))
    let state = field(result, "userData").unwrap()
    let volume = required(state, "orcaVolume")
    assert_eq(volume, "orca-env-devsy-" + required(state, "workspaceUid"))
    let worker = @json.parse(
      @fs.read_file(required(state, "tunnelDirectory") + "/state.json").text(),
    )
    assert_eq(field(worker, "orcaVolume"), field(state, "orcaVolume"))
    assert_eq(field(worker, "serverEnv"), field(state, "serverEnv"))
    assert_true(
      @fs.read_file(directory + "/args")
      .text()
      .contains("type=volume,source=" + volume + ",target=/worktrees"),
    )
    let ssh = @fs.read_file(directory + "/ssh-args").text()
    assert_true(ssh.contains("ORCA_USER_DATA_PATH=/worktrees/.orca"))
    assert_true(
      ssh.contains(
        "project setup-update --json --host local --setup 'fixture-setup' --worktree-base-path /worktrees",
      ),
    )
    assert_eq(field(state, "pairingCode"), None)
    assert_false(state.stringify().contains("fixture-pairing"))
    assert_eq(saved_command(state), invocation)
    assert_true(
      @fs.read_file(directory + "/ssh-args")
      .text()
      .contains(
        "ProxyCommand=" +
        proxy(
          state,
          @fs.realpath(
            env.get("XDG_STATE_HOME").unwrap() +
            "/orca-env-devsy/ssh-proxy-adapter",
          ),
          lease=required(worker, "socketDirectory") + "/primary-proxy.lock",
        ),
      ),
    )
    @fs.write_file(directory + "/orca.yaml", "invalid: [")
    @fs.write_file(directory + "/ssh-args", "")
    let (status, output, errors) = invoke("recover", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_eq(
      field(@json.parse(output), "connection"),
      field(result, "connection"),
    )
    let commands = @fs.read_file(directory + "/ssh-args")
    assert_true(commands.text().contains("ProxyCommand=false"))
    assert_false(commands.text().contains("--ssh-proxy"))
    assert_false(commands.text().contains("--recipe-json"))
    assert_false(commands.text().contains("releases/latest"))
  })
}

///|
async fn wait_relay_fixture(
  phase : String,
  directory : String,
  worker : String,
  timeout : Int32,
  done : async () -> Bool,
) -> Unit {
  @async.with_timeout(timeout, async fn() {
    while !done() {
      @async.sleep(25)
    }
  }) catch {
    error => {
      let markers = []
      for
        name in [
          "server-instance-stale", "server-instance-unset", "daemon-instance-stale",
          "relay-changes-on-start", "relay-instance-next", "fail-server-check",
        ] {
        markers.push(
          name + "=" + @fs.exists(directory + "/" + name).to_string(),
        )
      }
      let worker_markers = []
      for name in ["probe-request", "server-relay-pending", "worker-error.json"] {
        worker_markers.push(
          name + "=" + @fs.exists(worker + "/" + name).to_string(),
        )
      }
      let events = fixture_failure_events(directory)
      assert_true(
        false,
        msg="relay fixture " +
          phase +
          ": " +
          diagnostic_error(error) +
          "\n" +
          markers.join(" ") +
          "\n" +
          worker_markers.join(" ") +
          "\n" +
          events,
      )
    }
  }
}

///|
async test "recover synchronizes a changed server relay instance and skips an unset instance" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    let workspace_id = required(state, "workspaceId")
    @fs.write_file(directory + "/server-instance-stale", "")
    @fs.write_file(directory + "/server-instance-unset", "")
    let (status, _, errors) = invoke("recover", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_true(errors.contains(workspace_id + ": recover done"), msg=errors)
    assert_true(@fs.exists(directory + "/server-instance-stale"))
    let pending_directory = required(state, "tunnelDirectory")
    @fs.write_file(pending_directory + "/server-relay-pending", "")
    let (retry_status, _, retry_errors) = invoke("recover", env, directory)
    assert_eq(retry_status, 0, msg=retry_errors)
    assert_false(@fs.exists(pending_directory + "/server-relay-pending"))
    @fs.remove(directory + "/server-instance-unset")
    @fs.write_file(directory + "/server-instance-secret", "")
    let (status, _, errors) = invoke("recover", env, directory)
    assert_eq(status, 0, msg=errors)
    @fs.remove(directory + "/server-instance-secret")
    let (status, _, errors) = invoke("restart", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_true(errors.contains(workspace_id + ": restart done"), msg=errors)
    assert_false(@fs.exists(directory + "/server-instance-stale"))
    assert_true(
      @fs.read_file(directory + "/update-steps").text().contains("relay-stop"),
    )
    let worker = required(state, "tunnelDirectory")
    @fs.write_file(directory + "/daemon-instance-stale", "")
    let (daemon_status, _, daemon_errors) = invoke("restart", env, directory)
    assert_eq(daemon_status, 0, msg=daemon_errors)
    assert_false(@fs.exists(directory + "/daemon-instance-stale"))
    @fs.write_file(directory + "/daemon-instance-stale", "")
    @fs.write_file(directory + "/relay-changes-with-server", "")
    let (changed_status, _, changed_errors) = invoke("recover", env, directory)
    assert_true(changed_status != 0, msg=changed_errors)
    assert_true(
      changed_errors.contains("relay instance changed"),
      msg=changed_errors,
    )
    let (retry_status, _, retry_errors) = invoke("recover", env, directory)
    assert_eq(retry_status, 0, msg=retry_errors)
    assert_false(@fs.exists(worker + "/server-relay-pending"))
    @fs.remove(directory + "/relay-instance-next")
    @fs.write_file(directory + "/server-instance-stale", "")
    @fs.write_file(worker + "/probe-request", "")
    wait_relay_fixture("initial probe", directory, worker, 10000, async fn() {
      !@fs.exists(directory + "/server-instance-stale") &&
      !@fs.exists(worker + "/probe-request") &&
      field(
        @json.parse(@fs.read_file(worker + "/status.json").text()),
        "status",
      ) ==
      Some(Json::string("connected"))
    })
    let before = @fs.read_file(directory + "/update-steps")
      .text()
      .split("relay-stop")
      .count()
    @fs.write_file(directory + "/server-instance-stale", "")
    @fs.write_file(directory + "/relay-changes-on-start", "")
    @fs.write_file(worker + "/probe-request", "")
    wait_relay_fixture("repeated restart", directory, worker, 15000, async fn() {
      @fs.read_file(directory + "/update-steps")
      .text()
      .split("relay-stop")
      .count() >=
      before + 2 &&
      !@fs.exists(worker + "/server-relay-pending")
    })
    @fs.write_file(directory + "/fail-server-check", "")
    @fs.write_file(worker + "/probe-request", "")
    wait_relay_fixture("error recorded", directory, worker, 10000, async fn() {
      @fs.exists(worker + "/worker-error.json")
    })
    let worker_error = @fs.read_file(worker + "/worker-error.json").text()
    assert_true(worker_error.contains("cannot inspect server environment"))
    assert_false(worker_error.contains("ghp_fixtureprivatetoken123"))
    @fs.remove(directory + "/fail-server-check")
    wait_relay_fixture("error cleared", directory, worker, 15000, async fn() {
      !@fs.exists(worker + "/worker-error.json")
    })
    let events = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(
      events.contains(
        "\"stage\":\"server-relay-sync\",\"status\":\"restarted\"",
      ),
    )
    assert_true(events.contains("\"serverInstance\":\"old\""))
    assert_true(events.contains("\"relayInstance\":\"current\""))
    assert_false(events.contains("ghp_fixtureprivatetoken123"))
  })
}

///|
async test "restart reports the target and redacted SSH failure after timeout" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS", "5000")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  defer ignore(invoke("destroy", env, directory, payload~))
  @fs.rename(directory + "/bin/ssh", directory + "/bin/ssh-original")
  let wrapper =
    #|#!/bin/sh
    #|case "$*" in *'-N'*) printf '[proxy] connection refused password=fixture-private-password\n' >&2; awk 'BEGIN { printf "password="; for (i=0;i<9000;i++) printf "x"; print "fixture-private-tail" }' >&2; exit 255 ;; esac
    #|exec "$HOME/bin/ssh-original" "$@"
  @fs.write_file(directory + "/bin/ssh", wrapper + "\n", permission=0o700)
  let (status, _, errors) = invoke("restart", env, directory)
  assert_true(status != 0)
  assert_true(errors.contains(required(state, "workspaceId")), msg=errors)
  assert_true(errors.contains("[proxy] connection refused"), msg=errors)
  assert_false(errors.contains("fixture-private-password"), msg=errors)
  assert_false(errors.contains("fixture-private-tail"), msg=errors)
  let records = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(records.contains("connection refused"))
  assert_false(records.contains("fixture-private-password"))
  assert_false(records.contains("fixture-private-tail"))
  @fs.rename(directory + "/bin/ssh-original", directory + "/bin/ssh")
}

///|
async test "provisioned-root uses schema 2 and checks out the supplied task commit independently" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("ORCA_REPO_REF_HEAD", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  env.set("ORCA_REPO_BRANCH", "task-branch")
  let yaml =
    #|devsy:
    #|  connection: ssh
    #|  buildRef: refs/heads/main
    #|environmentRecipes:
    #|  - id: test
    #|    checkoutMode: provisioned-root
  @fs.write_file(directory + "/orca.yaml", yaml)
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  assert_eq(field(result, "schemaVersion"), Some(Json::number(2)))
  assert_eq(
    field(result, "checkoutMode"),
    Some(Json::string("provisioned-root")),
  )
  let args = @fs.read_file(directory + "/ssh-args")
  assert_true(args.text().contains("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
  assert_true(args.text().contains("git checkout -B 'task-branch'"))
}

///|
async test "task checkout works offline for present commits and fetches only missing commits" {
  let directory = @fs.tmpdir(prefix="orca-env-devsy-checkout")
  defer cleanup_fixture(directory)
  let env = {
    "PATH": "/usr/bin:/bin",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_TERMINAL_PROMPT": "0",
  }
  let setup =
    #|set -eu
    #|git init -q "$1/source"
    #|git -C "$1/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm first
    #|git -C "$1/source" rev-parse HEAD
    #|git clone -q "$1/source" "$1/checkout"
    #|git -C "$1/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm second
    #|git -C "$1/source" rev-parse HEAD
    #|git -C "$1/checkout" remote set-url origin "$1/unavailable"
  let (status, output, errors) = @process.collect_output(
    "/bin/sh",
    ["-c", setup, "sh", directory],
    extra_env=env,
  )
  assert_eq(status, 0, msg=errors.text())
  let hashes = output
    .text()
    .trim()
    .split("\n")
    .to_array()
    .map(value => value.to_owned())
  let root = directory + "/checkout"
  let (status, _, errors) = @process.collect_output(
    "/bin/sh",
    ["-c", checkout_script(root, hashes[0], "task-existing")],
    extra_env=env,
  )
  assert_eq(status, 0, msg=errors.text())
  let fetch = "git -C " +
    quote(root) +
    " remote set-url origin " +
    quote(directory + "/source") +
    " && " +
    checkout_script(root, hashes[1], "task-fetched")
  let (status, _, errors) = @process.collect_output(
    "/bin/sh",
    ["-c", fetch],
    extra_env=env,
  )
  assert_eq(status, 0, msg=errors.text())
  let missing = "git -C " +
    quote(root) +
    " remote set-url origin " +
    quote(directory + "/unavailable") +
    " && " +
    checkout_script(
      root, "cccccccccccccccccccccccccccccccccccccccc", "task-missing",
    )
  let (status, _, _) = @process.collect_output(
    "/bin/sh",
    ["-c", missing],
    extra_env=env,
  )
  assert_true(status != 0)
  let (status, output, _) = @process.collect_output(
    "/usr/bin/git",
    ["-C", root, "rev-parse", "HEAD"],
    extra_env=env,
  )
  assert_eq(status, 0)
  assert_eq(output.text().trim(), hashes[1])
}

///|
async test "Codex addon delivers synthetic access data only and excludes secrets from output and diagnostics" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.mkdir(directory + "/.codex")
  let claims : Json = { "exp": 4102444800 }
  let token = "fixture." +
    @base64.encode(@utf8.encode(claims.stringify())) +
    ".signature"
  let auth : Json = {
    "tokens": {
      "access_token": token,
      "account_id": "fixture-account",
      "refresh_token": "fixture-refresh",
    },
  }
  @fs.write_file(directory + "/.codex/auth.json", auth.stringify())
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy:\n  connection: ssh\n  buildRef: refs/heads/main\n  addons:\n    codexAuth: true\nenvironmentRecipes:\n  - id: test\n",
  )
  let before = @env.now().reinterpret_as_int64()
  let (status, output, errors) = invoke("create", env, directory)
  let after = @env.now().reinterpret_as_int64()
  assert_eq(status, 0, msg=errors)
  assert_false(errors.contains("addon failed"), msg=errors)
  let delivered = @json.parse(
    @fs.read_file(directory + "/delivered-auth").text(),
  )
  let tokens = field(delivered, "tokens").unwrap()
  let refreshed = required(delivered, "last_refresh")
  assert_eq(refreshed.length(), 24)
  for index, character in refreshed.to_array() {
    match index {
      4 | 7 => assert_eq(character, '-')
      10 => assert_eq(character, 'T')
      13 | 16 => assert_eq(character, ':')
      19 => assert_eq(character, '.')
      23 => assert_eq(character, 'Z')
      _ => assert_true(character >= '0' && character <= '9')
    }
  }
  let parsed : @time.PlainDateTime = @string.FromStr::from_str(refreshed[0:23])
  let refreshed_ms = parsed.to_unix_second() * 1000 +
    (parsed.nanosecond() / 1000000).to_int64()
  assert_true(refreshed_ms >= before && refreshed_ms <= after)
  assert_eq(
    field(delivered, "auth_mode"),
    Some(Json::string("chatgptAuthTokens")),
  )
  assert_eq(field(tokens, "id_token"), Some(Json::string(token)))
  assert_eq(field(tokens, "account_id"), Some(Json::string("fixture-account")))
  assert_eq(field(tokens, "access_token"), Some(Json::string(token)))
  assert_eq(field(tokens, "refresh_token"), Some(Json::string("")))
  let records = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  )
  for data in [output, errors, records.text()] {
    assert_false(data.contains(token))
    assert_false(data.contains("fixture-refresh"))
  }
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  assert_eq(
    field(field(state, "devsyEnv").unwrap(), "HOME"),
    Some(Json::string(directory)),
  )
  env.set("HOME", directory + "/changed-home")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  let (status, output, errors) = invoke("resume", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
  assert_eq(field(@json.parse(output), "userData"), Some(state))
}

///|
async test "failed create removes its UID-owned workspace and permits retry" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy:\n  connection: ssh\n  buildRef: refs/heads/main\nenvironmentRecipes:\n  - id: test\n",
  )
  @fs.write_file(directory + "/fail-root", "")
  let (status, output, _) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  assert_false(@fs.exists(directory + "/created"))
  @fs.remove(directory + "/fail-root")
  let (status, _, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
}

///|
async test "failed provisioning cleans the requested UID before a recipe receipt exists" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy:\n  connection: ssh\n  buildRef: refs/heads/main\nenvironmentRecipes:\n  - id: test\n",
  )
  @fs.write_file(directory + "/fail-up", "")
  let (status, output, _) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  assert_false(@fs.exists(directory + "/created"))
  @fs.remove(directory + "/fail-up")
  let (status, _, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
}

///|
async test "fake tunnel ignores a stale listener request from an earlier lifetime" {
  let (directory, _) = fixture()
  defer cleanup_fixture(directory)
  let occupied = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer occupied.close()
  @fs.write_file(directory + "/listener-port", occupied.addr.port().to_string())
  with_fake_tunnel(directory, async fn() {
    @async.sleep(50)
    assert_false(@fs.exists(directory + "/listener-ready"))
    let fresh = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    let port = fresh.addr.port()
    fresh.close()
    @fs.write_file(directory + "/listener-port.tmp", port.to_string())
    @fs.rename(
      directory + "/listener-port.tmp",
      directory + "/listener-port",
      replace=true,
    )
    @async.with_timeout(1000, async fn() {
      while !@fs.exists(directory + "/listener-ready") {
        @async.sleep(10)
      }
    })
  })
  assert_false(@fs.exists(directory + "/listener-port"))
  assert_false(@fs.exists(directory + "/listener-ready"))
}

///|
async fn with_fake_tunnel(directory : String, run : async () -> Unit) -> Unit {
  // A previous lifetime's port request must not race the next SSH invocation.
  for marker in ["listener-port", "listener-ready"] {
    @fs.remove(directory + "/" + marker) catch {
      _ => ()
    }
  }
  defer (for marker in ["listener-port", "listener-ready"] {
    @fs.remove(directory + "/" + marker) catch {
      _ => ()
    }
  })
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      while !@fs.exists(directory + "/listener-port") {
        @async.sleep(10)
      }
      let port = @fs.read_file(directory + "/listener-port")
        .text()
        .trim()
        .to_owned()
      // Reconnecting masters share the current lifetime's listener.
      let listener = @socket.TcpServer(
        @socket.Addr::parse("127.0.0.1:" + port),
        reuse_addr=true,
      )
      defer listener.close()
      @fs.write_file(directory + "/listener-ready", "")
      while true {
        let (connection, _) = listener.accept()
        connection.close()
      }
    })
    run()
  }) catch {
    AdapterError(message) =>
      assert_true(
        false,
        msg=redact_credentials(message) +
          "\n" +
          fixture_failure_events(directory),
      )
    error => raise error
  }
}

///|
async test "remote server launch returns JSON while the detached server remains alive" {
  let directory = @fs.tmpdir(prefix="orca-env-devsy-pipe-test")
  defer cleanup_fixture(directory)
  let install = directory + "/.local/share/orca-env-devsy/orca/current"
  @fs.mkdir(install + "/resources/app.asar/out/cli", recursive=true)
  let executable =
    #|#!/bin/sh
    #|sleep 60 </dev/null >/dev/null &
    #|printf '%s' "$!" > "$HOME/child-pid"
    #|printf '{}\n'
  @fs.symlink(install + "/orca-ide", target="/bin/sh")
  @fs.write_file(
    install + "/resources/app.asar/out/cli/index.js",
    executable + "\n",
  )
  defer @async.protect_from_cancel(async fn() {
    if @fs.exists(directory + "/child-pid") {
      let pid = @fs.read_file(directory + "/child-pid").text()
      ignore(@process.run("kill", [pid]))
    }
  })
  let env = @env.get_env_vars()
  env.set("HOME", directory)
  let output = @async.with_timeout(3000, async fn() {
    command(
      "sh",
      ["-c", server_launch_script(directory, 12345, Json::empty_object())],
      "fixture-serve",
      environment=env,
    )
  })
  assert_eq(@json.parse(output), Json::empty_object())
  let pid = @fs.read_file(directory + "/child-pid").text()
  assert_eq(@process.run("kill", ["-0", pid]), 0)
}

///|
async fn configured_launcher(directory : String) -> Array[String] {
  let arguments = [
    "", "two words", "single' double\"", "$(touch unexpected); * & | >", "%h %% %r",
    "line\nbreak",
  ]
  let script = StringBuilder()
  script.write_string("#!/bin/sh\nset -eu\n")
  for argument in arguments {
    script.write_string("test \"$1\" = " + quote(argument) + "\nshift\n")
  }
  script.write_string(
    "printf 'ok\\n' >> " +
    quote(directory + "/launcher-calls") +
    "\nexec " +
    quote(directory + "/bin/devsy") +
    " \"$@\"\n",
  )
  let path = directory + "/launcher ' % with spaces"
  @fs.write_file(path, script.to_string(), permission=0o700)
  [path] + arguments
}

///|
async test "configured command survives YAML and environment changes and real OpenSSH proxy expansion" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let invocation = configured_launcher(directory)
  env.set("LAUNCHER", invocation[0])
  let document : Json = {
    "devsy": {
      "connection": "ssh",
      "buildRef": "refs/heads/main",
      "command": Json::array(
        ["${LAUNCHER?}"] + invocation[1:].map(Json::string),
      ),
    },
    "environmentRecipes": [{ "id": "test" }],
  }
  @fs.write_file(directory + "/orca.yaml", document.stringify())
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  assert_eq(saved_command(state), invocation)
  @fs.write_file(directory + "/orca.yaml", "devsy: {command: [missing]}\n")
  env.set("LAUNCHER", "missing")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  for mode in ["resume", "recover", "suspend"] {
    let (status, output, errors) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    if mode != "suspend" {
      assert_eq(field(@json.parse(output), "userData"), Some(state))
    }
  }
  let worker = required(state, "tunnelDirectory")
  @fs.remove(worker + "/enabled")
  @async.with_timeout(5000, async fn() {
    while worker_alive(worker) {
      @async.sleep(25)
    }
  })
  // OpenSSH expands percent tokens before the shell runs. Use its real consumer
  // from an unrelated cwd with no recipe PATH or interpolation environment.
  let proxy_env = { "PATH": "/usr/bin:/bin", "FAKE_HOME": directory }
  let before = @fs.read_file(directory + "/launcher-calls").text()
  let (status, _, errors) = @process.collect_output(
    "/bin/sh",
    [
      "-c",
      "cd / && exec /usr/bin/ssh \"$@\"",
      "sh",
      "-F",
      "/dev/null",
      "-o",
      "ConnectTimeout=2",
      "-o",
      "ProxyCommand=" + proxy(state, integration_binary()),
      "developer@devsy-workspace",
    ],
    extra_env=proxy_env,
    inherit_env=false,
  )
  // The fake Devsy transport deliberately cannot complete an SSH handshake.
  assert_true(status != 0)
  assert_eq(
    @fs.read_file(directory + "/launcher-calls").text(),
    before + "ok\n",
    msg=errors.text(),
  )
  let (status, _, errors) = invoke("destroy", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
  assert_false(@fs.exists(directory + "/created"))
}

///|
async test "invalid command is rejected before Devsy and errors retain only setting location" {
  for invalid in [Json::null(), [], [""], ["devsy", 1], ["${MISSING}"]] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    let document : Json = {
      "devsy": { "connection": "ssh", "buildRef": "refs/heads/main" },
      "environmentRecipes": [{ "id": "test", "devsy": { "command": invalid } }],
    }
    @fs.write_file(directory + "/orca.yaml", document.stringify())
    let (status, output, errors) = invoke("create", env, directory)
    assert_true(status != 0)
    assert_eq(output, "")
    assert_true(errors.contains("environmentRecipes.test.devsy.command"))
    assert_false(@fs.exists(directory + "/args"))
  }
}

///|
async test "legacy saved state defaults to devsy and invalid saved commands fail before execution" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  if state is Json::Object(map) {
    map.remove("command")
  }
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  for mode in ["resume", "recover", "suspend"] {
    let (status, _, errors) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  }
  let invocation_log = directory + "/invalid-command-invocations"
  env.set("FAKE_INVOCATION_LOG", invocation_log)
  let (status, _, _) = @process.collect_output(
    directory + "/bin/devsy",
    ["context", "list"],
    extra_env=env,
  )
  assert_eq(status, 0)
  assert_true(@fs.exists(invocation_log))
  @fs.remove(invocation_log)
  set_field(state, "command", [])
  let (status, _, errors) = invoke("destroy", env, directory, payload~)
  assert_true(status != 0)
  assert_true(errors.contains("recipeResult.userData.command"))
  assert_false(@fs.exists(invocation_log))
  env.remove("FAKE_INVOCATION_LOG")
  if state is Json::Object(map) {
    map.remove("command")
  }
  let (status, _, errors) = invoke("destroy", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
}

///|
async test "command diagnostics distinguish process failure and exit failure without retaining arguments" {
  // Exercise the binary so recording uses its own HOME and run identity.
  let (fixture_dir, env) = fixture()
  defer @fs.rmdir(fixture_dir, recursive=true)
  env.set("FIXTURE_PRIVATE_TOKEN", "private-argument-fixture")
  for
    invocation in [
      ["missing-command-fixture", "private-argument-fixture"],
      ["/bin/sh", "-c", "exit 7", "private-argument-fixture"],
      [
        "/bin/sh", "-c", "printf 'create microsandbox VM: private-argument-fixture\\n'; exit 7",
      ],
    ] {
    let document : Json = {
      "devsy": {
        "connection": "ssh",
        "buildRef": "refs/heads/main",
        "command": Json::array(invocation.map(Json::string)),
      },
      "environmentRecipes": [{ "id": "test" }],
    }
    @fs.write_file(fixture_dir + "/orca.yaml", document.stringify())
    let (status, output, errors) = invoke("create", env, fixture_dir)
    assert_true(status != 0)
    assert_eq(output, "")
    assert_false(errors.contains("private-argument-fixture"))
  }
  for
    pair in [
      ("create microsandbox VM: network: permission denied", "vm_network"),
      ("create microsandbox VM: mount: not found", "vm_mount"),
      ("prepare microsandbox final image: not found", "vm_image"),
    ] {
    let document : Json = {
      "devsy": {
        "connection": "ssh",
        "buildRef": "refs/heads/main",
        "command": [
          "/bin/sh",
          "-c",
          "printf '%s\\n' " + quote(pair.0) + "; exit 7",
        ],
      },
      "environmentRecipes": [{ "id": "test" }],
    }
    @fs.write_file(fixture_dir + "/orca.yaml", document.stringify())
    let (status, _, _) = invoke("create", env, fixture_dir)
    assert_true(status != 0)
    assert_true(
      @fs.read_file(fixture_dir + "/.local/state/orca-env-devsy/events.jsonl")
      .text()
      .contains("\"errorType\":\"" + pair.1 + "\""),
    )
  }
  let records = @fs.read_file(
    fixture_dir + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(records.contains("process-error"), msg=records)
  assert_true(records.contains("exit-error"))
  assert_true(records.contains("\"exitCode\":7"))
  assert_true(records.contains("resolve-context"))
  assert_true(records.contains("vm_create"))
  assert_false(records.contains("private-argument-fixture"))
  assert_true(records.contains("missing-command-fixture"))
}

///|
async test "proxy preserves binary streams and the configured command exit status" {
  let directory = @fs.tmpdir(prefix="orca-env-devsy-proxy-test")
  defer cleanup_fixture(directory)
  let input = b"\x00SSH\n\xff"
  @fs.write_file(directory + "/input", input)
  let state : Json = {
    "devsyEnv": {
      "HOME": directory,
      "XDG_STATE_HOME": directory + "/.local/state",
      "PATH": "/usr/bin:/bin",
    },
    "command": ["/bin/sh", "-c", "cat; exit \"$PROXY_EXIT\"", "sh"],
    "workspaceId": "test-id",
    "user": "developer",
  }
  for expected in [0, 37] {
    let (status, output, errors) = @process.collect_output(
      "/bin/sh",
      ["-c", "exec " + proxy(state, integration_binary())],
      extra_env={ "PATH": "/usr/bin:/bin", "PROXY_EXIT": expected.to_string() },
      inherit_env=false,
      cwd="/",
      stdin=@process.redirect_from_file(directory + "/input"),
    )
    assert_eq(status, expected, msg=errors.text())
    assert_eq(output.binary(), input)
  }
}

///|
async test "PATH executable beginning with a dash stays unchanged in direct and proxy calls" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let invocation = configured_launcher(directory)
  @fs.symlink(directory + "/bin/-launcher", target=invocation[0])
  invocation[0] = "-launcher"
  let document : Json = {
    "devsy": {
      "connection": "ssh",
      "buildRef": "refs/heads/main",
      "command": Json::array(invocation.map(Json::string)),
    },
    "environmentRecipes": [{ "id": "test" }],
  }
  @fs.write_file(directory + "/orca.yaml", document.stringify())
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  assert_eq(saved_command(state)[0], "-launcher")
  let before = @fs.read_file(directory + "/launcher-calls").text()
  let external_env = {
    "PATH": directory + "/bin:/usr/bin:/bin",
    "FAKE_HOME": directory,
  }
  let (status, _, errors) = @process.collect_output(
    "/usr/bin/ssh",
    [
      "-F",
      "/dev/null",
      "-o",
      "ConnectTimeout=2",
      "-o",
      "ProxyCommand=" + proxy(state, integration_binary()),
      "developer@devsy-workspace",
    ],
    extra_env=external_env,
    inherit_env=false,
    cwd="/",
  )
  assert_true(status != 0)
  assert_eq(
    @fs.read_file(directory + "/launcher-calls").text(),
    before + "ok\n",
    msg=errors.text(),
  )
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  let (status, _, errors) = invoke("destroy", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
}

///|
async test "destroy succeeds repeatedly after external deletion" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  @fs.remove(directory + "/created")
  for _ in 0..<2 {
    let (status, output, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_eq(output, "")
  }
  let (status, _, _) = invoke("resume", env, directory, payload~)
  assert_true(status != 0)
}

///|
fn fixture_shell_error(stderr : String) -> String {
  if stderr.to_lower().contains("text file busy") {
    "text_file_busy"
  } else {
    process_error_type(stderr)
  }
}

///|
test "shell fixture diagnostics retain categories without private output" {
  assert_eq(
    fixture_shell_error("/private/fixture/orca: Text file busy private-secret"),
    "text_file_busy",
  )
  assert_eq(fixture_shell_error("private-secret"), "process_exit")
}

///|
async test "existing Orca installation is validated and reused without downloading or replacing it" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let install = directory + "/.local/share/orca-env-devsy/orca/current"
  @fs.mkdir(install, recursive=true)
  @fs.write_file(
    directory + "/bin/uname",
    "#!/bin/sh\nif test \"$1\" = -s; then printf Linux; else printf x86_64; fi\n",
    permission=0o700,
  )
  @fs.write_file(
    directory + "/bin/curl",
    "#!/bin/sh\nexit 66\n",
    permission=0o700,
  )
  let executable = "#!/bin/sh\nprintf 'existing-version\\n'\n"
  @fs.write_file(install + "/orca-ide", executable, permission=0o700)
  let (status, _, errors) = @process.collect_output(
    "/bin/sh",
    ["-c", server_install_script()],
    extra_env=env,
    inherit_env=false,
  )
  assert_eq(status, 0, msg=fixture_shell_error(errors.text()))
  assert_eq(@fs.read_file(install + "/orca-ide").text(), executable)
  @fs.write_file(install + "/orca-ide", "#!/bin/sh\nexit 8\n", permission=0o700)
  let (status, _, errors) = @process.collect_output(
    "/bin/sh",
    ["-c", server_install_script()],
    extra_env=env,
    inherit_env=false,
  )
  assert_eq(status, 8, msg=fixture_shell_error(errors.text()))
  assert_true(@fs.exists(install + "/orca-ide"))
}

///|
async test "branch builds try shallow and retry only a missing pinned commit with full clone" {
  for failure in ["missing", "missing-full", "other", "none"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    @fs.rename(directory + "/bin/devsy", directory + "/bin/devsy-original")
    let wrapper =
      #|#!/bin/sh
      #|set -eu
      #|case "$*" in
      #| *--git-clone-strategy=shallow*)
      #|   printf '%s\n' "$@" >> "$HOME/shallow-args"
      #|   if test "$CLONE_FAILURE" = missing || test "$CLONE_FAILURE" = missing-full; then
      #|     printf '%s\n' "{\"kind\":\"status\",\"phase\":\"cloning_repository\",\"state\":\"failed\",\"error\":{\"message\":\"Could not parse object 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\"}}"
      #|     printf '\377 non-UTF-8 private-stderr-secret\n' >&2
      #|     exit 1
      #|   fi
      #|   if test "$CLONE_FAILURE" = other; then exit 3; fi ;;
      #|esac
      #|if test "$CLONE_FAILURE" = missing-full; then
      #|  case "$*" in *'workspace up'*) exit 9 ;; esac
      #|fi
      #|exec "$HOME/bin/devsy-original" "$@"
    @fs.write_file(directory + "/bin/devsy", wrapper + "\n", permission=0o700)
    env.set("CLONE_FAILURE", failure)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: 'refs/heads/main'}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(
      status == 0,
      failure != "other" && failure != "missing-full",
      msg="clone scenario \{failure}: \{errors}",
    )
    let records = fixture_events(directory)
    if failure == "missing" || failure == "missing-full" {
      let fallback = field(create_event(records, "clone-fallback"), "source").unwrap()
      assert_eq(
        field(fallback, "fallbackReason"),
        Some(Json::string("missing-shallow-commit")),
      )
      assert_eq(field(fallback, "sourceKind"), Some(Json::string("commit")))
      assert_eq(field(fallback, "cloneStrategy"), Some(Json::string("full")))
    }
    let shallow = @fs.read_file(directory + "/shallow-args").text()
    assert_true(shallow.contains("https://example.com/repo.git@main\n"))
    assert_true(shallow.contains("--git-clone-strategy=shallow\n"))
    let full = @fs.read_file(directory + "/args").text()
    assert_eq(full.contains("--git-clone-strategy=\n"), failure == "missing")
    if failure == "missing-full" {
      assert_eq(
        field(create_event(records, "create-attempt"), "status"),
        Some(Json::string("failed")),
      )
    }
    if status == 0 {
      let payload : Json = {
        "schemaVersion": 1,
        "recipeResult": @json.parse(output),
      }
      let (status, _, errors) = invoke("destroy", env, directory, payload~)
      assert_eq(status, 0, msg=errors)
    }
  }
}

///|
test "checkout input validation preserves supported user names and rejects control characters" {
  assert_true(valid_user("developer$"))
  assert_true(valid_user("_service"))
  assert_false(valid_user("-option"))
  assert_false(valid_user("123"))
  assert_false(valid_workspace_id("-bad"))
  assert_eq(shallow_branch("refs/heads/main"), Some("main"))
  assert_eq(shallow_branch("refs/tags/v1"), None)
  assert_eq(shallow_branch("HEAD"), None)
  assert_eq(shallow_branch("refs/heads/pull/123/head"), None)
  assert_eq(shallow_branch("refs/heads/merge-requests/123/head"), None)
}

///|
async test "invalid provisioned branch is rejected before Devsy" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  // Exercise Git's own reference grammar, not a permissive fixture.
  @fs.write_file(
    directory + "/bin/git",
    "#!/bin/sh\nexec /usr/bin/git \"$@\"\n",
    permission=0o700,
  )
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test, checkoutMode: provisioned-root}]\n",
  )
  env.set("ORCA_REPO_REF_HEAD", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  for branch in ["-option", "bad..branch", "bad\nbranch", "refs@{bad"] {
    env.set("ORCA_REPO_BRANCH", branch)
    let (status, _, _) = invoke("create", env, directory)
    assert_true(status != 0)
    assert_false(@fs.exists(directory + "/args"))
  }
}

///|
fn synthetic_auth(expiry : Double) -> Json {
  let claims : Json = { "exp": expiry }
  let token = "fixture." +
    @base64.encode(@utf8.encode(claims.stringify())) +
    ".signature"
  {
    "auth_mode": "chatgpt",
    "tokens": {
      "access_token": token,
      "account_id": "fixture-account",
      "refresh_token": "fixture-refresh",
    },
  }
}

///|
async fn fake_codex(directory : String) -> Unit {
  let script =
    #|#!/bin/sh
    #|set -eu
    #|test "$1" = app-server && test "$2" = --stdio
    #|IFS= read -r initialize
    #|case "$initialize" in *'"initialize"'*) : ;; *) exit 2 ;; esac
    #|printf '{"id":1,"result":{}}\n'
    #|IFS= read -r initialized
    #|case "$initialized" in *'"initialized"'*) : ;; *) exit 2 ;; esac
    #|IFS= read -r request
    #|case "$request" in *'"account/read"'*'"refreshToken":true'*) : ;; *) exit 2 ;; esac
    #|printf 'refresh\n' >> "$CODEX_HOME/refresh-count"
    #|if test -f "$CODEX_HOME/fail-refresh"; then printf '{"id":2,"error":{"message":"refresh service unavailable"}}\n'; exit 1; fi
    #|sleep 0.1
    #|cp "$CODEX_HOME/next-auth.json" "$CODEX_HOME/auth.json"
    #|printf '{"method":"account/updated","params":{}}\n{"id":2,"result":{}}\n'
    #|cat >/dev/null
  @fs.write_file(directory + "/bin/codex", script + "\n", permission=0o700)
}

///|
async test "near-expiry Codex auth refreshes once across concurrent creates and forwards only renewed access data" {
  let (first, env1) = fixture()
  defer cleanup_fixture(first)
  let (second, env2) = fixture()
  defer cleanup_fixture(second)
  @fs.mkdir(first + "/.codex")
  let initial = synthetic_auth(@env.now().to_double() / 1000 + 60)
  let renewed = synthetic_auth(@env.now().to_double() / 1000 + 1209600)
  @fs.write_file(first + "/.codex/auth.json", initial.stringify())
  @fs.write_file(first + "/.codex/next-auth.json", renewed.stringify())
  env2.set("CODEX_HOME", first + "/.codex")
  for directory in [first, second] {
    fake_codex(directory)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: refs/heads/main, addons: {codexAuth: true}}\nenvironmentRecipes: [{id: test}]\n",
    )
  }
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() { invoke("create", env1, first) })
    let (status2, output2, errors2) = invoke("create", env2, second)
    let (status1, output1, errors1) = task.wait()
    assert_eq(status1, 0, msg=errors1)
    assert_eq(status2, 0, msg=errors2)
    for directory in [first, second] {
      let delivered = @json.parse(
        @fs.read_file(directory + "/delivered-auth").text(),
      )
      assert_eq(
        field(field(delivered, "tokens").unwrap(), "access_token"),
        field(field(renewed, "tokens").unwrap(), "access_token"),
      )
      assert_eq(
        field(field(delivered, "tokens").unwrap(), "refresh_token"),
        Some(Json::string("")),
      )
      let logs = @fs.read_file(
        directory + "/.local/state/orca-env-devsy/events.jsonl",
      ).text()
      assert_false(logs.contains("fixture-refresh"))
      assert_false(
        logs.contains(
          required(field(renewed, "tokens").unwrap(), "access_token"),
        ),
      )
    }
    assert_false(
      (output1 + output2 + errors1 + errors2).contains("fixture-refresh"),
    )
  })
  assert_eq(@fs.read_file(first + "/.codex/refresh-count").text(), "refresh\n")
}

///|
async test "failed refresh forwards an unexpired short token but never an expired one" {
  for expired in [false, true] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    @fs.mkdir(directory + "/.codex")
    let auth = synthetic_auth(
      @env.now().to_double() / 1000 + (if expired { -60 } else { 60 }),
    )
    @fs.write_file(directory + "/.codex/auth.json", auth.stringify())
    @fs.write_file(directory + "/.codex/fail-refresh", "")
    fake_codex(directory)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: refs/heads/main, addons: {codexAuth: true}}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, _, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_true(errors.contains("refresh failed"))
    assert_true(errors.contains("refresh service unavailable"), msg=errors)
    assert_true(
      @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl")
      .text()
      .contains("refresh service unavailable"),
    )
    assert_eq(@fs.exists(directory + "/delivered-auth"), !expired)
  }
}

///|
async test "RPC failure replaces the primary and transient failure preserves it" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let worker = required(state, "tunnelDirectory")
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    let before = @fs.read_file(directory + "/master-pid").text()
    @fs.write_file(directory + "/flaky-ready", "")
    let (status, _, errors) = invoke("recover", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_eq(@fs.read_file(directory + "/master-pid").text(), before)
    @fs.write_file(directory + "/rpc-unavailable", "")
    @fs.write_file(directory + "/recover-on-master", "")
    @fs.write_file(directory + "/daemon-instance-stale", "")
    let (status, _, errors) = invoke("recover", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_false(@fs.exists(directory + "/daemon-instance-stale"))
    assert_true(@fs.read_file(directory + "/master-pid").text() != before)
    assert_true(worker_alive(worker))
    let events = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(events.contains("http_503"))
    assert_true(events.contains("\"attempt\":2"))
    assert_false(events.contains("fixture-instance"))
  })
}

///|
async test "delayed primary Git readiness does not start a competing services owner" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(directory + "/git-unavailable", "")
    @fs.write_file(directory + "/git-invalid-stderr", "")
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = @async.with_task_group(async fn(group) {
      group.spawn_bg(async fn() {
        while !@fs.exists(directory + "/git-probed") {
          @async.sleep(10)
        }
        @async.sleep(3000)
        if @fs.exists(directory + "/git-unavailable") {
          @fs.remove(directory + "/git-unavailable")
        }
      })
      invoke("create", env, directory)
    })
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    assert_eq(@fs.read_file(directory + "/primary-services").text(), "enabled")
    let events = fixture_events(directory)
    let pending = events.filter(event => {
      field(event, "stage") == Some(Json::string("relay-probe")) &&
      field(event, "errorType") == Some(Json::string("git_helper_unavailable"))
    })
    assert_true(pending.length() > 0)
    assert_eq(field(pending[0], "exitCode"), Some(Json::number(1)))
    assert_true(required(pending[0], "errorMessage").contains("helper pending"))
    let state = field(result, "userData").unwrap()
    assert_eq(
      @fs.read_file(required(state, "tunnelDirectory") + "/git-status").text(),
      "ready",
    )
  })
}

///|
async test "disabled Git forwarding still requires RPC readiness" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("FAKE_GIT_FORWARDING", "false")
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    assert_eq(@fs.read_file(directory + "/primary-services").text(), "enabled")
    assert_false(@fs.exists(directory + "/git-probed"))
    assert_true(@fs.exists(directory + "/relay-probed"))
  })
}

///|
async test "tunnel worker recovers on the same port and remains running when stop or delete fails" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let worker = required(state, "tunnelDirectory")
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    assert_true(worker_alive(worker))
    let port = @fs.read_file(directory + "/listener-port").text()
    let before = @fs.read_file(directory + "/ssh-args")
      .text()
      .split("-L\n")
      .count()
    @fs.write_file(directory + "/drop-tunnel", "")
    @async.with_timeout(10000, async fn() {
      while @fs.read_file(directory + "/ssh-args").text().split("-L\n").count() <=
            before {
        @async.sleep(100)
      }
    })
    let (status, _, errors) = invoke("recover", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_eq(@fs.read_file(directory + "/listener-port").text(), port)
    let records = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(records.contains("authentication_failed"))
    assert_true(records.contains("retryDelayMs"))
    assert_true(records.contains("attempt"))
    assert_false(records.contains("private-stderr-secret"))
    for pair in [("suspend", "fail-stop"), ("destroy", "fail-delete")] {
      let (mode, marker) = pair
      @fs.write_file(directory + "/" + marker, "")
      let (status, _, _) = invoke(mode, env, directory, payload~)
      assert_true(status != 0)
      assert_true(worker_alive(worker))
      assert_true(@fs.exists(worker + "/enabled"))
      let (status, _, errors) = invoke("recover", env, directory, payload~)
      assert_eq(status, 0, msg=errors)
      @fs.remove(directory + "/" + marker)
    }
    @fs.remove(directory + "/created")
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_false(@fs.exists(worker))
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  })
}

///|
async test "short tag build refs use full clones including annotated tag peeling" {
  for annotated in [false, true] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    let script = if annotated {
      "#!/bin/sh\nprintf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\\trefs/tags/v1.0.0\\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\trefs/tags/v1.0.0^{}\\n'\n"
    } else {
      "#!/bin/sh\nprintf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\trefs/tags/v1.0.0\\n'\n"
    }
    @fs.write_file(directory + "/bin/git", script, permission=0o700)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: v1.0.0}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let args = @fs.read_file(directory + "/args").text()
    assert_true(args.contains("--git-clone-strategy=\n"))
    assert_false(args.contains("--git-clone-strategy=shallow"))
    let payload : Json = {
      "schemaVersion": 1,
      "recipeResult": @json.parse(output),
    }
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  }
}

///|
async test "automatic tunnel recovery refuses a replacement workspace UID" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let worker = required(field(result, "userData").unwrap(), "tunnelDirectory")
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    let uid = @fs.read_file(directory + "/uid").text()
    defer @fs.write_file(directory + "/uid", uid)
    defer ignore(invoke("destroy", env, directory, payload~))
    let before = @fs.read_file(directory + "/ssh-args")
      .text()
      .split("-L\n")
      .count()
    @fs.write_file(directory + "/uid", "replacement-uid")
    @fs.write_file(directory + "/drop-tunnel", "")
    @async.with_timeout(10000, async fn() {
      while worker_alive(worker) {
        @async.sleep(100)
      }
    })
    assert_false(@fs.exists(worker + "/enabled"))
    assert_eq(
      @fs.read_file(directory + "/ssh-args").text().split("-L\n").count(),
      before,
    )
    @fs.write_file(directory + "/uid", uid)
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  })
}

///|
async test "remote user and workspace folder validation rejects malformed metadata and permits service users" {
  for
    pair in [
      ("developer", Json::string("")),
      ("developer", Json::null()),
      ("developer", Json::string("relative")),
      ("developer", Json::string("/path\rname")),
      ("developer", Json::string("/path\nname")),
      ("developer", Json::number(4)),
      ("123", Json::string("/workspace/repo")),
      ("developer$", Json::string("/workspace/repo")),
    ] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    let (user, folder) = pair
    let result : Json = {
      "kind": "result",
      "outcome": "success",
      "remoteUser": user,
      "remoteWorkspaceFolder": folder,
    }
    @fs.write_file(directory + "/up-result", result.stringify() + "\n")
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, _) = invoke("create", env, directory)
    assert_eq(status == 0, user == "developer$")
    if status == 0 {
      let payload : Json = {
        "schemaVersion": 1,
        "recipeResult": @json.parse(output),
      }
      let (status, _, errors) = invoke("destroy", env, directory, payload~)
      assert_eq(status, 0, msg=errors)
    } else {
      assert_false(@fs.exists(directory + "/created"))
    }
  }
}

///|
async test "create uses the Devsy workspace folder without an SSH root probe" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let folder = "/workspace/repo/sub dir's $(literal)"
  let result : Json = {
    "kind": "result",
    "outcome": "success",
    "remoteUser": "developer",
    "remoteWorkspaceFolder": folder,
  }
  @fs.write_file(directory + "/up-result", result.stringify() + "\n")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let recipe = @json.parse(output)
  let payload : Json = { "schemaVersion": 1, "recipeResult": recipe }
  defer ignore(invoke("destroy", env, directory, payload~))
  assert_eq(
    field(field(recipe, "userData").unwrap(), "projectRoot"),
    Some(Json::string(folder)),
  )
  let ssh = @fs.read_file(directory + "/ssh-args").text()
  assert_false(ssh.contains("pwd -P"))
  assert_false(ssh.contains("--show-toplevel"))
  assert_true(ssh.contains("git -C " + quote(folder) + " rev-parse HEAD"))
}

///|
async test "server create returns recipe JSON while the tunnel child retains stderr" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(directory + "/keep-proxy-stderr", "")
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    @fs.write_file(directory + "/hold-proxy-setup", "")
    let ((status, output, errors), premature_check) = @async.with_timeout(
      15000,
      async fn() {
        @async.with_task_group(async fn(group) {
          let creation = group.spawn(async fn() {
            invoke("create", env, directory)
          })
          defer (@fs.remove(directory + "/hold-proxy-setup") catch { _ => () })
          while !@fs.exists(directory + "/listener-ready") {
            @async.sleep(10)
          }
          let base = directory + "/.local/state/orca-env-devsy/tunnels"
          let saved = @json.parse(
            @fs.read_file(base + "/" + @fs.readdir(base)[0] + "/state.json").text(),
          )
          let (check, _, _) = @process.collect_output(
            directory + "/bin/ssh",
            [
              "-S",
              required(saved, "socketDirectory") + "/socket",
              "-O",
              "check",
            ],
            extra_env=env,
          )
          @fs.remove(directory + "/hold-proxy-setup")
          let result = creation.wait()
          (result, check)
        })
      },
    )
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    assert_true(premature_check != 0)
    assert_eq(
      field(field(result, "connection").unwrap(), "type"),
      Some(Json::string("orca-server")),
    )
    assert_true(worker_alive(required(state, "tunnelDirectory")))
    let pid = @fs.read_file(directory + "/keeper-pid").text().trim().to_owned()
    assert_eq(@process.run("kill", ["-0", pid]), 0)
    let (status, _, errors) = invoke("suspend", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    let (status, _, _) = @process.collect_output("kill", ["-0", pid])
    assert_true(status != 0)
  })
}

///|
async test "destroy cancels and reaps a blocked worker UID query" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer (@fs.remove(directory + "/block-list") catch { _ => () })
    defer close_tunnel(state)
    @fs.write_file(directory + "/block-list", "")
    @fs.write_file(directory + "/drop-tunnel", "")
    @async.with_timeout(10000, async fn() {
      while !@fs.exists(directory + "/blocked-list-pid") {
        @async.sleep(100)
      }
    })
    let pid = @fs.read_file(directory + "/blocked-list-pid")
      .text()
      .trim()
      .to_owned()
    // The foreground lifecycle query must succeed while the worker's query stays
    // blocked; emulate that independent process after it has entered its loop.
    @fs.remove(directory + "/block-list")
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    let (status, _, _) = @process.collect_output("kill", ["-0", pid])
    assert_true(status != 0)
    assert_false(@fs.exists(required(state, "tunnelDirectory")))
  })
}

///|
async test "resume reuses a Server that survives suspension instead of starting a duplicate" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(directory + "/reuse-running-server", "")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let mut recipe = Json::null()
  with_fake_tunnel(directory, async fn() {
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    recipe = @json.parse(output)
    let payload : Json = { "schemaVersion": 1, "recipeResult": recipe }
    let (status, _, errors) = invoke("suspend", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  })
  @fs.write_file(directory + "/ssh-args", "")
  with_fake_tunnel(directory, async fn() {
    let payload : Json = { "schemaVersion": 1, "recipeResult": recipe }
    let (status, output, errors) = invoke("resume", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    let resumed = @json.parse(output)
    assert_eq(field(resumed, "connection"), field(recipe, "connection"))
    let args = @fs.read_file(directory + "/ssh-args").text()
    assert_false(args.contains("--recipe-json"))
    let payload : Json = { "schemaVersion": 1, "recipeResult": resumed }
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  })
}

///|
async test "Server loopback health probe ignores ambient curl proxy configuration" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let curl =
    #|#!/bin/sh
    #|test "$1" = --disable || exit 1
    #|test "$2" = --noproxy && test "$3" = '*' || exit 1
    #|test -n "$http_proxy" && test -n "$ALL_PROXY" || exit 1
    #|printf 101
  @fs.write_file(directory + "/bin/curl", curl + "\n", permission=0o700)
  env.set("http_proxy", "http://127.0.0.1:1")
  env.set("ALL_PROXY", "http://127.0.0.1:1")
  env.set("NO_PROXY", "")
  let (status, output, _) = @process.collect_output(
    "/bin/sh",
    ["-c", server_probe_script()],
    extra_env=env,
    inherit_env=false,
  )
  assert_eq(status, 0)
  assert_eq(output.text(), "101")
}

///|
async test "failed create still deletes workspace when tunnel state cleanup fails" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    @fs.write_file(directory + "/fail-tunnel-cleanup", "")
    defer @async.protect_from_cancel(async fn() {
      let base = directory + "/.local/state/orca-env-devsy/tunnels"
      if @fs.exists(base) {
        for name in @fs.readdir(base) {
          let worker = base + "/" + name
          if @fs.exists(worker + "/state.json") {
            @fs.remove(worker + "/state.json")
          }
          if @fs.exists(worker + "/enabled") {
            @fs.remove(worker + "/enabled")
          }
          @async.with_timeout(5000, async fn() {
            while worker_alive(worker) {
              @async.sleep(100)
            }
          })
        }
      }
      if @fs.exists(directory + "/ssh-args") {
        for arg in @fs.read_file(directory + "/ssh-args").text().split("\n") {
          if arg.has_suffix("/socket") {
            let socket_directory = arg
              .to_owned()
              .replace_all(old="/socket", new="")
            if @fs.exists(socket_directory) {
              @fs.rmdir(socket_directory, recursive=true)
            }
          }
        }
      }
    })
    let (status, output, errors) = invoke("create", env, directory)
    assert_true(status != 0)
    assert_eq(output, "")
    assert_true(errors.contains("continuing workspace deletion"))
    assert_false(@fs.exists(directory + "/created"))
    let args = @fs.read_file(directory + "/ssh-args")
      .text()
      .split("\n")
      .to_array()
    let sockets = args.filter(arg => arg.has_suffix("/socket"))
    assert_true(sockets.length() > 0)
    let records = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(records.contains("create-cleanup-tunnel"))
    assert_true(records.contains("tunnel_cleanup"))
    assert_true(records.contains("create-cleanup"))
  })
}

///|
async test "diagnostics retain backend phases and fixed failure classes" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let result =
    #|{"kind":"status","phase":"cloning_repository","state":"started","step":"private-step-secret"}
    #|{"kind":"status","phase":"building_image","state":"failed","error":{"message":"private-error-secret","context":{"token":"private-context-secret"}}}
    #|{"kind":"status","phase":"new_backend_phase","state":"waiting"}
    #|{"kind":"result","outcome":"success","remoteUser":"developer","remoteWorkspaceFolder":"/workspace/repo"}
  @fs.write_file(directory + "/up-result", result + "\n")
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let receipt = @json.parse(output)
  let payload : Json = { "schemaVersion": 1, "recipeResult": receipt }
  defer ignore(invoke("destroy", env, directory, payload~))
  let path = directory + "/.local/state/orca-env-devsy/events.jsonl"
  let records = @fs.read_file(path).text()
  assert_true(records.contains("cloning_repository"))
  assert_true(records.contains("building_image"))
  assert_true(records.contains("new_backend_phase"))
  assert_true(records.contains("waiting"))
  assert_true(records.contains("backend_phase"))
  assert_true(records.contains("durationMs"))
  assert_false(records.contains("private-"))
  env.set("ORCA_ENV_DEVSY_RECORDING", "0")
  @fs.write_file(directory + "/resume-input.json", payload.stringify())
  @async.with_task_group(async fn(group) {
    let sink = @process.redirect_to_file("/dev/null", shared=true)
    defer sink.close()
    let errors = @process.redirect_to_file(
      directory + "/resume-errors",
      shared=true,
    )
    defer errors.close()
    let child = @process.spawn(
      group,
      integration_binary(),
      ["recipe", "resume"],
      extra_env=env,
      stdin=@process.redirect_from_file(directory + "/resume-input.json"),
      stdout=sink,
      stderr=errors,
    )
    let run_suffix = "_" + child.pid.to_string()
    assert_eq(
      child.wait(),
      0,
      msg=@fs.read_file(directory + "/resume-errors").text(),
    )
    assert_false(
      fixture_events(directory)
      .iter()
      .any(event => {
        field(event, "runId") is Some(Json::String(id)) &&
        id.has_suffix(run_suffix)
      }),
    )
  })
  env.remove("ORCA_ENV_DEVSY_RECORDING")
  @fs.remove(path)
  @fs.mkdir(path)
  let (status, _, errors) = invoke("resume", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
}

///|
async test "binary stderr never changes command failure with recording enabled or disabled" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let document : Json = {
    "devsy": {
      "connection": "ssh",
      "buildRef": "refs/heads/main",
      "command": [
        "/bin/sh", "-c", "printf '\\377 Permission denied (publickey). private-binary-secret\\n' >&2; exit 7",
        "sh",
      ],
    },
    "environmentRecipes": [{ "id": "test" }],
  }
  @fs.write_file(directory + "/orca.yaml", document.stringify())
  for enabled in ["1", "0"] {
    env.set("ORCA_ENV_DEVSY_RECORDING", enabled)
    let (status, output, errors) = invoke("create", env, directory)
    assert_true(status != 0)
    assert_eq(output, "")
    assert_true(errors.contains("resolve-context failed (exit 7)"))
    assert_false(errors.contains("private-binary-secret"))
  }
  let records = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(records.contains("authentication_failed"))
  assert_true(records.contains("\"exitCode\":7"))
  assert_false(records.contains("private-binary-secret"))
}

///|
async test "restart replaces live connections through bulk and receipt recover" {
  for connection in ["ssh", "orca-server"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    with_fake_tunnel(directory, async fn() {
      @fs.write_file(
        directory + "/orca.yaml",
        "devsy: {connection: " +
        connection +
        ", buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
      )
      let (status, output, errors) = invoke("create", env, directory)
      assert_eq(status, 0, msg=errors)
      let result = @json.parse(output)
      let state = field(result, "userData").unwrap()
      let worker = required(state, "tunnelDirectory")
      let payload : Json = { "schemaVersion": 1, "recipeResult": result }
      defer ignore(invoke("destroy", env, directory, payload~))
      @fs.write_file(directory + "/orca.yaml", "invalid: [")
      for receipt in [false, true] {
        let before = @json.parse(@fs.read_file(worker + "/state.json").text())
        let pid = @fs.read_file(directory + "/master-pid")
          .text()
          .trim()
          .to_owned()
        assert_true(worker_alive(worker))
        @fs.write_file(directory + "/args", "")
        @fs.write_file(directory + "/ssh-args", "")
        let (status, output, errors) = invoke(
          "restart",
          env,
          directory,
          payload?=if receipt { Some(payload) } else { None },
        )
        assert_eq(status, 0, msg=errors)
        if receipt {
          let restarted = @json.parse(output)
          assert_eq(field(restarted, "connection"), field(result, "connection"))
          assert_eq(field(restarted, "userData"), Some(state))
        } else {
          assert_eq(output, "")
        }
        assert_true(worker_alive(worker))
        assert_true(@fs.exists(worker + "/enabled"))
        let after = @json.parse(@fs.read_file(worker + "/state.json").text())
        assert_eq(field(after, "localPort"), field(before, "localPort"))
        assert_true(
          @fs.read_file(directory + "/master-pid").text().trim() != pid,
        )
        let (alive, _, _) = @process.collect_output("kill", ["-0", pid])
        assert_true(alive != 0)
        let commands = @fs.read_file(directory + "/args").text()
        for operation in ["up", "stop", "delete"] {
          assert_false(commands.contains("workspace\n" + operation + "\n"))
        }
        assert_false(
          @fs.read_file(directory + "/ssh-args")
          .text()
          .contains("--recipe-json"),
        )
      }
      let records = @fs.read_file(
        directory + "/.local/state/orca-env-devsy/events.jsonl",
      ).text()
      assert_true(records.contains("\"stage\":\"ssh-tunnel-restart\""))
      assert_true(records.contains("\"tunnelDirectory\":\"" + worker))
    })
  }
}

///|
async test "restart refuses an SSH master that does not stop and preserves saved state" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  let worker = required(state, "tunnelDirectory")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  defer ignore(invoke("destroy", env, directory, payload~))
  @fs.remove(worker + "/enabled")
  @async.with_timeout(5000, async fn() {
    while worker_alive(worker) {
      @async.sleep(10)
    }
  })
  let saved = @fs.read_file(worker + "/state.json").text()
  let socket = required(@json.parse(saved), "socketDirectory")
  @fs.mkdir(socket, permission=0o700, allow_exist=true)
  @fs.write_file(socket + "/socket", "")
  @fs.write_file(worker + "/enabled", "")
  @fs.rename(directory + "/bin/ssh", directory + "/bin/ssh-original")
  let wrapper =
    #|#!/bin/sh
    #|case "$*" in *'-O exit'*) exit 1 ;; esac
    #|exec "$HOME/bin/ssh-original" "$@"
  @fs.write_file(directory + "/bin/ssh", wrapper + "\n", permission=0o700)
  @fs.write_file(directory + "/ssh-args", "")
  let (status, _, _) = invoke("restart", env, directory)
  assert_true(status != 0)
  assert_false(worker_alive(worker))
  assert_true(@fs.exists(worker + "/enabled"))
  assert_eq(@fs.read_file(worker + "/state.json").text(), saved)
  assert_false(@fs.read_file(directory + "/ssh-args").text().contains("-N\n"))
  let events = fixture_events(directory).filter(event => {
    field(event, "stage") == Some(Json::string("ssh-tunnel-restart"))
  })
  let failure = events.last().unwrap()
  assert_eq(field(failure, "status"), Some(Json::string("timeout")))
  assert_eq(field(failure, "errorType"), Some(Json::string("shutdown_timeout")))
  assert_eq(field(failure, "phase"), Some(Json::string("master")))
  assert_eq(field(failure, "tunnelDirectory"), Some(Json::string(worker)))
  assert_eq(field(failure, "runId"), field(events[0], "runId"))
  @fs.rename(directory + "/bin/ssh-original", directory + "/bin/ssh")
  let (status, _, errors) = invoke("restart", env, directory)
  assert_eq(status, 0, msg=errors)
  assert_true(worker_alive(worker))
}

///|
async test "receipt restart stops legacy masters without worker state" {
  for external in [false, true] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let worker = required(state, "tunnelDirectory")
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    @fs.remove(worker + "/enabled")
    @async.with_timeout(5000, async fn() {
      while worker_alive(worker) {
        @async.sleep(10)
      }
    })
    let legacy = if external { directory + "/legacy" } else { worker }
    @fs.mkdir(legacy, allow_exist=true)
    if !external {
      @fs.remove(worker + "/state.json")
    }
    let legacy_result = @json.parse(output)
    set_field(
      field(legacy_result, "userData").unwrap(),
      "tunnelDirectory",
      Json::string(legacy),
    )
    @fs.write_file(legacy + "/socket", "")
    @fs.write_file(directory + "/ssh-args", "")
    let (status, output, errors) = invoke("restart", env, directory, payload={
      "schemaVersion": 1,
      "recipeResult": legacy_result,
    })
    assert_eq(status, 0, msg=errors)
    assert_false(@fs.exists(legacy + "/socket"))
    let args = @fs.read_file(directory + "/ssh-args").text()
    assert_true(args.contains("-O\nexit\n"))
    let restarted = @json.parse(output)
    let restarted_worker = required(
      field(restarted, "userData").unwrap(),
      "tunnelDirectory",
    )
    assert_true(worker_alive(restarted_worker))
    let (status, _, errors) = invoke("destroy", env, directory, payload={
      "schemaVersion": 1,
      "recipeResult": restarted,
    })
    assert_eq(status, 0, msg=errors)
  }
}

///|
async test "bulk recover restores persistent XDG state without a receipt or current YAML" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("XDG_STATE_HOME", directory + "/xdg-state")
  with_fake_tunnel(directory, async fn() {
    let document : Json = {
      "devsy": {
        "connection": "orca-server",
        "buildRef": "refs/heads/main",
        "command": Json::array(configured_launcher(directory).map(Json::string)),
      },
      "environmentRecipes": [{ "id": "test" }],
    }
    @fs.write_file(directory + "/orca.yaml", document.stringify())
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let receipt = @json.parse(output)
    let state = field(receipt, "userData").unwrap()
    let worker = required(state, "tunnelDirectory")
    assert_true(
      worker.has_prefix(directory + "/xdg-state/orca-env-devsy/tunnels/"),
    )
    let payload : Json = { "schemaVersion": 1, "recipeResult": receipt }
    defer ignore(invoke("destroy", env, directory, payload~))
    let before = @json.parse(@fs.read_file(worker + "/state.json").text())
    assert_false(before.stringify().contains("fixture-pairing"))
    @fs.remove(worker + "/enabled")
    @async.with_timeout(5000, async fn() {
      while worker_alive(worker) {
        @async.sleep(100)
      }
    })
    if @fs.exists(required(before, "socketDirectory")) {
      @fs.rmdir(required(before, "socketDirectory"), recursive=true)
    }
    @fs.write_file(worker + "/enabled", "")
    @fs.write_file(directory + "/orca.yaml", "invalid: [")
    let (status, output, errors) = invoke("recover", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_eq(output, "")
    let after = @json.parse(@fs.read_file(worker + "/state.json").text())
    assert_eq(field(after, "localPort"), field(before, "localPort"))
    assert_eq(field(after, "command"), field(before, "command"))
    assert_true(worker_alive(worker))
    let (status, output, errors) = invoke("recover", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_eq(output, "")
    assert_eq(@json.parse(@fs.read_file(worker + "/state.json").text()), after)
    let (status, _, errors) = invoke("suspend", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_true(worker_alive(worker))
    let (status, output, errors) = invoke("recover", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_eq(output, "")
  })
}

///|
async test "bulk recovery skips disabled and stopped workspaces and reports replaced or corrupt entries" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let receipt = @json.parse(output)
    let state = field(receipt, "userData").unwrap()
    let worker = required(state, "tunnelDirectory")
    let payload : Json = { "schemaVersion": 1, "recipeResult": receipt }
    defer ignore(invoke("destroy", env, directory, payload~))
    @fs.remove(worker + "/enabled")
    @async.with_timeout(5000, async fn() {
      while worker_alive(worker) {
        @async.sleep(100)
      }
    })
    let base = directory + "/.local/state/orca-env-devsy/tunnels"
    @fs.mkdir(base + "/disabled")
    @fs.write_file(base + "/disabled/state.json", "{invalid")
    let (status, _, errors) = invoke("recover", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_false(worker_alive(worker))
    @fs.write_file(worker + "/enabled", "")
    @fs.write_file(directory + "/stopped", "")
    let args = @fs.read_file(directory + "/ssh-args").text()
    let (status, _, errors) = invoke("recover", env, directory)
    assert_eq(status, 0, msg=errors)
    let after = @fs.read_file(directory + "/ssh-args").text()
    assert_eq(after.split("-M\n").count(), args.split("-M\n").count())
    assert_true(@fs.exists(directory + "/stopped"))
    assert_false(worker_alive(worker))
    let (status, _, errors) = invoke("restart", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_true(errors.contains("workspace stopped; recovery skipped"))
    assert_true(@fs.exists(directory + "/stopped"))
    assert_false(worker_alive(worker))
    @fs.remove(directory + "/stopped")
    @fs.mkdir(base + "/blocked")
    let blocked = @json.parse(@fs.read_file(worker + "/state.json").text())
    set_field(blocked, "command", ["/bin/sh", "-c", "exec sleep 60", "sh"])
    @fs.write_file(base + "/blocked/state.json", blocked.stringify())
    @fs.write_file(
      base + "/blocked/environment.json",
      @fs.read_file(worker + "/environment.json").text(),
      permission=0o600,
    )
    @fs.write_file(base + "/blocked/enabled", "")
    @fs.mkdir(base + "/corrupt")
    @fs.write_file(base + "/corrupt/enabled", "")
    @fs.write_file(base + "/corrupt/state.json", "{invalid")
    let (status, _, errors) = invoke("recover", env, directory)
    assert_true(status != 0)
    assert_true(worker_alive(worker), msg=errors)
    @fs.remove(base + "/blocked/enabled")
    @fs.remove(base + "/corrupt/enabled")
    @fs.write_file(worker + "/enabled", "")
    let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
    set_field(saved, "workspaceUid", Json::string("replaced-fixture-uid"))
    // Use a separate inactive entry, leaving the live test worker owned by its receipt.
    @fs.mkdir(base + "/replaced")
    @fs.write_file(base + "/replaced/state.json", saved.stringify())
    @fs.write_file(
      base + "/replaced/environment.json",
      @fs.read_file(worker + "/environment.json").text(),
      permission=0o600,
    )
    @fs.write_file(base + "/replaced/enabled", "")
    let (status, _, errors) = invoke("recover", env, directory)
    assert_true(status != 0, msg=errors)
    assert_false(worker_alive(base + "/replaced"))
  })
}

///|
async test "lifecycle progress reaches stderr and diagnostics before workspace up completes" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  env.set("CUSTOM_SERVICE_TOKEN", "fixture-private-credential")
  @fs.rename(directory + "/bin/devsy", directory + "/bin/devsy-original")
  let wrapper =
    #|#!/bin/sh
    #|set -eu
    #|case "$*" in
    #| *'workspace up'*)
    #|   printf '%s\n' '{"kind":"status","operationId":"build-1","phase":"building_image","state":"started"}'
    #|   printf '%s\n' '{"level":"debug","msg":"#7 [stage 2/3] RUN install dependencies"}' >&2
    #|   printf '%s\n' '{"level":"debug","msg":"#7 [stage 2/3] RUN install dependencies"}' >&2
    #|   printf '%s\n' '{"level":"debug","msg":"#7 0.13 hidden-run-output"}' '{"level":"debug","msg":"hidden-debug-output"}' '{"level":"trace","msg":"hidden-trace-output"}' >&2
    #|   printf '%s\n' '{"level":"debug","msg":"#7 DONE 0.4s"}' '{"level":"debug","msg":"#8 CACHED"}' '{"level":"info","msg":"Step 3/4 : COPY . /app"}' >&2
    #|   printf '%s\n' '{"kind":"status","operationId":"build-1","phase":"building_image","state":"succeeded","durationMs":1234}'
    #|   sleep 0.05
    #|   printf '%s\n' '{"level":"info","msg":"hidden-classic-run-output"}' '{"level":"info","msg":"Successfully built fixture-image"}' '{"level":"info","msg":"task-prepare completed"}' >&2
    #|   printf '{"level":"info","msg":"lifecycle hook: ' >&2
    #|   printf '\343' >&2
    #|   sleep 0.02
    #|   printf '\201\202 completed"}\r\n' >&2
    #|   printf '%s\n' '{"level":"warn","msg":"fixture warning"}' '{"level":"error","msg":"fixture error"}' >&2
    #|   printf 'known value %s\n' "$CUSTOM_SERVICE_TOKEN" >&2
    #|   printf '%s\n' 'Authorization: Bearer fixture-private-header' 'X-API-Key: fixture-private-api-header' 'api-key=fixture-private-api-field' 'token = fixture-private-field' 'https://user:fixture-private-url@example.com/a' 'https://example.com/a?signature=fixture-private-signature' >&2
    #|   printf '%s\n' 'key=sk-proj-fixture-private-assignment' 'key:sk-proj-fixture-private-colon' 'Cookie=fixture-private-cookie' 'credential: fixture-private-credential-field' >&2
    #|   printf 'key\tsk-proj-fixture-private-tab\n' >&2
    #|   printf '\033[31m%s\033[0m\n' "$CUSTOM_SERVICE_TOKEN" >&2
    #|   printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----' >&2
    #|   printf '%s\n' 'fixture-private-key-body' >&2
    #|   printf '%s%s\n' '-----END ' 'PRIVATE KEY-----' >&2
    #|   printf '\377 fixture-private-binary\n' >&2
    #|   printf '%s\n' '{invalid JSON fixture-private-malformed' '{"kind":"result","message":"fixture-private-result"}' >&2
    #|   awk 'BEGIN { for(i=0;i<70000;i++) printf "x"; print "fixture-private-oversized" }' >&2
    #|   printf '%s\n' '{"level":"info","msg":"creating machine"}' >&2
    #|   touch "$HOME/up-waiting"
    #|   while test ! -f "$HOME/release-up"; do sleep 0.01; done
    #|   : ;;
    #| *'workspace stop'*|*'workspace delete'*) printf '%s\n' '{"level":"info","msg":"lifecycle action complete"}' >&2 ;;
    #|esac
    #|exec "$HOME/bin/devsy-original" "$@"
  @fs.write_file(directory + "/bin/devsy", wrapper + "\n", permission=0o700)
  let executable = integration_binary()
  let stdout = @process.redirect_to_file(
    directory + "/progress-stdout",
    shared=true,
  )
  defer stdout.close()
  let stderr = @process.redirect_to_file(
    directory + "/progress-stderr",
    shared=true,
  )
  defer stderr.close()
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      executable,
      ["recipe", "create"],
      extra_env=env,
      inherit_env=false,
      stdout~,
      stderr~,
    )
    @async.with_timeout(5000, async fn() {
      while !@fs.exists(directory + "/up-waiting") ||
            !@fs.read_file(directory + "/progress-stderr")
            .text()
            .contains("creating machine") {
        @async.sleep(10)
      }
    })
    assert_eq(child.try_wait(), None)
    assert_eq(@fs.read_file(directory + "/progress-stdout").text(), "")
    let errors = @fs.read_file(directory + "/progress-stderr").text()
    assert_true(errors.contains("Build image: running…"), msg=errors)
    assert_eq(errors.split("Build #7: [stage 2/3]").count(), 2)
    for
      message in [
        "Build #7: DONE", "Build #8: CACHED", "Build Step 3/4", "lifecycle hook: あ completed",
        "fixture warning", "fixture error", "task-prepare completed", "[redacted]",
      ] {
      assert_true(errors.contains(message), msg=errors)
    }
    for
      hidden in [
        "hidden-run-output", "hidden-classic-run-output", "hidden-debug-output",
        "hidden-trace-output", "fixture-private-",
      ] {
      assert_false(errors.contains(hidden), msg=errors)
    }
    let records = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(records.contains("building_image"))
    assert_false(records.contains("creating machine"))
    assert_false(records.contains("fixture-private-"))
    @fs.write_file(directory + "/release-up", "")
    assert_eq(child.wait(), 0)
  })
  let errors = @fs.read_file(directory + "/progress-stderr").text()
  assert_true(errors.contains("Build image: done (1.2s, elapsed "), msg=errors)
  assert_true(errors.contains("create: done ("))
  for line in errors.split("\n") {
    if line != "" {
      assert_true(
        line.length() > 9 &&
        line[2:3] == ":" &&
        line[5:6] == ":" &&
        line[8:9] == " ",
        msg=line.to_owned(),
      )
      assert_false(line.contains("orca-env-devsy:"), msg=line.to_owned())
    }
  }
  let receipt = @json.parse(
    @fs.read_file(directory + "/progress-stdout").text(),
  )
  let payload : Json = { "schemaVersion": 1, "recipeResult": receipt }
  for mode in ["resume", "suspend", "destroy"] {
    env.set("ORCA_ENV_DEVSY_RECORDING", "0")
    let (status, output, errors) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_true(errors.contains(mode + ": done ("), msg=errors)
    if mode == "resume" {
      ignore(@json.parse(output))
      assert_true(errors.contains("Build #7: DONE"))
    } else {
      assert_eq(output, "")
      assert_true(errors.contains("lifecycle action complete"))
    }
    assert_false(errors.contains("fixture-private-"))
  }
}

///|
async test "failed streamed workspace up preserves exit failure and owned cleanup" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  @fs.rename(directory + "/bin/devsy", directory + "/bin/devsy-original")
  let wrapper =
    #|#!/bin/sh
    #|set -eu
    #|case "$*" in
    #| *'workspace up'*)
    #|   "$HOME/bin/devsy-original" "$@" >/dev/null
    #|   printf '%s\n' '{"kind":"status","phase":"building_image","state":"started"}' '{"kind":"status","phase":"building_image","state":"failed","durationMs":2500}'
    #|   printf '%s\n' '{"kind":"log","level":"info","message":"Step 1/1 : RUN install"}'
    #|   printf '%s' '{"level":"error","msg":"build failed: fixture error"}' >&2
    #|   printf '%s\n' '{"kind":"error","message":"workspace error envelope"}'
    #|   exit 9 ;;
    #|esac
    #|exec "$HOME/bin/devsy-original" "$@"
  @fs.write_file(directory + "/bin/devsy", wrapper + "\n", permission=0o700)
  let (status, output, errors) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  assert_true(
    errors.contains("Build image: failed (2.5s, elapsed "),
    msg=errors,
  )
  assert_true(errors.contains("build failed: fixture error"))
  assert_true(errors.contains("workspace error envelope"))
  assert_true(errors.contains("workspace-create failed (exit 9)"))
  assert_true(errors.contains("create-cleanup: done ("))
  assert_false(@fs.exists(directory + "/created"))
}

///|
async test "unavailable progress stderr preserves lifecycle result with recording on and off" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let executable = integration_binary()
  for recording in ["1", "0"] {
    env.set("ORCA_ENV_DEVSY_RECORDING", recording)
    let (status, output, _) = @process.collect_output(
      "/bin/sh",
      ["-c", "exec \"$1\" recipe create 2>&-", "sh", executable],
      extra_env=env,
      inherit_env=false,
    )
    assert_eq(status, 0)
    let receipt = @json.parse(output.text())
    let payload : Json = { "schemaVersion": 1, "recipeResult": receipt }
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  }
  let records = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(records.contains("progress_io"))
}

///|
async test "filesystem failure reports its cause and elapsed time before any subprocess" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let (status, output, errors) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  assert_true(errors.contains(" create: failed:"), msg=errors)
  assert_true(errors.contains(", elapsed "))
  assert_true(errors.contains(directory + "/orca.yaml"), msg=errors)
  assert_true(errors.contains("No such file or directory"), msg=errors)
  let events = fixture_events(directory)
  assert_true(
    events
    .iter()
    .any(event => {
      field(event, "stage") == Some(Json::string("create")) &&
      field(event, "errorType") == Some(Json::string("unexpected")) &&
      required(event, "errorMessage").contains("orca.yaml")
    }),
  )
  assert_false(@fs.exists(directory + "/args"))
}

///|
async fn cleanup_fixture(directory : String) -> Unit {
  let leased = @fs.exists(directory + "/fixture-permit")
  defer (if leased { fixture_permits.release() })
  if @fs.exists(directory + "/orca-host/orca-runtime.json") {
    let metadata = @json.parse(
      @fs.read_file(directory + "/orca-host/orca-runtime.json").text(),
    )
    if field(metadata, "pid") is Some(Json::Number(pid, ..)) {
      ignore(proxy_signal(pid.to_int(), 15))
    }
  }
  let base = directory + "/.local/state/orca-env-devsy/tunnels"
  if @fs.exists(base) {
    for name in @fs.readdir(base) {
      let worker = base + "/" + name
      if @fs.exists(worker + "/enabled") {
        @fs.remove(worker + "/enabled")
      }
      @async.with_timeout(15000, async fn() {
        while worker_alive(worker) {
          @async.sleep(100)
        }
      })
      if @fs.exists(worker + "/state.json") {
        try {
          let state = @json.parse(@fs.read_file(worker + "/state.json").text())
          if field(state, "socketDirectory") is Some(Json::String(socket)) &&
            @fs.exists(socket) {
            if @fs.exists(socket) {
              @fs.rmdir(socket, recursive=true)
            }
          }
        } catch {
          _ => ()
        }
      }
    }
  }
  let root = directory + "/.local/state/orca-env-devsy"
  if @fs.exists(root) {
    @async.with_timeout(5000, async fn() {
      while supervisor_alive(root) {
        @async.sleep(10)
      }
    })
  }
  @fs.rmdir(directory, recursive=true)
}

///|
async test "SSH recipes retain their monitor during sleep and reap it on destruction" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let target = field(field(result, "connection").unwrap(), "target").unwrap()
  assert_true(
    required(target, "proxyCommand").contains("--start-services=false"),
  )
  let state = field(result, "userData").unwrap()
  let worker = required(state, "tunnelDirectory")
  let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
  assert_eq(field(saved, "localPort"), None)
  assert_eq(field(saved, "connection"), Some(Json::string("ssh")))
  assert_true(worker_alive(worker))
  assert_eq(@fs.read_file(directory + "/primary-services").text(), "enabled")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  let (status, _, errors) = invoke("suspend", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
  assert_true(worker_alive(worker))
  assert_true(@fs.exists(worker + "/enabled"))
  let (status, output, errors) = invoke("resume", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
  let resumed = @json.parse(output)
  let resumed_worker = required(
    field(resumed, "userData").unwrap(),
    "tunnelDirectory",
  )
  assert_true(worker_alive(resumed_worker))
  let payload : Json = { "schemaVersion": 1, "recipeResult": resumed }
  let (status, _, errors) = invoke("destroy", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
  assert_false(@fs.exists(resumed_worker))
}

///|
async test "adoption rejects stopped or replaced workspaces and reaps the old master" {
  for condition in ["stopped", "replaced"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let state = field(@json.parse(output), "userData").unwrap()
    let worker = required(state, "tunnelDirectory")
    @fs.remove(worker + "/enabled")
    @async.with_timeout(5000, async fn() {
      while worker_alive(worker) {
        @async.sleep(100)
      }
    })
    idle_wait_for(async fn() {
      !supervisor_alive(env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy")
    })
    let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
    let socket = required(saved, "socketDirectory")
    @fs.mkdir(socket, recursive=true, permission=0o700, allow_exist=true)
    // Fake OpenSSH checks this owned marker as a live orphaned master.
    @fs.write_file(socket + "/socket", "")
    @fs.write_file(worker + "/enabled", "")
    match condition {
      "stopped" => @fs.write_file(directory + "/stopped", "")
      "replaced" => {
        @fs.write_file(directory + "/uid", "different-uid")
        @fs.write_file(directory + "/fail-status", "")
      }
      _ =>
        @fs.write_file(
          directory + "/bin/devsy",
          "#!/bin/sh\nexit 1\n",
          permission=0o700,
        )
    }
    let executable = integration_binary()
    @async.with_task_group(async fn(group) {
      let child = @process.spawn(
        group,
        executable,
        [
          "--supervisor",
          env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
          worker,
        ],
        extra_env=env,
      )
      if condition == "stopped" {
        wait_worker_status(worker, "workspace-stopped")
        assert_true(worker_alive(worker))
        @fs.remove(worker + "/enabled")
      }
      assert_eq(child.wait(), 0)
    })
    assert_false(@fs.exists(socket + "/socket"))
    assert_false(worker_alive(worker))
    if condition == "replaced" {
      assert_eq(
        field(
          @json.parse(@fs.read_file(worker + "/status.json").text()),
          "status",
        ),
        Some(Json::string("ownership-error")),
      )
    }
  }
}

///|
async test "direct transport retains early and drained exit codes" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(directory + "/input", "x".repeat(1000000))
  for script in ["exit 37", "cat >/dev/null; sleep 0.3; printf tail; exit 37"] {
    let (code, output, _) = @process.collect_output(
      integration_binary(),
      extra_env=env,
      ["--ssh-proxy", "", "/bin/sh", "-c", script],
      stdin=@process.redirect_from_file(directory + "/input"),
    )
    assert_eq(code, 37)
    assert_eq(output.text(), if script == "exit 37" { "" } else { "tail" })
  }
}

///|
async test "SSH transport retains default signals and launcher termination traps" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let (code, _, _) = @process.collect_output(
    integration_binary(),
    extra_env=env,
    ["--ssh-proxy", "", "/bin/sh", "-c", "kill -TERM $$; exit 37"],
    stdin=@process.redirect_from_file("/dev/null"),
  )
  assert_eq(code, -15)
  @async.with_timeout(2500, async fn() {
    @async.with_task_group(async fn(group) {
      let (input, writer) = @process.write_to_process()
      defer writer.close()
      let child = @process.spawn(
        group,
        integration_binary(),
        extra_env=env,
        [
          "--ssh-proxy",
          "",
          "/bin/sh",
          "-c",
          "trap 'printf stopped > \"$1\"; exit 0' TERM; printf ready > \"$2\"; while :; do :; done",
          "sh",
          directory + "/terminated",
          directory + "/ready",
        ],
        stdin=input,
      )
      while !@fs.exists(directory + "/ready") {
        @async.sleep(10)
      }
      ignore(@process.collect_output("kill", ["-TERM", child.pid.to_string()]))
      ignore(child.wait())
      assert_eq(@fs.read_file(directory + "/terminated").text(), "stopped")
    })
  })
}

///|
async test "SSH owner death terminates managed transports even when stdin remains open or blocked" {
  for blocked in [false, true] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    @fs.write_file(
      directory + "/transport",
      "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > \"$1\"\n" +
      (if blocked { "" } else { "cat\n" }) +
      "while :; do :; done\n",
      permission=0o700,
    )
    @async.with_timeout(10000, async fn() {
      @async.with_task_group(async fn(group) {
        let (input, writer) = @process.write_to_process()
        defer writer.close()
        let (reader, output) = @process.read_from_process()
        defer reader.close()
        let owner = @process.spawn(
          group,
          "/bin/sh",
          [
            "-c",
            "exec 3<&0; \"$1\" --ssh-proxy \"$HOME/primary-proxy.lock\" \"$2\" \"$3\" <&3 3<&- & wait",
            "sh",
            integration_binary(),
            directory + "/transport",
            directory + "/child-pid",
          ],
          extra_env=env,
          stdin=input,
          stdout=output,
        )
        idle_wait_for(async fn() { @fs.exists(directory + "/child-pid") })
        let pid = @fs.read_file(directory + "/child-pid").text()
        let root = env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy"
        let receipts = @fs.readdir(root + "/transports")
        assert_eq(receipts.length(), 1)
        let receipt = @json.parse(
          @fs.read_file(root + "/transports/" + receipts[0] + "/state.json").text(),
        )
        assert_eq(required(receipt, "pid"), pid)
        assert_eq(required(receipt, "ownerPid"), owner.pid.to_string())
        if blocked {
          group.spawn_bg(no_wait=true, async fn() {
            for _ in 0..<128 {
              writer.write(Bytes::make(65536, 0)) catch {
                _ => break
              }
            }
          })
          @async.sleep(100)
        } else {
          let payload = b"\x00\x80\xff\r\nSSH"
          writer.write(payload)
          assert_eq(reader.read_exactly(payload.length()), payload)
        }
        assert_eq(
          @process.collect_output("kill", ["-KILL", owner.pid.to_string()]).0,
          0,
        )
        assert_eq(owner.wait(), -9)
        assert_eq(reader.read_some(max_len=1), None)
        idle_wait_for(() => process_start(@string.parse_int(pid)) == 0)
      })
    })
  }
}

///|
async test "adoption waits for Git options and validates the relay before connected" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  let worker = required(state, "tunnelDirectory")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  defer ignore(invoke("destroy", env, directory, payload~))
  @fs.remove(worker + "/enabled")
  @async.with_timeout(5000, async fn() {
    while worker_alive(worker) {
      @async.sleep(10)
    }
  })
  let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
  let socket = required(saved, "socketDirectory")
  @fs.mkdir(socket, recursive=true, permission=0o700, allow_exist=true)
  @fs.write_file(socket + "/socket", "")
  @fs.write_file(worker + "/enabled", "")
  @fs.write_file(worker + "/status.json", "{\"status\":\"connected\"}")
  @fs.rename(directory + "/bin/devsy", directory + "/bin/devsy-original")
  let wrapper =
    #|#!/bin/sh
    #|case "$*" in
    #|  *'context get'*) touch "$HOME/options-blocked"; while test ! -f "$HOME/release-options"; do sleep 0.01; done ;;
    #|esac
    #|exec "$HOME/bin/devsy-original" "$@"
  @fs.write_file(directory + "/bin/devsy", wrapper + "\n", permission=0o700)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      @async.with_timeout(5000, async fn() {
        while !@fs.exists(directory + "/options-blocked") {
          @async.sleep(10)
        }
      })
      assert_true(
        field(
          @json.parse(@fs.read_file(worker + "/status.json").text()),
          "status",
        ) !=
        Some(Json::string("connected")),
      )
      @fs.write_file(directory + "/release-options", "")
    })
    let (status, _, errors) = invoke("recover", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  })
  let events = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(events.contains("adopted"))
}

///|
async test "adopted primary is stopped before recovering after a failed health check" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  let worker = required(state, "tunnelDirectory")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  defer ignore(invoke("destroy", env, directory, payload~))
  @fs.remove(worker + "/enabled")
  @async.with_timeout(5000, async fn() {
    while worker_alive(worker) {
      @async.sleep(10)
    }
  })
  idle_wait_for(async fn() {
    !supervisor_alive(env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy")
  })
  let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
  let socket = required(saved, "socketDirectory")
  @fs.mkdir(socket, recursive=true, permission=0o700, allow_exist=true)
  @fs.write_file(socket + "/socket", "")
  @fs.write_file(worker + "/enabled", "")
  @fs.write_file(worker + "/status.json", "{}")
  @fs.write_file(directory + "/block-initial-probe", "")
  @fs.rename(directory + "/bin/ssh", directory + "/bin/ssh-original")
  let wrapper =
    #|#!/bin/sh
    #|set -eu
    #|control=
    #|previous=
    #|for arg in "$@"; do
    #|  if test "$previous" = -S; then control="$arg"; fi
    #|  previous="$arg"
    #|done
    #|case "$*" in
    #|  *'orca-relay-readiness'*)
    #|    if test -f "$HOME/block-initial-probe"; then rm "$HOME/block-initial-probe"; touch "$HOME/initial-probe-started"; while test ! -f "$HOME/release-initial-probe"; do sleep 0.01; done; exec "$HOME/bin/ssh-original" "$@"; fi
    #|    if test -f "$HOME/fail-next-check"; then printf 'readiness connection refused\n' >&2; exit 79; fi ;;
    #|  *'-N'*)
    #|    rm -f "$HOME/fail-next-check"
    #|    if test -f "$control"; then touch "$HOME/master-conflict"; exit 1; fi
    #|    touch "$HOME/master-recreated" ;;
    #|esac
    #|exec "$HOME/bin/ssh-original" "$@"
  @fs.write_file(directory + "/bin/ssh", wrapper + "\n", permission=0o700)
  @async.with_task_group(async fn(group) {
    let sink = @process.redirect_to_file("/dev/null", shared=true)
    defer sink.close()
    let stderr = @process.redirect_to_file(
      directory + "/supervisor-stderr",
      shared=true,
    )
    defer stderr.close()
    let child = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        worker,
      ],
      extra_env=env,
      stdout=sink,
      stderr~,
    )
    defer (@fs.remove(worker + "/enabled") catch { _ => () })
    @async.with_timeout(
      5000,
      async fn() {
        while !@fs.exists(directory + "/initial-probe-started") {
          @async.sleep(10)
        }
      },
      error=AdapterError("Timed out waiting for initial readiness probe"),
    )
    @fs.write_file(directory + "/fail-next-check", "")
    @fs.write_file(worker + "/probe-request", "")
    @fs.write_file(directory + "/release-initial-probe", "")
    @async.with_timeout(
      5000,
      async fn() {
        while !@fs.exists(directory + "/master-recreated") &&
              !@fs.exists(directory + "/master-conflict") {
          @async.sleep(10)
        }
      },
      error=AdapterError("Timed out waiting for primary replacement"),
    ) catch {
      error =>
        fail(
          diagnostic_error(error) +
          "\nstatus: " +
          @fs.read_file(worker + "/status.json").text() +
          "\n" +
          @fs.read_file(directory + "/supervisor-stderr").text(),
        )
    }
    assert_false(@fs.exists(directory + "/master-conflict"))
    assert_true(@fs.exists(directory + "/master-recreated"))
    let failures = fixture_events(directory).filter(event => {
      field(event, "stage") == Some(Json::string("relay-probe")) &&
      field(event, "exitCode") == Some(Json::number(79))
    })
    assert_true(failures.length() > 0)
    assert_eq(field(failures[0], "phase"), Some(Json::string("readiness")))
    assert_true(
      required(failures[0], "errorMessage").contains(
        "readiness connection refused",
      ),
    )
    @fs.remove(worker + "/enabled")
    assert_eq(
      @async.with_timeout(
        5000,
        async fn() { child.wait() },
        error=AdapterError("Timed out waiting for recovery supervisor shutdown"),
      ),
      0,
    )
  })
}

///|
async test "Git readiness follows caller cancellation and rejects a stopped worker" {
  let directory = @fs.tmpdir(prefix="orca-env-devsy-test")
  defer cleanup_fixture(directory)
  @fs.write_file(directory + "/enabled", "")
  {
    let lease = @fs.open(
      directory + "/worker.lock",
      mode=ReadWrite,
      create_mode=OpenOrCreate,
      permission=0o600,
    )
    defer lease.close()
    assert_true(lease.try_lock(Exclusive))
    defer lease.unlock()
    let cancelled = try {
      @async.with_timeout(200, async fn() { wait_git_relay(directory) })
      false
    } catch {
      @async.TimeoutError => true
      error => raise error
    }
    assert_true(cancelled)
    assert_true(worker_alive(directory))
    for status in ["ready", "disabled"] {
      @fs.write_file(directory + "/git-status", status)
      @async.with_timeout(1000, async fn() { wait_git_relay(directory) })
    }
  }
  let stopped = try {
    @async.with_timeout(1000, async fn() { wait_git_relay(directory) })
    false
  } catch {
    AdapterError("Tunnel worker stopped before Git credential relay readiness") =>
      true
    error => raise error
  }
  if !stopped {
    fail(
      "Stopped worker returned readiness; workerAlive=\{worker_alive(directory)}, enabled=\{@fs.exists(directory + "/enabled")}, status=\{@fs.read_file(directory + "/git-status").text()}",
    )
  }
}

///|
async test "provisioned task checkout waits for relay even with present commits" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("ORCA_REPO_REF_HEAD", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  env.set("ORCA_REPO_BRANCH", "task-branch")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test, checkoutMode: provisioned-root}]\n",
  )
  @fs.write_file(directory + "/git-unavailable", "")
  let (status, output, errors) = @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      while !@fs.exists(directory + "/git-probed") {
        @async.sleep(10)
      }
      @async.sleep(1000)
      @fs.remove(directory + "/git-unavailable")
    })
    invoke("create", env, directory)
  })
  assert_eq(status, 0, msg=errors)
  assert_false(errors.contains("readiness is unavailable"))
  let payload : Json = {
    "schemaVersion": 1,
    "recipeResult": @json.parse(output),
  }
  defer ignore(invoke("destroy", env, directory, payload~))
  assert_false(@fs.exists(directory + "/git-unavailable"))
  assert_true(
    @fs.read_file(directory + "/ssh-args")
    .text()
    .contains("git checkout -B 'task-branch'"),
  )
}

///|
async test "provisioned task checkout waits for primary Git readiness without replacing its master" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("ORCA_REPO_REF_HEAD", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  env.set("ORCA_REPO_BRANCH", "task-branch")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test, checkoutMode: provisioned-root}]\n",
  )
  @fs.write_file(directory + "/task-commit-missing", "")
  @fs.write_file(directory + "/git-unavailable", "")
  @fs.rename(directory + "/bin/ssh", directory + "/bin/ssh-original")
  let wrapper =
    #|#!/bin/sh
    #|case "$*" in
    #|  *'-N'*)
    #|    if test -f "$HOME/primary-started"; then touch "$HOME/primary-replaced"; fi
    #|    touch "$HOME/primary-started" ;;
    #|  *'git checkout -B'*)
    #|    touch "$HOME/task-checkout"
    #|    if test -f "$HOME/git-unavailable"; then
    #|      touch "$HOME/checkout-before-ready"
    #|      exit 7
    #|    fi ;;
    #|esac
    #|exec "$HOME/bin/ssh-original" "$@"
  @fs.write_file(directory + "/bin/ssh", wrapper + "\n", permission=0o700)
  let (status, output, errors) = @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      while !@fs.exists(directory + "/git-probed") {
        @async.sleep(10)
      }
      assert_false(@fs.exists(directory + "/task-checkout"))
      @fs.remove(directory + "/git-unavailable")
    })
    invoke("create", env, directory)
  })
  assert_eq(status, 0, msg=errors)
  let payload : Json = {
    "schemaVersion": 1,
    "recipeResult": @json.parse(output),
  }
  defer ignore(invoke("destroy", env, directory, payload~))
  assert_false(@fs.exists(directory + "/checkout-before-ready"))
  assert_false(@fs.exists(directory + "/primary-replaced"))
  assert_true(@fs.exists(directory + "/task-checkout"))
  assert_false(errors.contains("readiness is unavailable"))
}

///|
async test "saved SSH proxy survives pruning its original adapter installation" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let installed = directory + "/installed-adapter"
  assert_eq(@process.run("/bin/cp", [integration_binary(), installed]), 0)
  let (status, output, errors) = @process.collect_output(
    installed,
    ["recipe", "create"],
    extra_env=env,
  )
  assert_eq(status, 0, msg=errors.text())
  let result = @json.parse(output.text())
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  defer ignore(invoke("destroy", env, directory, payload~))
  let proxy = required(
    field(field(result, "connection").unwrap(), "target").unwrap(),
    "proxyCommand",
  )
  @fs.remove(installed)
  let worker = required(field(result, "userData").unwrap(), "tunnelDirectory")
  assert_true(worker_alive(worker))
  let (code, _, _) = @process.collect_output(
    "/bin/sh",
    ["-c", proxy],
    extra_env=env,
    stdin=@process.redirect_from_file("/dev/null"),
  )
  // The fake Devsy rejects stdio with exit 2; exit 127 means the launcher vanished.
  assert_eq(code, 2)
  let launcher = directory + "/.local/state/orca-env-devsy/ssh-proxy-adapter"
  @fs.rename(launcher, launcher + ".old")
  @fs.write_file(launcher, "outdated", permission=0o700)
  let (recovered, _, recover_errors) = invoke("recover", env, directory)
  assert_eq(recovered, 0, msg=recover_errors)
  assert_eq(
    @fs.read_file(launcher).binary(),
    @fs.read_file(integration_binary()).binary(),
  )
  let (refreshed, _, _) = @process.collect_output(
    "/bin/sh",
    ["-c", proxy],
    extra_env=env,
    stdin=@process.redirect_from_file("/dev/null"),
  )
  assert_eq(refreshed, 2)
}

///|
async test "process API failures retain executable path and numeric errno without arguments" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let document : Json = {
    "devsy": {
      "command": [directory + "/private-missing-command"],
      "connection": "ssh",
      "buildRef": "refs/heads/main",
    },
    "environmentRecipes": [{ "id": "test" }],
  }
  @fs.write_file(directory + "/orca.yaml", document.stringify())
  let (status, _, errors) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_true(errors.contains("process_os"))
  assert_true(errors.contains("osErrno"))
  assert_false(errors.contains("\"phase\":\"spawn\""))
  assert_true(errors.contains("private-missing-command"))
  assert_true(errors.contains("resolve-context failed (OS error"))
  let records = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(records.contains("private-missing-command"))
}

///|
async test "orca-worktree requires buildRef before any external acquisition" {
  for setting in ["", ", buildRef: ''"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh" +
      setting +
      "}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, _, errors) = invoke("create", env, directory)
    assert_true(status != 0)
    assert_true(errors.contains("devsy.buildRef is required"))
    assert_false(@fs.exists(directory + "/args"))
  }
}

///|
async test "branch build records the acquired tip rather than a stale preflight tip" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("FAKE_BUILD_COMMIT", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  assert_eq(
    field(field(result, "userData").unwrap(), "buildCommit"),
    Some(Json::string("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")),
  )
  let args = @fs.read_file(directory + "/args").text()
  assert_true(args.contains("https://example.com/repo.git@main\n"))
  assert_false(args.contains("@sha256:"))
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  let (status, _, errors) = invoke("destroy", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
}

///|
async test "provisioned-root builds the supplied start ref without buildRef" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("ORCA_REPO_REF", "refs/remotes/origin/main")
  env.set("ORCA_REPO_REF_HEAD", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  env.set("ORCA_REPO_BRANCH", "feature")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh}\nenvironmentRecipes: [{id: test, checkoutMode: provisioned-root}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let args = @fs.read_file(directory + "/args").text()
  assert_true(args.contains("https://example.com/repo.git@main\n"))
  assert_true(args.contains("--git-clone-strategy=shallow\n"))
  assert_false(args.contains("@sha256:"))
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  let (status, _, errors) = invoke("destroy", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
}

///|
async test "FUSE Git object creation uses rename without replacing user settings" {
  for
    (filesystem, initial, expected) in [
      ("virtiofs", None, Some("rename")),
      ("fuseblk", None, Some("rename")),
      ("virtiofs", Some("link"), Some("link")),
      ("virtiofs", Some("include"), Some("link")),
      ("virtiofs", Some("locked"), Some("link")),
      ("ext2/ext3", None, None),
    ] {
    let directory = @fs.tmpdir(prefix="orca-git-storage-test")
    defer @fs.rmdir(directory, recursive=true)
    let root = directory + "/workspace 'quoted'"
    @fs.mkdir(root)
    @fs.mkdir(directory + "/bin")
    @fs.write_file(
      directory + "/bin/stat",
      "#!/bin/sh\nprintf '%s\\n' \"$FAKE_FILESYSTEM\"\n",
      permission=0o700,
    )
    let env = {
      "HOME": directory,
      "GIT_CONFIG_GLOBAL": directory + "/.gitconfig",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_COUNT": "0",
      "GIT_CONFIG_PARAMETERS": "",
      "FAKE_FILESYSTEM": filesystem,
      "PATH": directory + "/bin:" + @env.get_env_var("PATH").unwrap(),
    }
    if initial is Some("locked") {
      let (_, executable, _) = @process.collect_output(
        "sh",
        ["-c", "command -v git"],
        extra_env=env,
      )
      env.set("REAL_GIT", executable.text().trim().to_owned())
      env.set("LOCK_ATTEMPT", directory + "/lock-attempt")
      @fs.write_file(
        directory + "/bin/git",
        (
          #|#!/bin/sh
          #|"$REAL_GIT" "$@"
          #|status=$?
          #|if test "$status" -eq 255; then : > "$LOCK_ATTEMPT"; fi
          #|exit "$status"
        ),
        permission=0o700,
      )
      @fs.write_file(
        directory + "/.gitconfig.lock",
        "[core]\ncreateObject = link\n",
      )
    } else if initial is Some(value) {
      let (key, value) = if value == "include" {
        let included = directory + "/included.config"
        @fs.write_file(included, "[core]\ncreateObject = link\n")
        ("include.path", included)
      } else {
        ("core.createObject", value)
      }
      let (status, _, errors) = @process.collect_output(
        "git",
        ["config", "--global", key, value],
        extra_env=env,
      )
      assert_eq(status, 0, msg=errors.text())
    }
    let (status, _, errors) = @async.with_task_group(async fn(group) {
      if initial == Some("locked") {
        group.spawn_bg(async fn() {
          @async.with_timeout(5000, async fn() {
            while !@fs.exists(directory + "/lock-attempt") {
              @async.sleep(10)
            }
          })
          @fs.rename(directory + "/.gitconfig.lock", directory + "/.gitconfig")
        })
      }
      @process.collect_output(
        "sh",
        ["-c", git_object_storage_script(root)],
        extra_env=env,
      )
    })
    assert_eq(status, 0, msg=errors.text())
    let (status, output, _) = @process.collect_output(
      "git",
      ["config", "--global", "--includes", "--get", "core.createObject"],
      extra_env=env,
    )
    match expected {
      Some(value) => {
        assert_eq(status, 0)
        assert_eq(output.text().trim(), value)
      }
      None => assert_eq(status, 1)
    }
  }
}

///|
fn create_event(
  events : Array[Json],
  stage : String,
  attempt~ : Int32 = 1,
) -> Json raise {
  let matches = events.filter(event => {
    field(event, "stage") == Some(Json::string(stage)) &&
    field(event, "createAttempt") == Some(Json::number(attempt.to_double()))
  })
  guard matches.length() == 1 else {
    raise AdapterError("Expected one saved create event for " + stage)
  }
  matches[0]
}

///|
async test "saved create sources separate Orca inputs configuration resolution and acquired checkout" {
  for input_state in ["unset", "empty", "valid", "invalid", "token"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    if input_state == "valid" {
      env.set("ORCA_REPO_URL", "ssh://git@example.com/repo.git")
    } else if input_state == "empty" {
      env.set(
        "ORCA_REPO_URL", "https::https://ghp_fixturetoken123@example.com/repo.git",
      )
    } else if input_state == "invalid" {
      env.set(
        "ORCA_REPO_URL", "HTTPS://ghp_fixturetoken123@example.com/repo.git",
      )
    } else if input_state == "token" {
      env.set(
        "ORCA_REPO_URL", "ftp://user:fixture-password@example.com/repo.git",
      )
    }
    let head = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    for name in ["ORCA_REPO_REF", "ORCA_REPO_REF_HEAD", "ORCA_REPO_BRANCH"] {
      match input_state {
        "unset" => env.remove(name)
        "empty" => env.set(name, "")
        "valid" =>
          env.set(
            name,
            if name == "ORCA_REPO_REF_HEAD" {
              head
            } else {
              "fix/task-source"
            },
          )
        "token" => env.set(name, "ghp_privacy_secret_fixture")
        _ =>
          env.set(
            name, "https://fixture-user:privacy-secret@example.com/repo?token=privacy-secret",
          )
      }
    }
    env.set("FAKE_BUILD_COMMIT", head)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let events = fixture_events(directory)
    let repository = field(
      create_event(events, "repository-source"),
      "evidence",
    ).unwrap()
    assert_eq(field(repository, "source"), Some(Json::string("environment")))
    assert_eq(
      field(repository, "url"),
      Some(
        Json::string(
          if input_state == "valid" {
            "ssh://git@example.com/repo.git"
          } else if input_state == "empty" {
            "https::https://[redacted]@example.com/repo.git"
          } else if input_state == "invalid" {
            "HTTPS://[redacted]@example.com/repo.git"
          } else if input_state == "token" {
            "ftp://[redacted]@example.com/repo.git"
          } else {
            "https://example.com/repo.git"
          },
        ),
      ),
    )
    assert_eq(field(repository, "path"), Some(Json::string(directory)))
    let received = events.filter(event => {
        field(event, "stage") == Some(Json::string("create-input")) &&
        field(event, "status") == Some(Json::string("received"))
      })[0]
    let source = field(received, "source").unwrap()
    for name in ["ORCA_REPO_REF", "ORCA_REPO_REF_HEAD", "ORCA_REPO_BRANCH"] {
      let value = field(source, name).unwrap()
      assert_eq(
        field(value, "state"),
        Some(
          Json::string(
            if input_state == "token" {
              "invalid"
            } else {
              input_state
            },
          ),
        ),
      )
      assert_eq(field(value, "value") is Some(_), input_state == "valid")
    }
    assert_eq(
      field(field(source, "ORCA_VM_INSTANCE_ID").unwrap(), "value"),
      Some(Json::string("test-id")),
    )
    assert_eq(
      field(field(source, "ORCA_RECIPE_ID").unwrap(), "value"),
      Some(Json::string("test")),
    )
    let config = field(create_event(events, "create-configuration"), "source").unwrap()
    assert_eq(
      field(config, "checkoutMode"),
      Some(Json::string("orca-worktree")),
    )
    assert_eq(field(config, "connection"), Some(Json::string("ssh")))
    assert_eq(
      field(field(config, "configuredBuildRef").unwrap(), "value"),
      Some(Json::string("refs/heads/main")),
    )
    let resolved = field(create_event(events, "build-resolution"), "source").unwrap()
    assert_eq(
      field(field(resolved, "resolvedCommit").unwrap(), "value"),
      Some(Json::string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
    )
    let selected = field(create_event(events, "build-selection"), "source").unwrap()
    assert_eq(
      field(field(selected, "resolvedBranch").unwrap(), "value"),
      Some(Json::string("main")),
    )
    assert_eq(
      field(selected, "selectionReason"),
      Some(Json::string("configured-build-ref")),
    )
    let clone = field(create_event(events, "clone-shallow"), "source").unwrap()
    assert_eq(field(clone, "cloneStrategy"), Some(Json::string("shallow")))
    assert_eq(field(clone, "fallback"), Some(Json::boolean(false)))
    let checkout = field(create_event(events, "build-checkout"), "source").unwrap()
    assert_eq(field(checkout, "scope"), Some(Json::string("build-checkout")))
    assert_eq(
      field(field(checkout, "actualCommit").unwrap(), "value"),
      Some(Json::string(head)),
    )
    assert_eq(field(checkout, "matches"), Some(Json::boolean(true)))
    assert_eq(
      field(create_event(events, "create-attempt"), "status"),
      Some(Json::string("success")),
    )
    for event in events {
      if field(event, "createAttempt") is Some(_) {
        assert_eq(field(event, "runId"), field(received, "runId"))
      }
    }
    let raw = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_false(raw.contains("privacy-secret"))
    assert_false(raw.contains("ghp_privacy_secret_fixture"))
    assert_false(raw.contains("fixture-user"))
    let payload : Json = {
      "schemaVersion": 1,
      "recipeResult": @json.parse(output),
    }
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  }
}

///|
async test "saved create failure retains inputs and the failed decision boundary" {
  for failure in ["input", "resolution", "ref-shape", "build", "checkout"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    env.set("ORCA_REPO_REF", "fix/task-source")
    env.set("ORCA_REPO_REF_HEAD", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    env.set("ORCA_REPO_BRANCH", "task")
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}\nenvironmentRecipes: [{id: test}]\n",
    )
    match failure {
      "input" =>
        env.set("ORCA_VM_INSTANCE_ID", "https://privacy-secret@example.com")
      "resolution" =>
        @fs.write_file(
          directory + "/bin/git",
          "#!/bin/sh\nexit 9\n",
          permission=0o700,
        )
      "ref-shape" => {
        @fs.write_file(
          directory + "/orca.yaml",
          "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
        )
        @fs.write_file(
          directory + "/bin/git",
          "#!/bin/sh\ncase \"$*\" in *--symref*) printf 'ref: refs/heads/main\\tHEAD\\n';; *) printf 'malformed privacy-secret\\n';; esac\n",
          permission=0o700,
        )
      }
      "build" => @fs.write_file(directory + "/fail-up", "")
      _ =>
        env.set("FAKE_BUILD_COMMIT", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    }
    let (status, output, _) = invoke("create", env, directory)
    assert_true(status != 0)
    assert_eq(output, "")
    let events = fixture_events(directory)
    let failed = create_event(events, "create-attempt")
    assert_eq(field(failed, "status"), Some(Json::string("failed")))
    assert_eq(
      field(failed, "createPhase"),
      Some(
        Json::string(
          match failure {
            "input" => "input-validation"
            "resolution" | "ref-shape" => "ref-resolution"
            "build" => "build"
            _ => "checkout-verification"
          },
        ),
      ),
    )
    let received = events.filter(event => {
        field(event, "stage") == Some(Json::string("create-input")) &&
        field(event, "status") == Some(Json::string("received"))
      })[0]
    assert_eq(
      field(
        field(field(received, "source").unwrap(), "ORCA_REPO_REF").unwrap(),
        "value",
      ),
      Some(Json::string("fix/task-source")),
    )
    if failure == "resolution" || failure == "ref-shape" {
      let requested = field(create_event(events, "build-request"), "source").unwrap()
      assert_eq(
        field(requested, "selectionReason"),
        Some(Json::string("configured-build-ref")),
      )
    }
    if failure == "ref-shape" {
      assert_eq(
        field(
          field(
            field(create_event(events, "build-lookup"), "source").unwrap(),
            "lookupRef",
          ).unwrap(),
          "value",
        ),
        Some(Json::string("refs/heads/main")),
      )
    }
    if failure == "checkout" {
      assert_eq(
        field(
          field(create_event(events, "build-checkout"), "source").unwrap(),
          "matches",
        ),
        Some(Json::boolean(false)),
      )
    }
    assert_false(
      @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl")
      .text()
      .contains("privacy-secret"),
    )
  }
}

///|
async test "task head fallback keeps attempts linked without claiming an Orca worktree checkout" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("ORCA_REPO_REF", "refs/heads/main")
  env.set("ORCA_REPO_REF_HEAD", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  env.set("ORCA_REPO_BRANCH", "task")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh}\nenvironmentRecipes: [{id: test, checkoutMode: provisioned-root}]\n",
  )
  let (status, output, _) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  let events = fixture_events(directory)
  let first = create_event(events, "create-attempt")
  let second = create_event(events, "create-attempt", attempt=2)
  assert_eq(field(first, "status"), Some(Json::string("retry")))
  assert_eq(field(second, "status"), Some(Json::string("failed")))
  assert_eq(field(first, "runId"), field(second, "runId"))
  let fallback = field(create_event(events, "clone-fallback"), "source").unwrap()
  assert_eq(
    field(fallback, "fallbackReason"),
    Some(Json::string("task-head-mismatch")),
  )
  assert_eq(field(fallback, "cloneStrategy"), None)
  let retry_clone = field(
    create_event(events, "clone-full", attempt=2),
    "source",
  ).unwrap()
  assert_eq(field(retry_clone, "cloneStrategy"), Some(Json::string("full")))
  let selection = field(
    create_event(events, "build-selection", attempt=2),
    "source",
  ).unwrap()
  assert_eq(
    field(selection, "selectionReason"),
    Some(Json::string("checkout-mismatch-retry")),
  )
  assert_eq(field(selection, "resolvedBranch"), Some({ "state": "unset" }))
}

///|
async test "create recording opt out and unwritable event store preserve lifecycle contracts" {
  for recording in ["enabled", "disabled", "unwritable"] {
    for failure in [false, true] {
      let (directory, env) = fixture()
      defer cleanup_fixture(directory)
      @fs.write_file(
        directory + "/orca.yaml",
        "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
      )
      let store = directory + "/.local/state/orca-env-devsy/events.jsonl"
      if recording == "disabled" {
        env.set("ORCA_ENV_DEVSY_RECORDING", "0")
      } else if recording == "unwritable" {
        @fs.mkdir(store, recursive=true)
      }
      if failure {
        @fs.write_file(directory + "/fail-up", "")
      }
      let (status, output, errors) = invoke("create", env, directory)
      assert_eq(status == 0, !failure, msg=errors)
      if failure {
        assert_eq(output, "")
      } else {
        let result = @json.parse(output)
        let state = field(result, "userData").unwrap()
        assert_eq(
          field(state, "buildRef"),
          Some(Json::string("refs/heads/main")),
        )
        assert_eq(
          field(state, "buildCommit"),
          Some(Json::string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
        )
        assert_eq(field(state, "connection"), Some(Json::string("ssh")))
        let payload : Json = { "schemaVersion": 1, "recipeResult": result }
        let (status, _, errors) = invoke("destroy", env, directory, payload~)
        assert_eq(status, 0, msg=errors)
      }
      if recording == "disabled" {
        assert_false(@fs.exists(store))
      }
      if recording == "unwritable" {
        assert_eq(@fs.readdir(store).length(), 0)
      }
    }
  }
}

///|
async test "clone override records the allowlisted strategy from the actual invocation" {
  for
    (args, expected) in [
      (["--git-clone-strategy=blobless"], "blobless"),
      (["--git-clone-strategy", "shallow"], "shallow"),
      (["--git-clone-strategy="], "full"),
      (
        ["--git-clone-strategy=bare", "--git-clone-strategy", "treeless"],
        "treeless",
      ),
      (["--git-clone-strategy=privacy-secret"], "invalid"),
      (["--git-clone-strategy"], "invalid"),
    ] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    let document : Json = {
      "devsy": {
        "connection": "ssh",
        "buildRef": "refs/heads/main",
        "upArgs": Json::array(args.map(Json::string)),
      },
      "environmentRecipes": [{ "id": "test" }],
    }
    @fs.write_file(directory + "/orca.yaml", document.stringify())
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let events = fixture_events(directory)
    let clone = field(create_event(events, "clone-override"), "source").unwrap()
    assert_eq(field(clone, "cloneStrategy"), Some(Json::string(expected)))
    assert_eq(field(clone, "strategySource"), Some(Json::string("upArgs")))
    assert_false(
      @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl")
      .text()
      .contains("privacy-secret"),
    )
    let payload : Json = {
      "schemaVersion": 1,
      "recipeResult": @json.parse(output),
    }
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  }
}

///|
async test "failed workspace creation preserves credential error causes and masks only values" {
  for recording in ["enabled", "disabled", "unwritable"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    env.set("CUSTOM_SERVICE_TOKEN", "fixture-private-environment")
    let store = directory + "/.local/state/orca-env-devsy/events.jsonl"
    if recording == "disabled" {
      env.set("ORCA_ENV_DEVSY_RECORDING", "0")
    } else if recording == "unwritable" {
      @fs.mkdir(store, recursive=true)
    }
    @fs.rename(directory + "/bin/devsy", directory + "/bin/devsy-original")
    let wrapper =
      #|#!/bin/sh
      #|set -eu
      #|case "$*" in
      #| *'workspace up'*)
      #|   "$HOME/bin/devsy-original" "$@" >/dev/null
      #|   printf '%s\n' '{"level":"error","msg":"get credentials: credential helper executable not found"}' >&2
      #|   printf '%s\n' '{"kind":"error","message":"token exchange failed: API returned 403; token=fixture-private-token; operation=connect"}'
      #|   printf '%s\n' '{"kind":"status","phase":"configuring_ssh","state":"failed","error":{"message":"SSH authorization failed: https://user:fixture-private-url@example.com/connect?signature=fixture-private-signature&region=apne1","hint":"check credential helper installation","context":{"token":"fixture-private-context"}}}'
      #|   printf '%s\n' 'ERROR Authorization: Bearer fixture-private-header' 'request failed with token: fixture-private-colon' 'error --token fixture-private-flag' 'Cookie="fixture-private-cookie"; session=fixture-private-session' 'https://example.com/path?access%5Ftoken=fixture-private-query&region=apne1' >&2
      #|   printf 'environment value: %s\n' "$CUSTOM_SERVICE_TOKEN" >&2
      #|   printf '%s\n' '{"level":"info","msg":"deleting machine"}' '{"level":"info","msg":"deleted machine"}' >&2
      #|   exit 9 ;;
      #|esac
      #|exec "$HOME/bin/devsy-original" "$@"
    @fs.write_file(directory + "/bin/devsy", wrapper + "\n", permission=0o700)
    let (status, output, errors) = invoke("create", env, directory)
    assert_true(status != 0)
    assert_eq(output, "")
    assert_false(@fs.exists(directory + "/created"))
    assert_false(errors.contains("fixture-private-"), msg=errors)
    assert_false(errors.contains("command output withheld"), msg=errors)
    assert_false(errors.contains("[credential output redacted]"), msg=errors)
    for
      cause in [
        "credential helper executable not found", "token exchange failed: API returned 403",
        "operation=connect", "SSH authorization failed", "region=apne1", "check credential helper installation",
        "workspace-create failed (exit 9)", "diagnostic run ", "[redacted]",
      ] {
      assert_true(errors.contains(cause), msg=errors)
    }
    if recording == "enabled" {
      let events = fixture_events(directory)
      let failure = events.filter(event => {
          field(event, "stage") == Some(Json::string("workspace-create")) &&
          field(event, "status") == Some(Json::string("exit-error"))
        })[0]
      let detail = required(failure, "errorMessage")
      assert_true(
        detail.contains("credential helper executable not found"),
        msg=detail,
      )
      assert_true(
        detail.contains("token exchange failed: API returned 403"),
        msg=detail,
      )
      assert_true(detail.contains("SSH authorization failed"), msg=detail)
      assert_false(@fs.read_file(store).text().contains("fixture-private-"))
      assert_eq(field(failure, "detailsTruncated"), Some(Json::boolean(false)))
      assert_true(errors.contains(required(failure, "runId")))
    } else if recording == "disabled" {
      assert_false(@fs.exists(store))
    }
  }
}

///|
async test "non streaming command failures retain plain stderr and bounded diagnostics" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let document : Json = {
    "devsy": {
      "connection": "ssh",
      "buildRef": "refs/heads/main",
      "command": [
        "/bin/sh", "-c", "i=0; while test $i -lt 12; do printf 'credential helper attempt %s failed\\n' $i >&2; i=$((i+1)); done; printf 'get credentials: executable /opt/helper not found; password=fixture-private-password; cause=ENOENT\\n' >&2; exit 7",
        "sh",
      ],
    },
    "environmentRecipes": [{ "id": "test" }],
  }
  @fs.write_file(directory + "/orca.yaml", document.stringify())
  let (status, output, errors) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  assert_true(errors.contains("resolve-context failed (exit 7)"))
  assert_true(errors.contains("executable /opt/helper not found"), msg=errors)
  assert_true(errors.contains("cause=ENOENT"), msg=errors)
  assert_false(errors.contains("fixture-private-password"))
  let records = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(records.contains("executable /opt/helper not found"), msg=records)
  assert_true(records.contains("\"detailsTruncated\":true"), msg=records)
  assert_false(records.contains("fixture-private-password"))
}

///|
async test "unsupported readiness is terminal and failed create removes its workspace" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  @fs.write_file(directory + "/unsupported-ready", "")
  let (status, _, errors) = @async.with_timeout(connection_timeout_ms(), async fn() {
    invoke("create", env, directory)
  })
  assert_true(status != 0)
  assert_true(errors.contains("Devsy /ready is unsupported"))
  assert_false(@fs.exists(directory + "/created"))
  assert_eq(
    @fs.read_file(directory + "/ssh-args").text().split("-N\n").count(),
    2,
  )
  let events = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(events.contains("readiness_unsupported"))
  assert_false(
    events.contains("\"stage\":\"orca-tunnel\",\"status\":\"retry\""),
  )
}

///|
async test "resume deadline returns failure while the worker continues recovering" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    let original_worker = required(
      field(result, "userData").unwrap(),
      "tunnelDirectory",
    )

    let (suspended, _, errors) = invoke("suspend", env, directory, payload~)
    assert_eq(suspended, 0, msg=errors)
    assert_true(worker_alive(original_worker))
    @fs.write_file(directory + "/rpc-unavailable", "")
    env.set("ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS", "500")
    let started = @env.now()
    let (status, _, errors) = invoke("resume", env, directory, payload~)
    assert_true(status != 0)
    assert_true(errors.contains("readiness timed out after 500 ms"))
    assert_true(@env.now() - started >= 500)
    assert_true(@env.now() - started < 5000)
    let base = directory + "/.local/state/orca-env-devsy/tunnels"
    let worker = base + "/" + @fs.readdir(base)[0]
    assert_true(worker_alive(worker))
    assert_true(@fs.exists(directory + "/created"))
    env.remove("ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS")
    @fs.remove(directory + "/rpc-unavailable")
    @fs.write_file(worker + "/probe-request", "")
    @async.with_timeout(5000, async fn() {
      while field(
              @json.parse(@fs.read_file(worker + "/status.json").text()),
              "status",
            ) !=
            Some(Json::string("connected")) {
        @async.sleep(100)
      }
    })
    assert_true(worker_alive(worker))
    let before = @fs.read_file(directory + "/master-pid").text()
    let (resumed, output, errors) = invoke("resume", env, directory, payload~)
    assert_eq(resumed, 0, msg=errors)
    let resumed_result = @json.parse(output)
    assert_eq(
      field(field(resumed_result, "userData").unwrap(), "tunnelDirectory"),
      Some(Json::string(worker)),
    )
    assert_eq(@fs.read_file(directory + "/master-pid").text(), before)
    assert_eq(@fs.readdir(base).length(), 1)
    let (destroyed, _, errors) = invoke("destroy", env, directory, payload={
      "schemaVersion": 1,
      "recipeResult": resumed_result,
    })
    assert_eq(destroyed, 0, msg=errors)
  })
}

///|
async test "recover restores an externally stopped then started workspace and its server" {
  for receipt in [false, true] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    with_fake_tunnel(directory, async fn() {
      @fs.write_file(
        directory + "/orca.yaml",
        "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
      )
      let (status, output, errors) = invoke("create", env, directory)
      assert_eq(status, 0, msg=errors)
      let result = @json.parse(output)
      let state = field(result, "userData").unwrap()
      let worker = required(state, "tunnelDirectory")
      let payload : Json = { "schemaVersion": 1, "recipeResult": result }
      defer ignore(invoke("destroy", env, directory, payload~))
      let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
      assert_eq(field(saved, "projectRoot"), field(state, "projectRoot"))
      @fs.write_file(directory + "/stopped", "")
      @fs.remove(required(saved, "socketDirectory") + "/socket")
      wait_worker_status(worker, "workspace-stopped")
      @fs.remove(directory + "/served")
      @fs.write_file(directory + "/args", "")
      let (status, _, errors) = invoke(
        "recover",
        env,
        directory,
        payload?=if receipt { Some(payload) } else { None },
      )
      assert_eq(status, 0, msg=errors)
      assert_true(worker_alive(worker))
      assert_false(@fs.exists(directory + "/served"))
      @fs.remove(directory + "/stopped")
      @fs.write_file(directory + "/ssh-args", "")
      let (status, restored, errors) = invoke(
        "recover",
        env,
        directory,
        payload?=if receipt { Some(payload) } else { None },
      )
      assert_eq(status, 0, msg=errors)
      assert_true(worker_alive(worker))
      assert_true(@fs.exists(directory + "/served"))
      assert_eq(
        @fs.read_file(directory + "/serve-count").text(),
        "serve\nserve\n",
      )
      let after = @json.parse(@fs.read_file(worker + "/state.json").text())
      assert_eq(field(after, "localPort"), field(saved, "localPort"))
      assert_eq(field(after, "workspaceUid"), field(saved, "workspaceUid"))
      if receipt {
        assert_eq(
          field(@json.parse(restored), "connection"),
          field(result, "connection"),
        )
      } else {
        assert_eq(restored, "")
      }
      let commands = @fs.read_file(directory + "/args").text()
      for operation in ["up", "stop", "delete"] {
        assert_false(commands.contains("workspace\n" + operation + "\n"))
      }
      assert_false(
        @fs.read_file(directory + "/ssh-args")
        .text()
        .contains("releases/latest"),
      )
      let (status, _, errors) = invoke("recover", env, directory)
      assert_eq(status, 0, msg=errors)
      assert_eq(
        @fs.read_file(directory + "/serve-count").text(),
        "serve\nserve\n",
      )
    })
  }
}

///|
async test "workspace recover and restart reject Busy without replacing a live worker" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  let worker = required(state, "tunnelDirectory")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  defer ignore(invoke("destroy", env, directory, payload~))
  let saved = @fs.read_file(worker + "/state.json").text()
  let pid = @fs.read_file(directory + "/master-pid").text()
  @fs.write_file(directory + "/busy", "")
  for mode in ["recover", "restart"] {
    for receipt in [false, true] {
      if mode == "restart" && !receipt {
        continue
      }
      let started = @env.now()
      let (status, _, _) = invoke(
        mode,
        env,
        directory,
        payload?=if receipt { Some(payload) } else { None },
      )
      assert_true(status != 0)
      assert_true(@env.now() - started < 5000)
      assert_true(worker_alive(worker))
      assert_eq(@fs.read_file(worker + "/state.json").text(), saved)
      assert_eq(@fs.read_file(directory + "/master-pid").text(), pid)
    }
  }
  let (status, _, _) = invoke("restart", env, directory)
  assert_true(status != 0)
  assert_false(worker_alive(worker))
  assert_eq(@fs.read_file(worker + "/state.json").text(), saved)
  @fs.remove(directory + "/busy")
  let (status, _, errors) = invoke("recover", env, directory)
  assert_eq(status, 0, msg=errors)
  let records = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(
    records.contains("\"stage\":\"recover-workspace\",\"status\":\"Busy\""),
  )
}

///|
async test "recover reports server startup failure without installing or resetting a live worker" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let worker = required(state, "tunnelDirectory")
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    let saved = @fs.read_file(worker + "/state.json").text()
    let pid = @fs.read_file(directory + "/master-pid").text()
    @fs.remove(directory + "/served")
    @fs.write_file(directory + "/fail-serve", "")
    @fs.write_file(directory + "/ssh-args", "")
    let (status, _, _) = invoke("recover", env, directory)
    assert_true(status != 0)
    assert_true(worker_alive(worker))
    assert_eq(@fs.read_file(worker + "/state.json").text(), saved)
    assert_eq(@fs.read_file(directory + "/master-pid").text(), pid)
    let commands = @fs.read_file(directory + "/ssh-args").text()
    assert_true(commands.contains("--recipe-json"))
    assert_false(commands.contains("releases/latest"))
    assert_false(commands.contains("-O\nexit\n"))
    @fs.remove(directory + "/fail-serve")
    let (status, _, errors) = invoke("recover", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_true(@fs.exists(directory + "/served"))
  })
}

///|
async test "receipt recovery skips a sleeping workspace and recovers its retained monitor after external up" {
  for mode in ["recover", "restart"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let worker = required(state, "tunnelDirectory")
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    let (status, _, errors) = invoke("suspend", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_true(worker_alive(worker))
    let (status, _, errors) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_true(worker_alive(worker))
    @fs.remove(directory + "/stopped")
    let (status, _, errors) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_true(worker_alive(worker))
    let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
    assert_eq(field(saved, "projectRoot"), field(state, "projectRoot"))
  }
}

///|
async test "server probe finishes after the upgrade headers while the websocket stays open" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      let (connection, _) = server.accept()
      defer connection.close()
      assert_eq(connection.read_exactly(4), b"GET ")
      connection.write(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n",
      )
      @async.sleep(5000)
    })
    let script = server_probe_script().replace_all(
      old="http://127.0.0.1:47121/",
      new="http://127.0.0.1:" + server.addr.port().to_string() + "/",
    )
    let (status, output, _) = @async.with_timeout(1500, async fn() {
      @process.collect_output("/bin/sh", ["-c", script])
    })
    assert_eq(status, 0)
    assert_eq(output.text(), "101")
  })
}

///|
async fn wait_worker_status(directory : String, expected : String) -> Unit {
  @async.with_timeout(20000, async fn() {
    while true {
      if @fs.exists(directory + "/status.json") &&
        field(
          @json.parse(@fs.read_file(directory + "/status.json").text()),
          "status",
        ) ==
        Some(Json::string(expected)) {
        return
      }
      @async.sleep(25)
    }
  })
}

///|
test "stopped monitoring backs off to five minutes and resets after recovery" {
  assert_eq([0, 1, 2, 3, 4, 5, 100].map(monitor_delay), [
    15000, 30000, 60000, 120000, 300000, 300000, 300000,
  ])
}

///|
async test "external stop and sleep retain a monitor that automatically restores the server" {
  for sleep in [false, true] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    env.set("ORCA_ENV_DEVSY_TEST_MONITOR_DELAY_MS", "500")
    with_fake_tunnel(directory, async fn() {
      @fs.write_file(
        directory + "/orca.yaml",
        "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
      )
      let (code, output, errors) = invoke("create", env, directory)
      assert_eq(code, 0, msg=errors)
      let result = @json.parse(output)
      let state = field(result, "userData").unwrap()
      let worker = required(state, "tunnelDirectory")
      let payload : Json = { "schemaVersion": 1, "recipeResult": result }
      defer ignore(invoke("destroy", env, directory, payload~))
      if sleep {
        let (code, _, errors) = invoke("suspend", env, directory, payload~)
        assert_eq(code, 0, msg=errors)
      } else {
        @fs.write_file(directory + "/stopped", "")
        @fs.write_file(directory + "/drop-tunnel", "")
      }
      wait_worker_status(worker, "workspace-stopped")
      assert_true(worker_alive(worker))
      @fs.remove(directory + "/served")
      @fs.write_file(directory + "/args", "")
      @fs.remove(directory + "/stopped")
      wait_worker_status(worker, "connected")
      assert_true(@fs.exists(directory + "/served"))
      assert_eq(
        @fs.read_file(directory + "/serve-count").text(),
        "serve\nserve\n",
      )
      let commands = @fs.read_file(directory + "/args").text()
      assert_true(commands.contains("--container-status=false"))
      for operation in ["up", "stop", "delete"] {
        assert_false(commands.contains("workspace\n" + operation + "\n"))
      }
      let events = @fs.read_file(
        directory + "/.local/state/orca-env-devsy/events.jsonl",
      ).text()
      assert_true(events.contains("monitor-wait"))
      assert_true(events.contains("500"))
      @fs.write_file(directory + "/stopped", "")
      @fs.write_file(directory + "/drop-tunnel", "")
      wait_worker_status(worker, "workspace-stopped")
      @async.with_timeout(5000, async fn() {
        while monitor_wait_events(directory).length() < 2 {
          @async.sleep(25)
        }
      })
      let waits = monitor_wait_events(directory)
      assert_eq(waits.length(), 2)
      for event in waits {
        assert_eq(field(event, "attempt"), Some(Json::number(0)))
        assert_eq(field(event, "retryDelayMs"), Some(Json::number(500)))
      }
    })
  }
}

///|
async test "monitor retains Busy and query failures but terminates on UID replacement" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, output, errors) = invoke("create", env, directory)
  assert_eq(code, 0, msg=errors)
  let state = field(@json.parse(output), "userData").unwrap()
  let worker = required(state, "tunnelDirectory")
  let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
  @fs.write_file(directory + "/busy", "")
  @fs.remove(required(saved, "socketDirectory") + "/socket")
  wait_worker_status(worker, "workspace-busy")
  assert_true(worker_alive(worker))
  let before = @fs.read_file(directory + "/ssh-args")
    .text()
    .split("-N\n")
    .count()
  @fs.write_file(directory + "/fail-status", "")
  @fs.write_file(worker + "/probe-request", "")
  @async.with_timeout(5000, async fn() {
    while !@fs.read_file(
            directory + "/.local/state/orca-env-devsy/events.jsonl",
          )
          .text()
          .contains("workspace_query_failed") {
      @async.sleep(25)
    }
  })
  let monitor_failures = fixture_events(directory).filter(event => {
    field(event, "stage") == Some(Json::string("orca-tunnel")) &&
    field(event, "errorType") == Some(Json::string("workspace_query_failed"))
  })
  assert_true(monitor_failures.length() > 0)
  assert_true(
    required(monitor_failures[monitor_failures.length() - 1], "errorMessage").contains(
      "workspace-status failed (exit 1)",
    ),
  )
  assert_true(worker_alive(worker))
  assert_true(@fs.exists(worker + "/enabled"))
  assert_eq(
    @fs.read_file(directory + "/ssh-args").text().split("-N\n").count(),
    before,
  )
  @fs.remove(directory + "/fail-status")
  @fs.write_file(directory + "/uid", "replacement-uid")
  @fs.write_file(worker + "/probe-request", "")
  @async.with_timeout(5000, async fn() {
    while worker_alive(worker) {
      @async.sleep(25)
    }
  })
  assert_false(@fs.exists(worker + "/enabled"))
  let events = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(events.contains("replacement-uid"))
  assert_true(events.contains("expectedWorkspaceUid"))
  assert_true(events.contains("replaced"))
}

///|
async test "concurrent resume sleep and destroy serialize without recreating a deleted workspace" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, output, errors) = invoke("create", env, directory)
  assert_eq(code, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  let worker = required(state, "tunnelDirectory")
  @fs.write_file(
    directory + "/concurrent.json",
    ({ "schemaVersion": 1, "recipeResult": result } : Json).stringify(),
  )
  let run = async fn(mode : String) {
    @process.collect_output(
      integration_binary(),
      ["recipe", mode],
      extra_env=env,
      stdin=@process.redirect_from_file(directory + "/concurrent.json"),
    )
  }
  @async.with_timeout(15000, async fn() {
    @async.with_task_group(async fn(group) {
      let resumed = group.spawn(async fn() { run("resume") })
      let (code, _, errors) = run("suspend")
      assert_eq(code, 0, msg=errors.text())
      let (code, _, errors) = resumed.wait()
      assert_eq(code, 0, msg=errors.text())
    })
  })
  assert_true(worker_alive(worker))
  @async.with_timeout(15000, async fn() {
    @async.with_task_group(async fn(group) {
      let resumed = group.spawn(async fn() { run("resume") })
      let recovered = group.spawn(async fn() {
        invoke("recover", env, directory)
      })
      let (code, _, errors) = run("destroy")
      assert_eq(code, 0, msg=errors.text())
      ignore(resumed.wait())
      ignore(recovered.wait())
    })
  })
  assert_false(@fs.exists(directory + "/created"))
  assert_false(@fs.exists(worker + "/enabled"))
  if @fs.exists(worker) {
    assert_false(worker_alive(worker))
  }
}

///|
async fn fixture_events(directory : String) -> Array[Json] {
  let file = @fs.open(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
    mode=ReadOnly,
  )
  defer file.close()
  let buffer = FixedArray::make(file.size().to_int(), b'\x00')
  let size = file.read_at(buffer, position=0L)
  let mut complete = size
  while complete > 0 && buffer[complete - 1] != b'\n' {
    complete -= 1
  }
  let content = @utf8.decode(buffer.unsafe_reinterpret_as_bytes()[:complete])
  let events = []
  let lines = content.split("\n").to_array()
  for index in 0..<(lines.length() - 1) {
    events.push(@json.parse(lines[index].to_owned()))
  }
  events
}

///|
async fn fixture_failure_events(directory : String) -> String {
  let events = fixture_events(directory)
    .map(event => event.stringify())
    .join("\n") catch {
      error => "diagnostic read failed: " + error.to_string()
    }
  redact_credentials(events).replace_all(
    old="ghp_fixtureprivatetoken123",
    new="[redacted]",
  )
}

///|
test "diagnostic errors retain context and mask environment credentials" {
  let detail = diagnostic_error(
    AdapterError("operation failed: fixture-sensitive-value"),
    environment={ "ACCESS_TOKEN": "fixture-sensitive-value" },
  )
  assert_eq(detail, "operation failed: [redacted]")
  assert_eq(
    AdapterError("connection refused").to_string(),
    "connection refused",
  )
  assert_eq(InvalidConfig("invalid recipe").to_string(), "invalid recipe")
  assert_eq(
    Show::to_string(SettingsProcessError("write", "ENOSPC", 1)),
    "Orca settings process failed (exit 1, write: ENOSPC)",
  )
}

///|
async test "fixture event snapshots only parse complete records" {
  let directory = @fs.tmpdir(prefix="orca-event-snapshot")
  defer @fs.rmdir(directory, recursive=true)
  let root = directory + "/.local/state/orca-env-devsy"
  @fs.mkdir(root, recursive=true)
  let path = root + "/events.jsonl"
  @fs.write_file(path, "{\"stage\":\"first\"}\n{\"stage\":\"")
  assert_eq(fixture_events(directory).length(), 1)
  @fs.write_file(path, b"\xe3", append=true, create_mode=OpenOrCreate)
  assert_eq(fixture_events(directory).length(), 1)
  @fs.write_file(path, b"\x81\x82\"}\n", append=true, create_mode=OpenOrCreate)
  let events = fixture_events(directory)
  assert_eq(events.length(), 2)
  assert_eq(field(events[1], "stage"), Some(Json::string("あ")))
}

///|
async fn monitor_wait_events(directory : String) -> Array[Json] {
  let events = []
  for event in fixture_events(directory) {
    if field(event, "stage") == Some(Json::string("monitor-wait")) {
      events.push(event)
    }
  }
  events
}

///|
async test "long monitor and connection retry waits yield to pause wake and shutdown" {
  let directory = @fs.tmpdir(prefix="orca-monitor-wait")
  defer @fs.rmdir(directory, recursive=true)
  for action in ["paused", "probe-request", "disabled"] {
    @fs.write_file(directory + "/enabled", "")
    let started = @env.now()
    @async.with_timeout(2000, async fn() {
      @async.with_task_group(async fn(group) {
        let waiting = group.spawn(async fn() { monitor_wait(directory, 300000) })
        @async.sleep(100)
        if action == "disabled" {
          @fs.remove(directory + "/enabled")
        } else {
          @fs.write_file(directory + "/" + action, "")
        }
        waiting.wait()
      })
    })
    assert_true(@env.now() - started < 2000)
    if action != "disabled" {
      @fs.remove(directory + "/" + action)
    }
  }
  assert_eq(pause_request(directory), None)
  @fs.write_file(directory + "/paused", "first-request")
  assert_eq(pause_request(directory), Some("first-request"))
  @fs.remove(directory + "/paused")
  assert_eq(pause_request(directory), None)
}

///|
async test "invalid connection budgets fail before resuming a workspace" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, output, errors) = invoke("create", env, directory)
  assert_eq(code, 0, msg=errors)
  let payload : Json = {
    "schemaVersion": 1,
    "recipeResult": @json.parse(output),
  }
  defer {
    env.remove("ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS")
    ignore(invoke("destroy", env, directory, payload~))
  }
  @fs.write_file(directory + "/args", "")
  for value in ["0", "-1", "invalid", "2147483648"] {
    env.set("ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS", value)
    let (code, _, errors) = invoke("resume", env, directory, payload~)
    assert_true(code != 0)
    assert_true(errors.contains("must be positive milliseconds"))
  }
  assert_false(
    @fs.read_file(directory + "/args").text().contains("workspace\nup\n"),
  )
}

///|
async test "storage and project configuration failures do not publish a recipe" {
  for failure in ["fail-storage", "fail-project"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    with_fake_tunnel(directory, async fn() {
      @fs.write_file(
        directory + "/orca.yaml",
        "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
      )
      @fs.write_file(directory + "/" + failure, "")
      let (status, output, _) = invoke("create", env, directory)
      assert_true(status != 0)
      assert_eq(output, "")
      assert_false(@fs.exists(directory + "/created"))
      let events = @fs.read_file(
        directory + "/.local/state/orca-env-devsy/events.jsonl",
      ).text()
      assert_true(
        events.contains(
          if failure == "fail-storage" {
            "orca-storage"
          } else {
            "orca-project-register"
          },
        ),
      )
      assert_false(events.contains("fixture-pairing"))
    })
  }
}

///|
async test "worker recovery reinstalls a missing server into the retained profile" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main, orca-server: {env: {PATH: '${DEVSY_REMOTE_WORKSPACE_FOLDER?}/.local/bin:${PATH?}'}}}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let payload : Json = {
      "schemaVersion": 1,
      "recipeResult": @json.parse(output),
    }
    defer ignore(invoke("destroy", env, directory, payload~))
    @fs.remove(directory + "/served")
    @fs.write_file(directory + "/missing-orca", "")
    @fs.write_file(directory + "/ssh-args", "")
    let (status, _, errors) = invoke("recover", env, directory)
    assert_eq(status, 0, msg=errors)
    let commands = @fs.read_file(directory + "/ssh-args").text()
    assert_true(commands.contains("releases/latest"))
    assert_true(commands.contains("/workspace/repo"))
    assert_true(commands.contains(".local/bin:"))
    assert_true(commands.contains("ORCA_USER_DATA_PATH=/worktrees/.orca"))
    assert_false(@fs.exists(directory + "/missing-orca"))
  })
}

///|
async test "volume cleanup respects the saved target and never changes destroy success" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let volume = required(state, "orcaVolume")
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    let plan = field(state, "orcaVolumeCleanup").unwrap()
    assert_eq(optional_text(plan, "mode"), "local")
    assert_eq(required(plan, "program"), directory + "/bin/runtime")
    @fs.write_file(directory + "/fail-delete", "")
    let (status, _, _) = invoke("destroy", env, directory, payload~)
    assert_true(status != 0)
    assert_false(@fs.exists(directory + "/volume-args"))
    @fs.remove(directory + "/fail-delete")
    for failure in ["fail-volume-list", "fail-volume-remove"] {
      @fs.write_file(directory + "/" + failure, "")
      let (status, output, errors) = invoke("destroy", env, directory, payload~)
      assert_eq(status, 0, msg=errors)
      assert_eq(output, "")
      assert_true(errors.contains("warning: Orca volume " + volume))
      assert_true(@fs.exists(directory + "/volume-present"))
      @fs.remove(directory + "/" + failure)
    }
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_false(@fs.exists(directory + "/volume-present"))
    @fs.remove(directory + "/volume-args")
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_eq(
      @fs.read_file(directory + "/volume-args").text(),
      "volume\nls\n--format\njson\n",
    )
    for runtime in ["docker", "podman"] {
      set_field(plan, "runtime", Json::string(runtime))
      @fs.write_file(directory + "/volume-present", "")
      @fs.write_file(
        directory + "/volume-list",
        if runtime == "docker" {
          "{\"Name\":\"unrelated\"}\n{\"Name\":\"" + volume + "\"}\n"
        } else {
          "[{\"Name\":\"unrelated\"},{\"Name\":\"" + volume + "\"}]"
        },
      )
      let (status, _, errors) = invoke("destroy", env, directory, payload~)
      assert_eq(status, 0, msg=errors)
      assert_false(@fs.exists(directory + "/volume-present"))
    }
    @fs.remove(directory + "/volume-args")
    set_field(state, "orcaVolume", Json::string("foreign-volume"))
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_true(errors.contains("does not match the saved workspace UID"))
    assert_false(@fs.exists(directory + "/volume-args"))
    let events = @fs.read_file(
      env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(events.contains("runtime unavailable"))
    assert_true(events.contains("volume is in use"))
  })
}

///|
async test "failed server creation reclaims only the assigned volume" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  @fs.write_file(directory + "/fail-up", "")
  let (status, _, _) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_false(@fs.exists(directory + "/created"))
  assert_false(@fs.exists(directory + "/volume-present"))
  assert_true(@fs.read_file(directory + "/volume-args").text().contains("rm\n"))
}

///|
async test "server environment resolves remote values without shell evaluation" {
  let directory = @fs.tmpdir(prefix="orca-server-env")
  defer cleanup_fixture(directory)
  let install = directory + "/.local/share/orca-env-devsy/orca/current"
  @fs.mkdir(install + "/resources/app.asar/out/cli", recursive=true)
  let bun = command("which", ["bun"], "fixture-bun").trim().to_owned()
  @fs.symlink(install + "/orca-ide", target=bun)
  @fs.write_file(
    install + "/resources/app.asar/out/cli/index.js",
    "console.log(process.env.PATH); console.log(process.env.LITERAL); console.log(process.env.COPY); console.log(process.env.HOME); console.log(process.env.PPID);\n",
  )
  let env = @env.get_env_vars()
  env.set("HOME", directory)
  env.set("PATH", "/usr/bin:/bin")
  env.set("LITERAL", "remote original")
  let settings : Json = {
    "PATH": "${DEVSY_REMOTE_WORKSPACE_FOLDER?}/.local/bin:${PATH?}",
    "LITERAL": "$(touch injected); 'quoted'",
    "COPY": "${LITERAL?}",
    "HOME": "/another-home",
    "PPID": "fixture-ppid",
  }
  let output = command(
    "sh",
    ["-c", server_launch_script("/work space", 12345, settings)],
    "fixture-serve-env",
    environment=env,
  )
  assert_eq(
    output, "/work space/.local/bin:/usr/bin:/bin\n$(touch injected); 'quoted'\nremote original\n/another-home\nfixture-ppid\n",
  )
  assert_false(@fs.exists(directory + "/injected"))
}

///|
async test "server environment observations distinguish remote values and mask credentials" {
  let directory = @fs.tmpdir(prefix="orca-server-observation")
  defer cleanup_fixture(directory)
  let install = directory + "/.local/share/orca-env-devsy/orca/current"
  @fs.mkdir(install + "/resources/app.asar/out/cli", recursive=true)
  let bun = command("which", ["bun"], "fixture-bun").trim().to_owned()
  @fs.symlink(install + "/orca-ide", target=bun)
  @fs.write_file(
    install + "/resources/app.asar/out/cli/index.js",
    "console.log(process.env.PPID_COPY);\n",
  )
  let env = @env.get_env_vars()
  env.set("HOME", directory)
  env.set("PATH", "/fixture/bin:/usr/bin")
  env.set("EMPTY_OBSERVATION", "")
  env.remove("MISSING_OBSERVATION")
  env.set("AWS_SECRET_ACCESS_KEY", "synthetic-secret-value")
  env.set("AZURE_STORAGE_KEY", "synthetic-azure-secret")
  env.set("SECRET_ALIAS", "synthetic-alias-secret")
  env.set("NPM_CONFIG__AUTH", "ZmFrZTpwYXNzd29yZA==")
  env.set(
    "BEARER_OBSERVATION", "{\"note\":\"Bearer synthetic-bearer-value\",\"next\":\"ok\"}",
  )
  env.set("LONG_OBSERVATION", "x".repeat(25000))
  env.set("BAD_QUERY", "https://example.com/?%zz=x")
  env.set(
    "VALUE_OBSERVATION", "context Authorization: Bearer ghp_fixturetoken and tail",
  )
  let config : Json = {
    "PATH": "${DEVSY_REMOTE_WORKSPACE_FOLDER?}:${PATH?}",
    "A": "${EMPTY_OBSERVATION}",
    "B": "${MISSING_OBSERVATION}",
    "C": "${AWS_SECRET_ACCESS_KEY?}",
    "D": "${VALUE_OBSERVATION?}",
    "E": "${AZURE_STORAGE_KEY?}",
    "F": "${LONG_OBSERVATION?}",
    "G": "${BAD_QUERY?}",
    "AWS_SECRET_ACCESS_KEY": "${SECRET_ALIAS?}",
    "NONSECRET_ALIAS": "${SECRET_ALIAS?}",
    "PPID_COPY": "${PPID?}",
    "NPM_COPY": "${NPM_CONFIG__AUTH?}",
    "BEARER_COPY": "${BEARER_OBSERVATION?}",
  }
  let output = command(
    "sh",
    ["-c", server_launch_script("/work space", 12345, config, recording=true)],
    "fixture-observation",
    environment=env,
  )
  assert_false(output.contains("synthetic-secret-value"))
  assert_false(output.contains("ghp_fixturetoken"))
  assert_false(output.contains("synthetic-azure-secret"))
  assert_false(output.contains("synthetic-alias-secret"))
  assert_false(output.contains("ZmFrZTpwYXNzd29yZA=="))
  assert_false(output.contains("synthetic-bearer-value"))
  guard output.split_once("\n") is Some((event_line, shell_ppid)) else {
    fail("missing observation")
  }
  let event = @json.parse(event_line.to_owned())
  let refs = field(event, "serverEnvironment").unwrap()
  assert_eq(
    field(field(refs, "BEARER_OBSERVATION").unwrap(), "value"),
    Some(Json::string("{\"note\":\"Bearer [redacted]\",\"next\":\"ok\"}")),
  )
  assert_eq(
    field(field(refs, "SECRET_ALIAS").unwrap(), "value"),
    Some(Json::string("[redacted]")),
  )
  assert_eq(
    field(field(refs, "PPID").unwrap(), "value"),
    Some(Json::string(shell_ppid.trim().to_owned())),
  )
  assert_true(event.stringify().contains("LONG_OBSERVATION"))
  assert_eq(
    field(field(refs, "AZURE_STORAGE_KEY").unwrap(), "value"),
    Some(Json::string("[redacted]")),
  )
  assert_eq(
    field(field(refs, "LONG_OBSERVATION").unwrap(), "truncated"),
    Some(Json::boolean(true)),
  )
  assert_eq(
    field(field(refs, "PATH").unwrap(), "value"),
    Some(Json::string("/fixture/bin:/usr/bin")),
  )
  assert_eq(
    field(field(refs, "EMPTY_OBSERVATION").unwrap(), "state"),
    Some(Json::string("empty")),
  )
  assert_eq(
    field(field(refs, "MISSING_OBSERVATION").unwrap(), "state"),
    Some(Json::string("unset")),
  )
  assert_eq(
    field(field(refs, "AWS_SECRET_ACCESS_KEY").unwrap(), "value"),
    Some(Json::string("[redacted]")),
  )
  assert_true(
    required(field(refs, "VALUE_OBSERVATION").unwrap(), "value").contains(
      "context",
    ),
  )
  assert_eq(
    field(field(refs, "DEVSY_REMOTE_WORKSPACE_FOLDER").unwrap(), "value"),
    Some(Json::string("/work space")),
  )
}

///|
async test "dynamic shell references are expanded once with recording enabled or disabled" {
  let directory = @fs.tmpdir(prefix="orca-server-dynamic")
  defer cleanup_fixture(directory)
  let install = directory + "/.local/share/orca-env-devsy/orca/current"
  @fs.mkdir(install + "/resources/app.asar/out/cli", recursive=true)
  let bun = command("which", ["bun"], "fixture-bun").trim().to_owned()
  @fs.symlink(install + "/orca-ide", target=bun)
  @fs.write_file(
    install + "/resources/app.asar/out/cli/index.js",
    "console.log(process.env.COPY);\n",
  )
  let env = @env.get_env_vars()
  env.set("HOME", directory)
  let config : Json = { "COPY": "${RANDOM?}" }
  let recorded = command(
    "bash",
    ["-c", server_launch_script("/workspace", 12345, config, recording=true)],
    "fixture-dynamic",
    environment=env,
  )
  guard recorded.split_once("\n") is Some((line, actual)) else {
    fail("missing observation")
  }
  let event = @json.parse(line.to_owned())
  let refs = field(event, "serverEnvironment").unwrap()
  assert_eq(
    field(field(refs, "RANDOM").unwrap(), "value"),
    Some(Json::string(actual.trim().to_owned())),
  )
  let disabled = command(
    "bash",
    ["-c", server_launch_script("/workspace", 12345, config)],
    "fixture-dynamic",
    environment=env,
  )
  assert_true(
    disabled.trim().to_owned().to_array().iter().all(c => c >= '0' && c <= '9'),
  )
}

///|
async test "normal server launch retains redacted remote environment diagnostics" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    let install = directory + "/.local/share/orca-env-devsy/orca/current"
    @fs.mkdir(install + "/resources/app.asar/out/cli", recursive=true)
    let bun = command("which", ["bun"], "fixture-bun").trim().to_owned()
    @fs.symlink(install + "/orca-ide", target=bun)
    @fs.write_file(
      install + "/resources/app.asar/out/cli/index.js",
      "console.log(JSON.stringify({connection:{pairingCode:'fixture-pairing'}}));\n",
    )
    @fs.write_file(directory + "/real-serve", "")
    env.set("NPM_CONFIG__AUTH", "ZmFrZTpwYXNzd29yZA==")
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main, orca-server: {env: {PATH: '${DEVSY_REMOTE_WORKSPACE_FOLDER?}/.local/bin:${PATH?}', COPY: '${NPM_CONFIG__AUTH?}'}}}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let payload : Json = {
      "schemaVersion": 1,
      "recipeResult": @json.parse(output),
    }
    defer ignore(invoke("destroy", env, directory, payload~))
    let log = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_false(log.contains("ZmFrZTpwYXNzd29yZA=="))
    assert_true(log.contains("server-environment"))
    assert_true(log.contains("NPM_CONFIG__AUTH"))
    assert_true(log.contains("[redacted]"))
    assert_true(log.contains("/workspace/repo"))
  })
}

///|
async test "server update marker preserves configured environment" {
  let directory = @fs.tmpdir(prefix="orca-update-env")
  defer cleanup_fixture(directory)
  let install = directory + "/.local/share/orca-env-devsy/orca/current"
  @fs.mkdir(install + "/resources/app.asar/out/cli", recursive=true)
  let bun = command("which", ["bun"], "fixture-bun").trim().to_owned()
  @fs.symlink(install + "/orca-ide", target=bun)
  @fs.write_file(
    install + "/resources/app.asar/out/cli/index.js",
    "console.log(process.env.ORCA_ENV_DEVSY_SERVER_UPDATE_VERSION + ':' + process.env.ORCA_ENV_DEVSY_UPDATE_123);\n",
  )
  let env = @env.get_env_vars()
  env.set("HOME", directory)
  env.remove("ORCA_ENV_DEVSY_UPDATE_123")
  let settings : Json = { "ORCA_ENV_DEVSY_SERVER_UPDATE_VERSION": "user-value" }
  let output = command(
    "sh",
    [
      "-c",
      server_launch_script(
        "/work",
        12345,
        settings,
        update_marker=("ORCA_ENV_DEVSY_UPDATE_123", "owned"),
      ),
    ],
    "fixture-update-env",
    environment=env,
  )
  assert_eq(output, "user-value:owned\n")
}

///|
async test "remote update marker rejects overlap and permits retry after completion" {
  let directory = @fs.tmpdir(prefix="orca-update-marker")
  defer cleanup_fixture(directory)
  @fs.mkdir(directory + "/.local/share/orca-env-devsy/orca", recursive=true)
  let env = @env.get_env_vars()
  env.set("HOME", directory)
  let first = server_update_locked(
    "touch \"$HOME/started\"; while ! test -f \"$HOME/finish\"; do sleep 0.05; done",
  )
  let second = server_update_locked("touch \"$HOME/second\"")
  @async.with_timeout(10000, async fn() {
    @async.with_task_group(async fn(group) {
      let task = group.spawn(async fn() {
        @process.collect_output("sh", ["-c", first], extra_env=env)
      })
      while !@fs.exists(directory + "/started") {
        @async.sleep(10)
      }
      let (busy, _, _) = @process.collect_output(
        "sh",
        ["-c", second],
        extra_env=env,
      )
      assert_true(busy != 0)
      assert_false(@fs.exists(directory + "/second"))
      @fs.write_file(directory + "/finish", "")
      let (code, _, errors) = task.wait()
      assert_eq(code, 0, msg=errors.text())
    })
  })
  let (code, _, errors) = @process.collect_output(
    "sh",
    ["-c", second],
    extra_env=env,
  )
  assert_eq(code, 0, msg=errors.text())
  assert_true(@fs.exists(directory + "/second"))
  let marker = directory + "/.local/share/orca-env-devsy/orca/update-active"
  @fs.mkdir(marker)
  let (stale, _, _) = @process.collect_output(
    "sh",
    ["-c", second],
    extra_env=env,
  )
  assert_true(stale != 0)
  assert_true(@fs.exists(marker))
  @fs.rmdir(marker)
  let (cleared, _, errors) = @process.collect_output(
    "sh",
    ["-c", second],
    extra_env=env,
  )
  assert_eq(cleared, 0, msg=errors.text())
}

///|
async test "remote update marker survives caller exit until the child finishes" {
  let directory = @fs.tmpdir(prefix="orca-update-abandon")
  defer cleanup_fixture(directory)
  @fs.mkdir(directory + "/.local/share/orca-env-devsy/orca", recursive=true)
  let env = @env.get_env_vars()
  env.set("HOME", directory)
  let first = "printf '%s\\n' \"$$\" > \"$HOME/parent\"; " +
    server_update_locked(
      "touch \"$HOME/started\"; while ! test -f \"$HOME/finish\"; do sleep 0.05; done",
    )
  let retry = server_update_locked("touch \"$HOME/retried\"")
  @async.with_timeout(10000, async fn() {
    @async.with_task_group(async fn(group) {
      let task = group.spawn(async fn() {
        @process.collect_output("sh", ["-c", first], extra_env=env)
      })
      while !@fs.exists(directory + "/started") {
        @async.sleep(10)
      }
      let pid = @fs.read_file(directory + "/parent").text().trim().to_owned()
      assert_eq(@process.run("kill", ["-TERM", pid]), 0)
      @async.sleep(100)
      let (busy, _, _) = @process.collect_output(
        "sh",
        ["-c", retry],
        extra_env=env,
      )
      assert_true(busy != 0)
      assert_false(@fs.exists(directory + "/retried"))
      @fs.write_file(directory + "/finish", "")
      let (finished, _, _) = task.wait()
      assert_true(finished != 0)
    })
  })
  let (retried, _, errors) = @process.collect_output(
    "sh",
    ["-c", retry],
    extra_env=env,
  )
  assert_eq(retried, 0, msg=errors.text())
  assert_true(@fs.exists(directory + "/retried"))
}
