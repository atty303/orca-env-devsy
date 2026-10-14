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
    #|  *'workspace list'*)
    #|    if test -f "$FAKE_HOME/block-list"; then
    #|      printf '%s\n' "$$" > "$FAKE_HOME/blocked-list-pid"
    #|      while test ! -f "$FAKE_HOME/release-list"; do sleep 0.1; done
    #|    fi
    #|    if test -f "$FAKE_HOME/created"; then printf '[{"id":"test-id","uid":"%s"}]\n' "$(cat "$FAKE_HOME/uid")"; else printf '[]\n'; fi ;;
    #|  *'workspace status'*) if test -f "$FAKE_HOME/stopped"; then printf '{"state":"Stopped"}\n'; else printf '{"state":"Running"}\n'; fi ;;
    #|  *'workspace up'*) rm -f "$FAKE_HOME/stopped"; touch "$FAKE_HOME/created"; test ! -f "$FAKE_HOME/fail-up"
    #|    if test -f "$FAKE_HOME/up-result"; then cat "$FAKE_HOME/up-result"; else printf '{"kind":"result","outcome":"success","remoteUser":"developer","remoteWorkspaceFolder":"/workspace/repo"}\n'; fi ;;
    #|  *'workspace stop'*) test ! -f "$FAKE_HOME/fail-stop"; touch "$FAKE_HOME/stopped" ;;
    #|  *'workspace delete'*) test ! -f "$FAKE_HOME/fail-delete"; rm -f "$FAKE_HOME/created" ;;
    #|  *) exit 2 ;;
    #|esac
  let git =
    #|#!/bin/sh
    #|remote=HEAD
    #|for arg in "$@"; do case "$arg" in *'^{}') : ;; refs/heads/*) remote="$arg" ;; esac; done
    #|printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t%s\n' "$remote"
  let ssh =
    #|#!/bin/sh
    #|set -eu
    #|printf '%s\n' "$@" >> "$FAKE_HOME/ssh-args"
    #|case "$*" in
    #|  *'rev-parse HEAD'*) test ! -f "$FAKE_HOME/fail-root"; printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
    #|  *'pwd -P'*) printf '/workspace/repo\n' ;;
    #|  *'Sec-WebSocket-Version'*) if test -f "$FAKE_HOME/reuse-running-server" && test -f "$FAKE_HOME/served"; then printf 101; else printf 000; fi ;;
    #|  *'--recipe-json'*) touch "$FAKE_HOME/served"; printf '{"schemaVersion":1,"connection":{"type":"orca-server","pairingCode":"fixture-pairing","projectRoot":"/workspace/repo"}}\n' ;;
    #|  *'-O check'*)
    #|    if test -f "$FAKE_HOME/fail-tunnel-cleanup"; then
    #|      for state in "$XDG_STATE_HOME/orca-env-devsy/tunnels/"*/state.json; do printf '{invalid' > "$state"; done
    #|    fi
    #|    test -f "$FAKE_HOME/listener-ready" ;;
    #|  *'-O exit'*) rm -f "$FAKE_HOME/listener-ready" ;;
    #|  *'cat >'* ) test ! -f "$FAKE_HOME/fail-addon"; cat > "$FAKE_HOME/delivered-auth" ;;
    #|  *'-L 127.0.0.1:'* )
    #|    while test "$1" != '-L'; do shift; done
    #|    port=${2#127.0.0.1:}; port=${port%%:*}
    #|    printf '%s\n' "$port" > "$FAKE_HOME/listener-port"
    #|    count=0
    #|    while ! test -f "$FAKE_HOME/listener-ready"; do count=$((count+1)); test "$count" -lt 100; sleep 0.01; done
    #|    if test -f "$FAKE_HOME/keep-proxy-stderr"; then
    #|      sleep 60 & keeper=$!
    #|      printf '%s\n' "$keeper" > "$FAKE_HOME/keeper-pid"
    #|      trap 'kill "$keeper" 2>/dev/null || true; wait "$keeper" 2>/dev/null || true' EXIT HUP INT TERM
    #|    fi
    #|    while test -f "$FAKE_HOME/listener-ready"; do
    #|      if test -f "$FAKE_HOME/drop-tunnel"; then rm "$FAKE_HOME/drop-tunnel"; printf "Permission denied (publickey). private-stderr-secret\n" >&2; exit 1; fi
    #|      sleep 0.01
    #|    done ;;
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
  let executable = @env.get_env_var("ORCA_ENV_DEVSY_TEST_BINARY").unwrap_or(
    @env.current_dir().unwrap() +
    "/_build/native/release/build/cmd/main/main.exe",
  )
  let input = if payload is Some(value) {
    @fs.write_file(directory + "/stdin.json", value.stringify())
    Some(@process.redirect_from_file(directory + "/stdin.json"))
  } else {
    None
  }
  let (status, stdout, stderr) = @process.collect_output(
    executable,
    if mode == "reconnect" && payload is Some(_) {
      [mode, "--receipt"]
    } else {
      [mode]
    },
    extra_env=env,
    stdin?=input,
  )
  (status, stdout.text(), stderr.text())
}

