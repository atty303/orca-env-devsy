///|
fn integration_binary() -> String {
  @env.get_env_var("ORCA_ENV_DEVSY_TEST_BINARY").unwrap_or(
    @env.current_dir().unwrap() +
    "/_build/native/release/build/cmd/main/main.exe",
  )
}

///|
async fn fixture() -> (String, Map[String, String]) {
  let directory = @fs.tmpdir(prefix="orca-env-devsy-test")
  @fs.mkdir(directory + "/bin")
  let devsy =
    #|#!/bin/sh
    #|set -eu
    #|printf '%s\n' "$@" >> "$FAKE_HOME/args"
    #|previous=
    #|for arg in "$@"; do
    #|  if test "$previous" = --uid; then printf '%s' "$arg" > "$FAKE_HOME/uid"; fi
    #|  previous="$arg"
    #|done
    #|case "$*" in
    #|  *'context list'*) printf '[{"name":"fixture-context","default":true}]\n' ;;
    #|  *'context get'*) printf '{"SSH_INJECT_GIT_CREDENTIALS":{"default":"true","value":"%s"}}\n' "${FAKE_GIT_FORWARDING:-true}" ;;
    #|  *'workspace list'*)
    #|    if test -f "$FAKE_HOME/block-list"; then
    #|      printf '%s\n' "$$" > "$FAKE_HOME/blocked-list-pid"
    #|      while test ! -f "$FAKE_HOME/release-list"; do sleep 0.1; done
    #|    fi
    #|    if test -f "$FAKE_HOME/created"; then printf '[{"id":"test-id","uid":"%s"}]\n' "$(cat "$FAKE_HOME/uid")"; else printf '[]\n'; fi ;;
    #|  *'workspace status'*) test ! -f "$FAKE_HOME/fail-status"; if test -f "$FAKE_HOME/stopped"; then printf '{"state":"Stopped"}\n'; else printf '{"state":"Running"}\n'; fi ;;
    #|  *'workspace up'*) rm -f "$FAKE_HOME/stopped"; touch "$FAKE_HOME/created"; test ! -f "$FAKE_HOME/fail-up"
    #|    if test -f "$FAKE_HOME/up-result"; then cat "$FAKE_HOME/up-result"; else printf '{"kind":"result","outcome":"success","remoteUser":"developer","remoteWorkspaceFolder":"/workspace/repo"}\n'; fi ;;
    #|  *'workspace stop'*) test ! -f "$FAKE_HOME/fail-stop"; touch "$FAKE_HOME/stopped" ;;
    #|  *'workspace delete'*) test ! -f "$FAKE_HOME/fail-delete"; rm -f "$FAKE_HOME/created" ;;
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
    #|printf '%s\n' "$@" >> "$FAKE_HOME/ssh-args"
    #|control=
    #|previous=
    #|for arg in "$@"; do
    #|  if test "$previous" = -S; then control="$arg"; fi
    #|  previous="$arg"
    #|done
    #|case "$*" in
    #|  *'-N'*) printf '%s\n' "$$" > "$FAKE_HOME/master-pid"; case "$*" in *'--start-services=false'*) printf disabled > "$FAKE_HOME/primary-services" ;; *) printf enabled > "$FAKE_HOME/primary-services" ;; esac ;;
    #|esac
    #|case "$*" in
    #|  *'orca-git-readiness'*)
    #|    touch "$FAKE_HOME/git-probed"
    #|    test -f "$control"
    #|    test ! -f "$FAKE_HOME/git-unavailable" ;;
    #|  *'then printf present; else printf missing; fi'*) if test -f "$FAKE_HOME/task-commit-missing"; then printf missing; else printf present; fi ;;
    #|  *'rev-parse'*'refs/remotes/origin/'*) printf '%s\n' "${FAKE_BUILD_COMMIT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
    #|  *'rev-parse HEAD'*) test ! -f "$FAKE_HOME/fail-root"; printf '%s\n' "${FAKE_BUILD_COMMIT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
    #|  *'Sec-WebSocket-Version'*) if test -f "$FAKE_HOME/reuse-running-server" && test -f "$FAKE_HOME/served"; then printf 101; else printf 000; fi ;;
    #|  *'--recipe-json'*) touch "$FAKE_HOME/served"; printf '{"schemaVersion":1,"connection":{"type":"orca-server","pairingCode":"fixture-pairing","projectRoot":"/workspace/repo"}}\n' ;;
    #|  *'-O check'*)
    #|    if test -f "$FAKE_HOME/fail-tunnel-cleanup"; then
    #|      for state in "$XDG_STATE_HOME/orca-env-devsy/tunnels/"*/state.json; do printf '{invalid' > "$state"; done
    #|    fi
    #|    test -f "$control" ;;
    #|  *'-O exit'*) rm -f "$control" ;;
    #|  *'cat >'* ) test ! -f "$FAKE_HOME/fail-addon"; cat > "$FAKE_HOME/delivered-auth" ;;
    #|  *'-L 127.0.0.1:'* )
    #|    while test "$1" != '-L'; do shift; done
    #|    port=${2#127.0.0.1:}; port=${port%%:*}
    #|    printf '%s\n' "$port" > "$FAKE_HOME/listener-port.tmp"
    #|    mv "$FAKE_HOME/listener-port.tmp" "$FAKE_HOME/listener-port"
    #|    count=0
    #|    while ! test -f "$FAKE_HOME/listener-ready"; do count=$((count+1)); test "$count" -lt 100; sleep 0.01; done
    #|    keeper=
    #|    trap 'rm -f "$control"; if test -n "$keeper"; then kill "$keeper" 2>/dev/null || true; wait "$keeper" 2>/dev/null || true; fi' EXIT HUP INT TERM
    #|    while test -f "$FAKE_HOME/hold-proxy-setup"; do sleep 0.01; done
    #|    if test -f "$FAKE_HOME/keep-proxy-stderr"; then
    #|      sleep 60 & keeper=$!
    #|      printf '%s\n' "$keeper" > "$FAKE_HOME/keeper-pid"
    #|    fi
    #|    touch "$control"
    #|    while test -f "$control"; do
    #|      if test -f "$FAKE_HOME/drop-tunnel"; then rm "$FAKE_HOME/drop-tunnel"; printf "Permission denied (publickey). private-stderr-secret\n" >&2; exit 1; fi
    #|      sleep 0.01
    #|    done ;;
    #|  *'-N'* )
    #|    trap 'rm -f "$control"' EXIT HUP INT TERM
    #|    touch "$control"
    #|    while test -f "$control" && test -f "$FAKE_HOME/created"; do sleep 0.01; done ;;
    #|  *) : ;;
    #|esac
  for pair in [("devsy", devsy), ("git", git), ("ssh", ssh)] {
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
  let executable = integration_binary()
  let input = if payload is Some(value) {
    @fs.write_file(directory + "/stdin.json", value.stringify())
    Some(@process.redirect_from_file(directory + "/stdin.json"))
  } else {
    None
  }
  let (status, stdout, stderr) = @process.collect_output(
    executable,
    if (mode == "reconnect" || mode == "restart") && payload is Some(_) {
      [mode, "--receipt"]
    } else {
      [mode]
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
async test "server CLI emits pairing separately and reconnect does not install or start a server" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    let yaml =
      #|devsy:
      #|  connection: orca-server
      #|  buildRef: refs/heads/main
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
    assert_eq(field(state, "pairingCode"), None)
    assert_false(state.stringify().contains("fixture-pairing"))
    assert_eq(saved_command(state), invocation)
    assert_true(
      @fs.read_file(directory + "/ssh-args")
      .text()
      .contains("ProxyCommand=" + proxy(state, integration_binary())),
    )
    @fs.write_file(directory + "/orca.yaml", "invalid: [")
    @fs.write_file(directory + "/ssh-args", "")
    let (status, output, errors) = invoke("reconnect", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_eq(
      field(@json.parse(output), "connection"),
      field(result, "connection"),
    )
    let commands = @fs.read_file(directory + "/ssh-args")
    assert_true(
      commands
      .text()
      .contains("ProxyCommand=" + proxy(state, integration_binary())),
    )
    assert_false(commands.text().contains("--recipe-json"))
    assert_false(commands.text().contains("releases/latest"))
  })
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
  })
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
      ["-c", server_launch_script(directory, 12345)],
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
  for mode in ["resume", "reconnect", "suspend"] {
    let (status, output, errors) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    if mode != "suspend" {
      assert_eq(field(@json.parse(output), "userData"), Some(state))
    }
  }
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
  for mode in ["resume", "reconnect", "suspend"] {
    let (status, _, errors) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0, msg=errors)
  }
  let before = @fs.read_file(directory + "/args").text()
  set_field(state, "command", [])
  let (status, _, errors) = invoke("destroy", env, directory, payload~)
  assert_true(status != 0)
  assert_true(errors.contains("recipeResult.userData.command"))
  assert_eq(@fs.read_file(directory + "/args").text(), before)
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
    "devsyEnv": {},
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
      #|   printf '%s\n' "$@" >> "$FAKE_HOME/shallow-args"
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
      #|exec "$FAKE_HOME/bin/devsy-original" "$@"
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
    let records = saved_create_events(directory)
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
    #|test ! -f "$CODEX_HOME/fail-refresh"
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
    assert_eq(@fs.exists(directory + "/delivered-auth"), !expired)
  }
}

