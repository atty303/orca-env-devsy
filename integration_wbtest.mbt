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
    #|    if test -f "$FAKE_HOME/created"; then printf '[{"id":"test-id","uid":"%s"}]\n' "$(cat "$FAKE_HOME/uid")"; else printf '[]\n'; fi ;;
    #|  *'workspace up'*) touch "$FAKE_HOME/created"; test ! -f "$FAKE_HOME/fail-up"; printf '{"kind":"result","outcome":"success","remoteUser":"developer","remoteWorkspaceFolder":"/workspace/repo"}\n' ;;
    #|  *'workspace stop'*) : ;;
    #|  *'workspace delete'*) rm "$FAKE_HOME/created" ;;
    #|  *) exit 2 ;;
    #|esac
  let git =
    #|#!/bin/sh
    #|printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tHEAD\n'
  let ssh =
    #|#!/bin/sh
    #|set -eu
    #|printf '%s\n' "$@" >> "$FAKE_HOME/ssh-args"
    #|case "$*" in
    #|  *'rev-parse HEAD'*) test ! -f "$FAKE_HOME/fail-root"; printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
    #|  *'pwd -P'*) printf '/workspace/repo\n' ;;
    #|  *'--recipe-json'*) printf '{"schemaVersion":1,"connection":{"type":"orca-server","pairingCode":"fixture-pairing","projectRoot":"/workspace/repo"}}\n' ;;
    #|  *'-O check'*) test -f "$FAKE_HOME/listener-ready" ;;
    #|  *'-O exit'*) rm -f "$FAKE_HOME/listener-ready" ;;
    #|  *'cat >'* ) test ! -f "$FAKE_HOME/fail-addon"; cat > "$FAKE_HOME/delivered-auth" ;;
    #|  *'-L '* )
    #|    while test "$1" != '-L'; do shift; done
    #|    port=${2#127.0.0.1:}; port=${port%%:*}
    #|    printf '%s\n' "$port" > "$FAKE_HOME/listener-port"
    #|    count=0
    #|    while ! test -f "$FAKE_HOME/listener-ready"; do count=$((count+1)); test "$count" -lt 100; sleep 0.01; done ;;
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
    [mode],
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
    assert_eq(status, 0)
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
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      while !@fs.exists(directory + "/listener-port") {
        @async.sleep(10)
      }
      let port = @fs.read_file(directory + "/listener-port")
        .text()
        .trim()
        .to_owned()
      let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:" + port))
      defer listener.close()
      @fs.write_file(directory + "/listener-ready", "")
      while @fs.exists(directory + "/listener-ready") {
        @async.sleep(10)
      }
    })
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