///|
async test "native CLI preserves creation settings across lifecycle and emits only recipe JSON" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  let yaml =
    #|devsy:
    #|  connection: ssh
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
  let (status, stdout, _) = invoke("create", env, directory)
  assert_eq(status, 0)
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
  assert_true(args.text().contains("\n--git-clone-strategy=\n"))
  assert_true(args.text().contains("VALUE=two words; $(ignored)\n"))
  @fs.write_file(directory + "/orca.yaml", "deliberately invalid yaml: [")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  for mode in ["resume", "suspend", "destroy"] {
    let (status, output, _) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0)
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
  defer @fs.rmdir(directory, recursive=true)
  let yaml =
    #|devsy:
    #|  connection: ssh
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
  defer @fs.rmdir(directory, recursive=true)
  with_fake_tunnel(directory, async fn() {
    let yaml =
      #|devsy:
      #|  connection: orca-server
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
      .contains("ProxyCommand=" + proxy(state)),
    )
    @fs.write_file(directory + "/orca.yaml", "invalid: [")
    @fs.write_file(directory + "/ssh-args", "")
    let (status, output, _) = invoke("reconnect", env, directory, payload~)
    assert_eq(status, 0)
    assert_eq(
      field(@json.parse(output), "connection"),
      field(result, "connection"),
    )
    let commands = @fs.read_file(directory + "/ssh-args")
    assert_true(commands.text().contains("ProxyCommand=" + proxy(state)))
    assert_false(commands.text().contains("--recipe-json"))
    assert_false(commands.text().contains("releases/latest"))
  })
}

///|
async test "provisioned-root uses schema 2 and checks out the supplied task commit independently" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  env.set("ORCA_REPO_REF_HEAD", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
  env.set("ORCA_REPO_BRANCH", "task-branch")
  let yaml =
    #|devsy:
    #|  connection: ssh
    #|environmentRecipes:
    #|  - id: test
    #|    checkoutMode: provisioned-root
  @fs.write_file(directory + "/orca.yaml", yaml)
  let (status, output, _) = invoke("create", env, directory)
  assert_eq(status, 0)
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
async test "Codex addon delivers synthetic access data only and excludes secrets from output and diagnostics" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
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
    "devsy:\n  connection: ssh\n  addons:\n    codexAuth: true\nenvironmentRecipes:\n  - id: test\n",
  )
  let (status, output, errors) = invoke("create", env, directory)
  assert_eq(status, 0)
  assert_false(errors.contains("addon failed"), msg=errors)
  let delivered = @json.parse(
    @fs.read_file(directory + "/delivered-auth").text(),
  )
  let tokens = field(delivered, "tokens").unwrap()
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
  let (status, output, _) = invoke("resume", env, directory, payload~)
  assert_eq(status, 0)
  assert_eq(field(@json.parse(output), "userData"), Some(state))
}

///|
async test "failed create removes its UID-owned workspace and permits retry" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy:\n  connection: ssh\nenvironmentRecipes:\n  - id: test\n",
  )
  @fs.write_file(directory + "/fail-root", "")
  let (status, output, _) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  assert_false(@fs.exists(directory + "/created"))
  @fs.remove(directory + "/fail-root")
  let (status, _, _) = invoke("create", env, directory)
  assert_eq(status, 0)
}