///|
async test "Git relay loss is monitored without opening another services connection" {
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
    let starts = @fs.read_file(directory + "/ssh-args")
      .text()
      .split("-N\n")
      .count()
    @fs.write_file(directory + "/git-unavailable", "")
    @async.with_timeout(5000, async fn() {
      while @fs.read_file(worker + "/git-status").text() != "unavailable" {
        @async.sleep(10)
      }
    })
    assert_true(worker_alive(worker))
    assert_true(@fs.exists(directory + "/git-unavailable"))
    let events = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(events.contains("readiness_unavailable"))
    @fs.remove(directory + "/git-unavailable")
    @async.with_timeout(5000, async fn() {
      while @fs.read_file(worker + "/git-status").text() != "ready" {
        @async.sleep(10)
      }
    })
    assert_eq(
      @fs.read_file(directory + "/ssh-args").text().split("-N\n").count(),
      starts,
    )
    assert_false(
      @fs.read_file(directory + "/ssh-args")
      .text()
      .contains("credential-socket"),
    )
    @fs.write_file(worker + "/git-established", "")
    let (status, _, errors) = invoke("suspend", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_false(@fs.exists(worker))
  })
}

///|
async test "delayed primary Git readiness does not start a competing services owner" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(directory + "/git-unavailable", "")
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
    let state = field(result, "userData").unwrap()
    assert_eq(
      @fs.read_file(required(state, "tunnelDirectory") + "/git-status").text(),
      "ready",
    )
  })
}