///|
async test "failed provisioning cleans the requested UID before a recipe receipt exists" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy:\n  connection: ssh\nenvironmentRecipes:\n  - id: test\n",
  )
  @fs.write_file(directory + "/fail-up", "")
  let (status, output, _) = invoke("create", env, directory)
  assert_true(status != 0)
  assert_eq(output, "")
  assert_false(@fs.exists(directory + "/created"))
  @fs.remove(directory + "/fail-up")
  let (status, _, _) = invoke("create", env, directory)
  assert_eq(status, 0)
}

///|
async fn with_fake_tunnel(directory : String, run : async () -> Unit) -> Unit {
  @fs.write_file(directory + "/fixture-tunnel-enabled", "")
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      while @fs.exists(directory + "/fixture-tunnel-enabled") {
        if !@fs.exists(directory + "/listener-port") {
          @async.sleep(10)
          continue
        }
        let port = @fs.read_file(directory + "/listener-port")
          .text()
          .trim()
          .to_owned()
        let listener = @socket.TcpServer(
          @socket.Addr::parse("127.0.0.1:" + port),
        )
        defer listener.close()
        @fs.write_file(directory + "/listener-ready", "")
        while @fs.exists(directory + "/listener-ready") &&
              @fs.exists(directory + "/fixture-tunnel-enabled") {
          @async.sleep(10)
        }
        @async.sleep(10)
      }
    })
    defer {
      @fs.remove(directory + "/fixture-tunnel-enabled") catch {
        _ => ()
      }
      @fs.remove(directory + "/listener-ready") catch {
        _ => ()
      }
    }
    run()
  })
}

///|
async test "remote server launch returns JSON while the detached server remains alive" {
  let directory = @fs.tmpdir(prefix="orca-env-devsy-pipe-test")
  defer @fs.rmdir(directory, recursive=true)
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
  defer @fs.rmdir(directory, recursive=true)
  let invocation = configured_launcher(directory)
  env.set("LAUNCHER", invocation[0])
  let document : Json = {
    "devsy": {
      "connection": "ssh",
      "command": Json::array(
        ["${LAUNCHER?}"] + invocation[1:].map(Json::string),
      ),
    },
    "environmentRecipes": [{ "id": "test" }],
  }
  @fs.write_file(directory + "/orca.yaml", document.stringify())
  let (status, output, _) = invoke("create", env, directory)
  assert_eq(status, 0)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  assert_eq(saved_command(state), invocation)
  @fs.write_file(directory + "/orca.yaml", "devsy: {command: [missing]}\n")
  env.set("LAUNCHER", "missing")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  for mode in ["resume", "reconnect", "suspend"] {
    let (status, output, _) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0)
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
      "ProxyCommand=" + proxy(state),
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
  let (status, _, _) = invoke("destroy", env, directory, payload~)
  assert_eq(status, 0)
  assert_false(@fs.exists(directory + "/created"))
}

///|
async test "invalid command is rejected before Devsy and errors retain only setting location" {
  for invalid in [Json::null(), [], [""], ["devsy", 1], ["${MISSING}"]] {
    let (directory, env) = fixture()
    defer @fs.rmdir(directory, recursive=true)
    let document : Json = {
      "devsy": { "connection": "ssh" },
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
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, _) = invoke("create", env, directory)
  assert_eq(status, 0)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  if state is Json::Object(map) {
    map.remove("command")
  }
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  for mode in ["resume", "reconnect", "suspend"] {
    let (status, _, _) = invoke(mode, env, directory, payload~)
    assert_eq(status, 0)
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
  let (status, _, _) = invoke("destroy", env, directory, payload~)
  assert_eq(status, 0)
}

///|
async test "command diagnostics distinguish process failure and exit failure without retaining arguments" {
  // Exercise the binary so recording uses its own HOME and run identity.
  let (fixture_dir, env) = fixture()
  defer @fs.rmdir(fixture_dir, recursive=true)
  for
    invocation in [
      ["missing-command-fixture", "private-argument-fixture"],
      ["/bin/sh", "-c", "exit 7", "private-argument-fixture"],
    ] {
    let document : Json = {
      "devsy": {
        "connection": "ssh",
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
  let records = @fs.read_file(
    fixture_dir + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(records.contains("process-error"), msg=records)
  assert_true(records.contains("exit-error"))
  assert_true(records.contains("\"exitCode\":7"))
  assert_true(records.contains("resolve-context"))
  assert_false(records.contains("private-argument-fixture"))
  assert_false(records.contains("missing-command-fixture"))
}

///|
async test "proxy preserves binary streams and the configured command exit status" {
  let directory = @fs.tmpdir(prefix="orca-env-devsy-proxy-test")
  defer @fs.rmdir(directory, recursive=true)
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
      ["-c", "exec " + proxy(state)],
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
  defer @fs.rmdir(directory, recursive=true)
  let invocation = configured_launcher(directory)
  @fs.symlink(directory + "/bin/-launcher", target=invocation[0])
  invocation[0] = "-launcher"
  let document : Json = {
    "devsy": {
      "connection": "ssh",
      "command": Json::array(invocation.map(Json::string)),
    },
    "environmentRecipes": [{ "id": "test" }],
  }
  @fs.write_file(directory + "/orca.yaml", document.stringify())
  let (status, output, _) = invoke("create", env, directory)
  assert_eq(status, 0)
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
      "ProxyCommand=" + proxy(state),
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
  let (status, _, _) = invoke("destroy", env, directory, payload~)
  assert_eq(status, 0)
}

///|
async test "destroy succeeds repeatedly after external deletion" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (status, output, _) = invoke("create", env, directory)
  assert_eq(status, 0)
  let result = @json.parse(output)
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  @fs.remove(directory + "/created")
  for _ in 0..<2 {
    let (status, output, _) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0)
    assert_eq(output, "")
  }
  let (status, _, _) = invoke("resume", env, directory, payload~)
  assert_true(status != 0)
}

///|
async test "existing Orca installation is validated and reused without downloading or replacing it" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
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
  let (status, _, _) = @process.collect_output(
    "/bin/sh",
    ["-c", server_install_script()],
    extra_env=env,
    inherit_env=false,
  )
  assert_eq(status, 0)
  assert_eq(@fs.read_file(install + "/orca-ide").text(), executable)
  @fs.write_file(install + "/orca-ide", "#!/bin/sh\nexit 8\n", permission=0o700)
  let (status, _, _) = @process.collect_output(
    "/bin/sh",
    ["-c", server_install_script()],
    extra_env=env,
    inherit_env=false,
  )
  assert_eq(status, 8)
  assert_true(@fs.exists(install + "/orca-ide"))
}

///|
async test "branch builds try shallow and retry only a missing pinned commit with full clone" {
  for failure in ["missing", "other", "none"] {
    let (directory, env) = fixture()
    defer @fs.rmdir(directory, recursive=true)
    @fs.rename(directory + "/bin/devsy", directory + "/bin/devsy-original")
    let wrapper =
      #|#!/bin/sh
      #|set -eu
      #|case "$*" in
      #| *--git-clone-strategy=shallow*)
      #|   printf '%s\n' "$@" >> "$FAKE_HOME/shallow-args"
      #|   if test "$CLONE_FAILURE" = missing; then
      #|     printf '%s\n' "{\"kind\":\"status\",\"phase\":\"cloning_repository\",\"state\":\"failed\",\"error\":{\"message\":\"Could not parse object 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\"}}"
      #|     printf '\377 non-UTF-8 private-stderr-secret\n' >&2
      #|     exit 1
      #|   fi
      #|   if test "$CLONE_FAILURE" = other; then exit 3; fi ;;
      #|esac
      #|exec "$FAKE_HOME/bin/devsy-original" "$@"
    @fs.write_file(directory + "/bin/devsy", wrapper + "\n", permission=0o700)
    env.set("CLONE_FAILURE", failure)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, buildRef: 'refs/heads/main'}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, _) = invoke("create", env, directory)
    assert_eq(status == 0, failure != "other")
    let shallow = @fs.read_file(directory + "/shallow-args").text()
    assert_true(
      shallow.contains(
        "@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@main\n",
      ),
    )
    assert_true(shallow.contains("--git-clone-strategy=shallow\n"))
    let full = @fs.read_file(directory + "/args").text()
    assert_eq(full.contains("--git-clone-strategy=\n"), failure == "missing")
    if status == 0 {
      let payload : Json = {
        "schemaVersion": 1,
        "recipeResult": @json.parse(output),
      }
      let (status, _, _) = invoke("destroy", env, directory, payload~)
      assert_eq(status, 0)
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
}

///|
async test "invalid provisioned branch is rejected before Devsy" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  // Exercise Git's own reference grammar, not a permissive fixture.
  @fs.write_file(
    directory + "/bin/git",
    "#!/bin/sh\nexec /usr/bin/git \"$@\"\n",
    permission=0o700,
  )
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh}\nenvironmentRecipes: [{id: test, checkoutMode: provisioned-root}]\n",
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
  defer @fs.rmdir(first, recursive=true)
  let (second, env2) = fixture()
  defer @fs.rmdir(second, recursive=true)
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
      "devsy: {connection: ssh, addons: {codexAuth: true}}\nenvironmentRecipes: [{id: test}]\n",
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
    defer @fs.rmdir(directory, recursive=true)
    @fs.mkdir(directory + "/.codex")
    let auth = synthetic_auth(
      @env.now().to_double() / 1000 + (if expired { -60 } else { 60 }),
    )
    @fs.write_file(directory + "/.codex/auth.json", auth.stringify())
    @fs.write_file(directory + "/.codex/fail-refresh", "")
    fake_codex(directory)
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: ssh, addons: {codexAuth: true}}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, _, errors) = invoke("create", env, directory)
    assert_eq(status, 0)
    assert_true(errors.contains("refresh failed"))
    assert_eq(@fs.exists(directory + "/delivered-auth"), !expired)
  }
}