///|
async test "disabled Git forwarding retains primary services without Git readiness probes" {
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
    assert_false(
      @fs.read_file(directory + "/ssh-args")
      .text()
      .contains("orca-git-readiness"),
    )
  })
}

///|
async test "tunnel worker reconnects on the same port and remains running when stop or delete fails" {
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
    let (status, _, errors) = invoke("reconnect", env, directory, payload~)
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
      let (status, _, errors) = invoke("reconnect", env, directory, payload~)
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
      5000,
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
          (creation.wait(), check)
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
    let base = directory + "/.local/state/orca-env-devsy/tunnels"
    let worker = base + "/" + @fs.readdir(base)[0]
    let socket_directory = sockets[0]
      .to_owned()
      .replace_all(old="/socket", new="")
    // Repair only this deliberately corrupted test state so the owned worker can stop.
    @fs.remove(worker + "/state.json")
    @fs.remove(worker + "/enabled")
    @async.with_timeout(5000, async fn() {
      while worker_alive(worker) {
        @async.sleep(100)
      }
    })
    @fs.rmdir(worker, recursive=true)
    @fs.rmdir(socket_directory, recursive=true)
    let records = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(records.contains("create-cleanup-tunnel"))
    assert_true(records.contains("tunnel_cleanup"))
    assert_true(records.contains("create-cleanup"))
  })
}