///|
async test "tunnel worker reconnects on the same port and remains running when stop or delete fails" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server}\nenvironmentRecipes: [{id: test}]\n",
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
      assert_true(@fs.exists(directory + "/listener-ready"))
      @fs.remove(directory + "/" + marker)
    }
    @fs.remove(directory + "/created")
    let (status, _, errors) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0, msg=errors)
    assert_false(@fs.exists(worker))
    let (status, _, _) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0)
  })
}

///|
async test "short tag build refs use full clones including annotated tag peeling" {
  for annotated in [false, true] {
    let (directory, env) = fixture()
    defer @fs.rmdir(directory, recursive=true)
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
    let (status, _, _) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0)
  }
}

///|
async test "automatic tunnel recovery refuses a replacement workspace UID" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server}\nenvironmentRecipes: [{id: test}]\n",
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
    let (status, _, _) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0)
  })
}

///|
async test "remote user and workspace folder validation rejects malformed metadata and permits service users" {
  for
    pair in [
      ("developer", Json::string("relative")),
      ("developer", Json::string("/path\rname")),
      ("developer", Json::string("/path\nname")),
      ("developer", Json::number(4)),
      ("123", Json::string("/workspace/repo")),
      ("developer$", Json::string("/workspace/repo")),
    ] {
    let (directory, env) = fixture()
    defer @fs.rmdir(directory, recursive=true)
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
      "devsy: {connection: ssh}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, _) = invoke("create", env, directory)
    assert_eq(status == 0, user == "developer$")
    if status == 0 {
      let payload : Json = {
        "schemaVersion": 1,
        "recipeResult": @json.parse(output),
      }
      let (status, _, _) = invoke("destroy", env, directory, payload~)
      assert_eq(status, 0)
    } else {
      assert_false(@fs.exists(directory + "/created"))
    }
  }
}

///|
async test "server create returns recipe JSON while the tunnel child retains stderr" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(directory + "/keep-proxy-stderr", "")
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server}\nenvironmentRecipes: [{id: test}]\n",
    )
    let (status, output, errors) = @async.with_timeout(5000, async fn() {
      invoke("create", env, directory)
    })
    assert_eq(status, 0, msg=errors)
    let result = @json.parse(output)
    let state = field(result, "userData").unwrap()
    let payload : Json = { "schemaVersion": 1, "recipeResult": result }
    defer ignore(invoke("destroy", env, directory, payload~))
    assert_eq(
      field(field(result, "connection").unwrap(), "type"),
      Some(Json::string("orca-server")),
    )
    assert_true(worker_alive(required(state, "tunnelDirectory")))
    let pid = @fs.read_file(directory + "/keeper-pid").text().trim().to_owned()
    assert_eq(@process.run("kill", ["-0", pid]), 0)
    let (status, _, _) = invoke("suspend", env, directory, payload~)
    assert_eq(status, 0)
    let (status, _, _) = @process.collect_output("kill", ["-0", pid])
    assert_true(status != 0)
  })
}

///|
async test "destroy cancels and reaps a blocked worker UID query" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server}\nenvironmentRecipes: [{id: test}]\n",
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
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(directory + "/reuse-running-server", "")
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: orca-server}\nenvironmentRecipes: [{id: test}]\n",
  )
  let mut recipe = Json::null()
  with_fake_tunnel(directory, async fn() {
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    recipe = @json.parse(output)
    let payload : Json = { "schemaVersion": 1, "recipeResult": recipe }
    let (status, _, _) = invoke("suspend", env, directory, payload~)
    assert_eq(status, 0)
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
    let (status, _, _) = invoke("destroy", env, directory, payload~)
    assert_eq(status, 0)
  })
}

///|
async test "Server loopback health probe ignores ambient curl proxy configuration" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
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
  defer @fs.rmdir(directory, recursive=true)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server}\nenvironmentRecipes: [{id: test}]\n",
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
    @fs.remove(directory + "/listener-ready")
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
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh}\nenvironmentRecipes: [{id: test}]\n",
  )
  let result =
    #|{"kind":"status","phase":"cloning_repository","state":"started","step":"private-step-secret"}
    #|{"kind":"status","phase":"building_image","state":"failed","error":{"message":"private-error-secret","context":{"token":"private-context-secret"}}}
    #|{"kind":"status","phase":"private-phase-secret","state":"failed"}
    #|{"kind":"result","outcome":"success","remoteUser":"developer","remoteWorkspaceFolder":"/workspace/repo"}
  @fs.write_file(directory + "/up-result", result + "\n")
  let (status, output, _) = invoke("create", env, directory)
  assert_eq(status, 0)
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
  let (status, _, _) = invoke("resume", env, directory, payload~)
  assert_eq(status, 0)
  assert_eq(@fs.read_file(path).text(), records)
  env.remove("ORCA_ENV_DEVSY_RECORDING")
  @fs.remove(path)
  @fs.mkdir(path)
  let (status, _, _) = invoke("resume", env, directory, payload~)
  assert_eq(status, 0)
}

///|
async test "binary stderr never changes command failure with recording enabled or disabled" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  let document : Json = {
    "devsy": {
      "connection": "ssh",
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
async test "bulk reconnect restores persistent XDG state without a receipt or current YAML" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  env.set("XDG_STATE_HOME", directory + "/xdg-state")
  with_fake_tunnel(directory, async fn() {
    let document : Json = {
      "devsy": {
        "connection": "orca-server",
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
    let (status, output, _) = invoke("reconnect", env, directory)
    assert_eq(status, 0)
    assert_eq(output, "")
    assert_eq(@json.parse(@fs.read_file(worker + "/state.json").text()), after)
    let (status, _, _) = invoke("suspend", env, directory, payload~)
    assert_eq(status, 0)
    assert_false(@fs.exists(worker))
    let (status, output, _) = invoke("reconnect", env, directory)
    assert_eq(status, 0)
    assert_eq(output, "")
  })
}

///|
async test "bulk recovery skips disabled stopped and replaced workspaces and continues past corrupt entries" {
  let (directory, env) = fixture()
  defer @fs.rmdir(directory, recursive=true)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server}\nenvironmentRecipes: [{id: test}]\n",
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
    let (status, _, _) = invoke("reconnect", env, directory)
    assert_eq(status, 0)
    assert_false(worker_alive(worker))
    @fs.write_file(worker + "/enabled", "")
    @fs.write_file(directory + "/stopped", "")
    let args = @fs.read_file(directory + "/ssh-args").text()
    let (status, _, _) = invoke("reconnect", env, directory)
    assert_eq(status, 0)
    assert_eq(@fs.read_file(directory + "/ssh-args").text(), args)
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
    let (status, _, _) = invoke("reconnect", env, directory)
    assert_eq(status, 0)
    assert_false(@fs.exists(base + "/replaced/enabled"))
  })
}