///|
async test "diagnostics retain only known backend phases and fixed failure classes" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let result =
    #|{"kind":"status","phase":"cloning_repository","state":"started","step":"private-step-secret"}
    #|{"kind":"status","phase":"building_image","state":"failed","error":{"message":"private-error-secret","context":{"token":"private-context-secret"}}}
    #|{"kind":"status","phase":"private-phase-secret","state":"failed"}
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
  assert_true(records.contains("backend_phase"))
  assert_true(records.contains("durationMs"))
  assert_false(records.contains("private-"))
  env.set("ORCA_ENV_DEVSY_RECORDING", "0")
  let (status, _, errors) = invoke("resume", env, directory, payload~)
  assert_eq(status, 0, msg=errors)
  assert_eq(@fs.read_file(path).text(), records)
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
async test "restart replaces live connections through bulk and receipt reconnect" {
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
        assert_true(
          field(after, "socketDirectory") != field(before, "socketDirectory"),
        )
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
  @fs.mkdir(socket, allow_exist=true)
  @fs.write_file(socket + "/socket", "")
  @fs.write_file(worker + "/enabled", "")
  @fs.rename(directory + "/bin/ssh", directory + "/bin/ssh-original")
  let wrapper =
    #|#!/bin/sh
    #|case "$*" in *'-O exit'*) exit 1 ;; esac
    #|exec "$FAKE_HOME/bin/ssh-original" "$@"
  @fs.write_file(directory + "/bin/ssh", wrapper + "\n", permission=0o700)
  @fs.write_file(directory + "/ssh-args", "")
  let (status, _, _) = invoke("restart", env, directory)
  assert_true(status != 0)
  assert_false(worker_alive(worker))
  assert_eq(@fs.read_file(worker + "/state.json").text(), saved)
  assert_false(@fs.read_file(directory + "/ssh-args").text().contains("-N\n"))
  let records = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  let events : Array[Json] = []
  for line in records.split("\n") {
    if line != "" {
      let event = @json.parse(line.to_owned())
      if field(event, "stage") == Some(Json::string("ssh-tunnel-restart")) {
        events.push(event)
      }
    }
  }
  let failure = events.last().unwrap()
  assert_eq(field(failure, "status"), Some(Json::string("timeout")))
  assert_eq(field(failure, "errorType"), Some(Json::string("shutdown_timeout")))
  assert_eq(field(failure, "phase"), Some(Json::string("master")))
  assert_eq(field(failure, "tunnelDirectory"), Some(Json::string(worker)))
  assert_eq(field(failure, "runId"), field(events[0], "runId"))
  @fs.rename(directory + "/bin/ssh-original", directory + "/bin/ssh")
  let (status, _, errors) = invoke("restart", env, directory, payload~)
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
async test "bulk reconnect restores persistent XDG state without a receipt or current YAML" {
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
    @fs.rmdir(required(before, "socketDirectory"), recursive=true)
    @fs.write_file(worker + "/enabled", "")
    @fs.write_file(directory + "/orca.yaml", "invalid: [")
    let (status, output, errors) = invoke("reconnect", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_eq(output, "")
    let after = @json.parse(@fs.read_file(worker + "/state.json").text())
    assert_eq(field(after, "localPort"), field(before, "localPort"))
    assert_eq(field(after, "command"), field(before, "command"))
    assert_true(
      field(after, "socketDirectory") != field(before, "socketDirectory"),
    )
    assert_true(worker_alive(worker))
    let (status, output, errors) = invoke("reconnect", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_eq(output, "")
    assert_eq(@json.parse(@fs.read_file(worker + "/state.json").text()), after)
    let (status, _, errors) = invoke("suspend", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_false(@fs.exists(worker))
    let (status, output, errors) = invoke("reconnect", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_eq(output, "")
  })
}

///|
async test "bulk recovery skips disabled stopped and replaced workspaces and continues past corrupt entries" {
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
    let (status, _, errors) = invoke("reconnect", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_false(worker_alive(worker))
    @fs.write_file(worker + "/enabled", "")
    @fs.write_file(directory + "/stopped", "")
    let args = @fs.read_file(directory + "/ssh-args").text()
    let (status, _, errors) = invoke("reconnect", env, directory)
    assert_eq(status, 0, msg=errors)
    let after = @fs.read_file(directory + "/ssh-args").text()
    assert_eq(after.split("-M\n").count(), args.split("-M\n").count())
    assert_true(@fs.exists(directory + "/stopped"))
    assert_false(worker_alive(worker))
    @fs.remove(directory + "/stopped")
    @fs.mkdir(base + "/blocked")
    let blocked = @json.parse(@fs.read_file(worker + "/state.json").text())
    set_field(blocked, "command", ["/bin/sh", "-c", "exec sleep 60", "sh"])
    @fs.write_file(base + "/blocked/state.json", blocked.stringify())
    @fs.write_file(base + "/blocked/enabled", "")
    @fs.mkdir(base + "/corrupt")
    @fs.write_file(base + "/corrupt/enabled", "")
    @fs.write_file(base + "/corrupt/state.json", "{invalid")
    let (status, _, _) = invoke("reconnect", env, directory)
    assert_true(status != 0)
    assert_true(worker_alive(worker))
    @fs.remove(base + "/blocked/enabled")
    @fs.remove(base + "/corrupt/enabled")
    @fs.write_file(worker + "/enabled", "")
    let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
    set_field(saved, "workspaceUid", Json::string("replaced-fixture-uid"))
    // Use a separate inactive entry, leaving the live test worker owned by its receipt.
    @fs.mkdir(base + "/replaced")
    @fs.write_file(base + "/replaced/state.json", saved.stringify())
    @fs.write_file(base + "/replaced/enabled", "")
    let (status, _, errors) = invoke("reconnect", env, directory)
    assert_eq(status, 0, msg=errors)
    assert_false(@fs.exists(base + "/replaced/enabled"))
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
    #|   touch "$FAKE_HOME/up-waiting"
    #|   while test ! -f "$FAKE_HOME/release-up"; do sleep 0.01; done
    #|   : ;;
    #| *'workspace stop'*|*'workspace delete'*) printf '%s\n' '{"level":"info","msg":"lifecycle action complete"}' >&2 ;;
    #|esac
    #|exec "$FAKE_HOME/bin/devsy-original" "$@"
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
      ["create"],
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
    #|   "$FAKE_HOME/bin/devsy-original" "$@" >/dev/null
    #|   printf '%s\n' '{"kind":"status","phase":"building_image","state":"started"}' '{"kind":"status","phase":"building_image","state":"failed","durationMs":2500}'
    #|   printf '%s\n' '{"kind":"log","level":"info","message":"Step 1/1 : RUN install"}'
    #|   printf '%s' '{"level":"error","msg":"build failed: fixture error"}' >&2
    #|   printf '%s\n' '{"kind":"error","message":"workspace error envelope"}'
    #|   exit 9 ;;
    #|esac
    #|exec "$FAKE_HOME/bin/devsy-original" "$@"
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
      ["-c", "exec \"$1\" create 2>&-", "sh", executable],
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
async test "filesystem failure reports safe timestamped elapsed time before any subprocess" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let (status, output, errors) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  assert_true(errors.contains(" create: failed ("), msg=errors)
  assert_true(errors.contains(", elapsed "))
  assert_false(errors.contains(directory))
  assert_false(@fs.exists(directory + "/args"))
}

///|
async fn cleanup_fixture(directory : String) -> Unit {
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
            @fs.rmdir(socket, recursive=true)
          }
        } catch {
          _ => ()
        }
      }
    }
  }
  @fs.rmdir(directory, recursive=true)
}

///|
async test "SSH recipes retain a recovery worker without a server port and reap it on lifecycle changes" {
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
  assert_false(@fs.exists(worker))
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
async test "adoption rejects stopped replaced or unqueryable workspaces and reaps the old master" {
  for condition in ["stopped", "replaced", "unqueryable"] {
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
    let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
    let socket = required(saved, "socketDirectory")
    @fs.mkdir(socket, recursive=true, allow_exist=true)
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
    ignore(
      @process.collect_output(
        executable,
        ["--tunnel-worker", worker],
        extra_env=env,
      ),
    )
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
async test "SSH proxy preserves binary input and reaps its child on EOF or signals" {
  for termination in ["eof", "HUP", "TERM"] {
    let (directory, _) = fixture()
    defer cleanup_fixture(directory)
    @fs.write_file(
      directory + "/transport",
      "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > \"$1\"\ncat\nwhile :; do :; done\n",
      permission=0o700,
    )
    @async.with_timeout(3000, async fn() {
      @async.with_task_group(async fn(group) {
        let (input, writer) = @process.write_to_process()
        defer writer.close()
        let (reader, output) = @process.read_from_process()
        defer reader.close()
        let sink = @process.redirect_to_file("/dev/null", shared=true)
        defer sink.close()
        let proxy = @process.spawn(
          group,
          integration_binary(),
          [
            "--ssh-proxy",
            "",
            directory + "/transport",
            directory + "/child-pid",
          ],
          stdin=input,
          stdout=output,
          stderr=sink,
        )
        let payload = b"\x00\x80\xff\r\nSSH"
        writer.write(payload)
        assert_eq(reader.read_exactly(payload.length()), payload)
        let pid = @fs.read_file(directory + "/child-pid")
          .text()
          .trim()
          .to_owned()
        assert_true(@string.parse_int(pid) > 1)
        if termination == "eof" {
          writer.close()
        } else {
          ignore(
            @process.collect_output("kill", [
              "-" + termination,
              proxy.pid.to_string(),
            ]),
          )
        }
        let code = proxy.wait()
        if termination == "eof" {
          assert_eq(code, 0)
        }
        let (alive, _, _) = @process.collect_output("kill", ["-0", pid])
        assert_true(alive != 0, msg="Proxy child must be reaped before exit")
      })
    })
  }
}

///|
async test "SSH proxy retains early and drained exit codes and closes launcher descendants" {
  let (directory, _) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(directory + "/input", "x".repeat(1000000))
  for script in ["exit 37", "cat >/dev/null; sleep 0.3; printf tail; exit 37"] {
    let (code, output, _) = @process.collect_output(
      integration_binary(),
      ["--ssh-proxy", "", "/bin/sh", "-c", script],
      stdin=@process.redirect_from_file(directory + "/input"),
    )
    assert_eq(code, 37)
    assert_eq(output.text(), if script == "exit 37" { "" } else { "tail" })
  }
  @async.with_timeout(2500, async fn() {
    let (code, output, _) = @process.collect_output(
      integration_binary(),
      [
        "--ssh-proxy", "", "/bin/sh", "-c", "sleep 30 & printf '%s' \"$!\"; wait",
      ],
      stdin=@process.redirect_from_file("/dev/null"),
    )
    assert_eq(code, 0)
    assert_true(@string.parse_int(output.text().trim().to_owned()) > 1)
    let (alive, _, _) = @process.collect_output("kill", ["-0", output.text()])
    assert_true(
      alive != 0,
      msg="Launcher descendants must not survive proxy cleanup",
    )
  })
}

///|
async test "SSH transport retains default signals and launcher termination traps" {
  let (directory, _) = fixture()
  defer cleanup_fixture(directory)
  let (code, _, _) = @process.collect_output(
    integration_binary(),
    ["--ssh-proxy", "", "/bin/sh", "-c", "kill -TERM $$; exit 37"],
    stdin=@process.redirect_from_file("/dev/null"),
  )
  assert_eq(code, 143)
  @async.with_timeout(2500, async fn() {
    @async.with_task_group(async fn(group) {
      let (input, writer) = @process.write_to_process()
      defer writer.close()
      let child = @process.spawn(
        group,
        integration_binary(),
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
async test "SSH proxy caller group death closes streams and reaps the transport" {
  let (directory, _) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/transport",
    "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > \"$1\"\ncat\nwhile :; do :; done\n",
    permission=0o700,
  )
  @async.with_timeout(3500, async fn() {
    @async.with_task_group(async fn(group) {
      let (input, writer) = @process.write_to_process()
      defer writer.close()
      let (reader, output) = @process.read_from_process()
      defer reader.close()
      let sink = @process.redirect_to_file("/dev/null", shared=true)
      defer sink.close()
      let proxy = @process.spawn(
        group,
        integration_binary(),
        [
          "--ssh-transport",
          integration_binary(),
          "--ssh-proxy",
          "",
          directory + "/transport",
          directory + "/child-pid",
        ],
        stdin=input,
        stdout=output,
        stderr=sink,
      )
      writer.write(b"ready")
      assert_eq(reader.read_exactly(5), b"ready")
      let pid = @fs.read_file(directory + "/child-pid").text()
      let (code, pgid, _) = @process.collect_output("ps", [
        "-o",
        "pgid=",
        "-p",
        proxy.pid.to_string(),
      ])
      assert_eq(code, 0)
      assert_eq(pgid.text().trim(), proxy.pid.to_string())
      let (killed, _, _) = @process.collect_output("kill", [
        "-KILL",
        "--",
        "-" + proxy.pid.to_string(),
      ])
      assert_eq(killed, 0)
      ignore(proxy.wait())
      // The original caller still holds stdin open; termination must close
      // inherited output streams without waiting for that caller's EOF.
      assert_eq(reader.read_some(max_len=1), None)
      let (alive, _, _) = @process.collect_output("kill", ["-0", pid])
      assert_true(
        alive != 0,
        msg="Transport must be reaped after caller group death",
      )
    })
  })
}

///|
async test "SSH proxy caller death reaps a transport with blocked stdin" {
  let (directory, _) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/transport",
    "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > \"$1\"\nwhile :; do :; done\n",
    permission=0o700,
  )
  @async.with_timeout(3500, async fn() {
    @async.with_task_group(async fn(group) {
      let (input, writer) = @process.write_to_process()
      defer writer.close()
      let (reader, output) = @process.read_from_process()
      defer reader.close()
      let sink = @process.redirect_to_file("/dev/null", shared=true)
      defer sink.close()
      let proxy = @process.spawn(
        group,
        integration_binary(),
        [
          "--ssh-transport",
          "/bin/sh",
          "-c",
          "\"$1\" --ssh-proxy '' \"$2\" \"$3\" <&0 & wait",
          "sh",
          integration_binary(),
          directory + "/transport",
          directory + "/child-pid",
        ],
        stdin=input,
        stdout=output,
        stderr=sink,
      )
      while !@fs.exists(directory + "/child-pid") {
        @async.sleep(10)
      }
      group.spawn_bg(no_wait=true, async fn() {
        for _ in 0..<128 {
          writer.write(Bytes::make(65536, 0)) catch {
            _ => break
          }
        }
      })
      @async.sleep(100)
      let pid = @fs.read_file(directory + "/child-pid").text()
      let (code, pgid, _) = @process.collect_output("ps", [
        "-o",
        "pgid=",
        "-p",
        proxy.pid.to_string(),
      ])
      assert_eq(code, 0)
      assert_eq(pgid.text().trim(), proxy.pid.to_string())
      let (killed, _, _) = @process.collect_output("kill", [
        "-KILL",
        "--",
        "-" + proxy.pid.to_string(),
      ])
      assert_eq(killed, 0)
      ignore(proxy.wait())
      // Data forwarding is blocked. Parent liveness must still reap the
      // transport and close the inherited output streams.
      assert_eq(reader.read_some(max_len=1), None)
      let (alive, _, _) = @process.collect_output("kill", ["-0", pid])
      assert_true(
        alive != 0,
        msg="Transport must be reaped after caller group death",
      )
    })
  })
}

///|
async test "adoption publishes connected independently of pending Git options" {
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
      @async.sleep(10)
    }
  }) catch {
    _ =>
      assert_true(false, msg="adoption fixture: previous worker did not stop")
  }
  let saved = @json.parse(@fs.read_file(worker + "/state.json").text())
  let socket = required(saved, "socketDirectory")
  @fs.mkdir(socket, recursive=true, allow_exist=true)
  @fs.write_file(socket + "/socket", "")
  @fs.write_file(worker + "/enabled", "")
  @fs.write_file(worker + "/status.json", "{}")
  @fs.rename(directory + "/bin/devsy", directory + "/bin/devsy-original")
  let wrapper =
    #|#!/bin/sh
    #|case "$*" in
    #|  *'workspace list'*) touch "$FAKE_HOME/adoption-list" ;;
    #|  *'workspace status'*) touch "$FAKE_HOME/adoption-status" ;;
    #|  *'context get'*)
    #|    touch "$FAKE_HOME/adoption-options"
    #|    while test ! -f "$FAKE_HOME/allow-options-query"; do sleep 0.01; done
    #|    touch "$FAKE_HOME/options-blocked"
    #|    while test ! -f "$FAKE_HOME/release-options"; do sleep 0.01; done ;;
    #|esac
    #|exec "$FAKE_HOME/bin/devsy-original" "$@"
  @fs.write_file(directory + "/bin/devsy", wrapper + "\n", permission=0o700)
  env.set("FAKE_GIT_FORWARDING", "false")
  @async.with_task_group(async fn(group) {
    let sink = @process.redirect_to_file("/dev/null", shared=true)
    defer sink.close()
    let child = @process.spawn(
      group,
      integration_binary(),
      ["--tunnel-worker", worker],
      extra_env=env,
      stdout=sink,
      stderr=sink,
    )
    defer {
      @fs.write_file(directory + "/allow-options-query", "")
      @fs.write_file(directory + "/release-options", "")
    }
    @async.with_timeout(5000, async fn() {
      while field(
              @json.parse(@fs.read_file(worker + "/status.json").text()),
              "status",
            ) !=
            Some(Json::string("connected")) {
        @async.sleep(10)
      }
    }) catch {
      _ => {
        let observed : Json = {
          "primarySocket": @fs.exists(socket + "/socket"),
          "workspaceList": @fs.exists(directory + "/adoption-list"),
          "workspaceStatus": @fs.exists(directory + "/adoption-status"),
          "optionsRequested": @fs.exists(directory + "/adoption-options"),
        }
        if child.try_wait() is Some(code) {
          set_field(observed, "workerExited", Json::boolean(true))
          if code >= -255 && code <= 255 {
            set_field(
              observed,
              "workerExitCode",
              Json::number(code.to_double()),
            )
          }
        } else {
          set_field(observed, "workerExited", Json::boolean(false))
        }
        let status = @json.parse(@fs.read_file(worker + "/status.json").text())
        for
          value in [
            "connected", "connecting", "stopped", "workspace-stopped", "ownership-error",
          ] {
          if field(status, "status") == Some(Json::string(value)) {
            set_field(observed, "status", Json::string(value))
          }
        }
        try {
          let events = @fs.read_file(
            directory + "/.local/state/orca-env-devsy/events.jsonl",
          ).text()
          let phases = Json::empty_object()
          for line in events.split("\n") {
            if line == "" {
              continue
            }
            let event = @json.parse(line.to_owned())
            for stage in ["workspace-list", "workspace-status", "orca-tunnel"] {
              if field(event, "stage") == Some(Json::string(stage)) {
                for
                  status in [
                    "started", "success", "exit-error", "process-error", "cancelled",
                    "adopted", "stopped",
                  ] {
                  if field(event, "status") == Some(Json::string(status)) {
                    set_field(phases, stage, Json::string(status))
                  }
                }
              }
            }
          }
          set_field(observed, "phases", phases)
        } catch {
          _ => ()
        }
        assert_true(
          false,
          msg="adoption fixture: primary did not connect while options were gated " +
            observed.stringify() +
            fixture_process_errors(env),
        )
      }
    }
    assert_false(@fs.exists(directory + "/options-blocked"))
    @fs.write_file(directory + "/allow-options-query", "")
    @async.with_timeout(5000, async fn() {
      while !@fs.exists(directory + "/options-blocked") {
        @async.sleep(10)
      }
    }) catch {
      _ =>
        assert_true(
          false,
          msg="adoption fixture: options request did not reach the gate",
        )
    }
    assert_false(@fs.exists(directory + "/release-options"))
    @fs.write_file(directory + "/release-options", "")
    @async.with_timeout(5000, async fn() {
      while @fs.read_file(worker + "/git-status").text() != "disabled" {
        @async.sleep(10)
      }
    }) catch {
      _ =>
        assert_true(
          false,
          msg="adoption fixture: released Git options were not applied",
        )
    }
    @fs.remove(worker + "/enabled")
    assert_eq(child.wait(), 0)
  })
}

///|
async test "adopted primary is stopped before reconnecting after a failed health check" {
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
  @fs.mkdir(socket, recursive=true, allow_exist=true)
  @fs.write_file(socket + "/socket", "")
  @fs.write_file(worker + "/enabled", "")
  @fs.write_file(worker + "/status.json", "{}")
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
    #|  *'-O check'*)
    #|    if test -f "$FAKE_HOME/fail-next-check"; then rm "$FAKE_HOME/fail-next-check"; exit 1; fi ;;
    #|  *'-N'*)
    #|    if test -f "$control"; then touch "$FAKE_HOME/master-conflict"; exit 1; fi
    #|    touch "$FAKE_HOME/master-recreated" ;;
    #|esac
    #|exec "$FAKE_HOME/bin/ssh-original" "$@"
  @fs.write_file(directory + "/bin/ssh", wrapper + "\n", permission=0o700)
  @async.with_timeout(5000, async fn() {
    @async.with_task_group(async fn(group) {
      let sink = @process.redirect_to_file("/dev/null", shared=true)
      defer sink.close()
      let child = @process.spawn(
        group,
        integration_binary(),
        ["--tunnel-worker", worker],
        extra_env=env,
        stdout=sink,
        stderr=sink,
      )
      defer (@fs.remove(worker + "/enabled") catch { _ => () })
      while field(
              @json.parse(@fs.read_file(worker + "/status.json").text()),
              "status",
            ) !=
            Some(Json::string("connected")) {
        @async.sleep(10)
      }
      @fs.write_file(directory + "/fail-next-check", "")
      while !@fs.exists(directory + "/master-recreated") &&
            !@fs.exists(directory + "/master-conflict") {
        @async.sleep(10)
      }
      assert_false(@fs.exists(directory + "/master-conflict"))
      assert_true(@fs.exists(directory + "/master-recreated"))
      @fs.remove(worker + "/enabled")
      assert_eq(child.wait(), 0)
    })
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
async test "provisioned task checkout uses present commits without an available relay" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("ORCA_REPO_REF_HEAD", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  env.set("ORCA_REPO_BRANCH", "task-branch")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test, checkoutMode: provisioned-root}]\n",
  )
  @fs.write_file(directory + "/git-unavailable", "")
  let (status, output, errors) = @async.with_timeout(8000, async fn() {
    invoke("create", env, directory)
  })
  assert_eq(status, 0, msg=errors)
  assert_false(errors.contains("readiness is unavailable"))
  let payload : Json = {
    "schemaVersion": 1,
    "recipeResult": @json.parse(output),
  }
  defer ignore(invoke("destroy", env, directory, payload~))
  assert_true(@fs.exists(directory + "/git-unavailable"))
  assert_true(
    @fs.read_file(directory + "/ssh-args")
    .text()
    .contains("git checkout -B 'task-branch'"),
  )
}

///|
async test "provisioned task checkout waits beyond thirty seconds for primary Git readiness" {
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
    #|  *'git checkout -B'*)
    #|    touch "$FAKE_HOME/task-checkout"
    #|    if test -f "$FAKE_HOME/git-unavailable"; then
    #|      touch "$FAKE_HOME/checkout-before-ready"
    #|      exit 7
    #|    fi ;;
    #|esac
    #|exec "$FAKE_HOME/bin/ssh-original" "$@"
  @fs.write_file(directory + "/bin/ssh", wrapper + "\n", permission=0o700)
  let (status, output, errors) = @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      while !@fs.exists(directory + "/git-probed") {
        @async.sleep(10)
      }
      @async.sleep(31500)
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
  @fs.write_file(
    installed,
    @fs.read_file(integration_binary()),
    permission=0o700,
  )
  let (status, output, errors) = @process.collect_output(
    installed,
    ["create"],
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
  let (reconnected, _, reconnect_errors) = invoke("reconnect", env, directory)
  assert_eq(reconnected, 0, msg=reconnect_errors)
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
async fn saved_create_events(directory : String) -> Array[Json] {
  let events = []
  for
    line in @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    )
    .text()
    .split("\n") {
    if line != "" {
      events.push(@json.parse(line.to_owned()))
    }
  }
  events
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
    let events = saved_create_events(directory)
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
    assert_false(raw.contains("example.com"))
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
    let events = saved_create_events(directory)
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
  let events = saved_create_events(directory)
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
    let events = saved_create_events(directory)
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
      #|   "$FAKE_HOME/bin/devsy-original" "$@" >/dev/null
      #|   printf '%s\n' '{"level":"error","msg":"get credentials: credential helper executable not found"}' >&2
      #|   printf '%s\n' '{"kind":"error","message":"token exchange failed: API returned 403; token=fixture-private-token; operation=connect"}'
      #|   printf '%s\n' '{"kind":"status","phase":"configuring_ssh","state":"failed","error":{"message":"SSH authorization failed: https://user:fixture-private-url@example.com/connect?signature=fixture-private-signature&region=apne1","hint":"check credential helper installation","context":{"token":"fixture-private-context"}}}'
      #|   printf '%s\n' 'ERROR Authorization: Bearer fixture-private-header' 'request failed with token: fixture-private-colon' 'error --token fixture-private-flag' 'Cookie="fixture-private-cookie"; session=fixture-private-session' 'https://example.com/path?access%5Ftoken=fixture-private-query&region=apne1' >&2
      #|   printf 'environment value: %s\n' "$CUSTOM_SERVICE_TOKEN" >&2
      #|   printf '%s\n' '{"level":"info","msg":"deleting machine"}' '{"level":"info","msg":"deleted machine"}' >&2
      #|   exit 9 ;;
      #|esac
      #|exec "$FAKE_HOME/bin/devsy-original" "$@"
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
      let events = saved_create_events(directory)
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
