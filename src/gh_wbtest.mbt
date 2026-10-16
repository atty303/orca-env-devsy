///|
async fn fake_gh(directory : String) -> Unit {
  let script =
    #|#!/bin/sh
    #|set -eu
    #|if test "${FAKE_GH_REMOTE:-}" != 1; then
    #|  case "$*" in
    #|    'auth token --hostname github.com')
    #|      printf 'read\n' >> "$FAKE_HOME/host-gh-reads"
    #|      test ! -f "$FAKE_HOME/fail-host-gh"
    #|      cat "$FAKE_HOME/host-gh-token" ;;
    #|    'api user --hostname github.com --jq .login')
    #|      test ! -f "$FAKE_HOME/fail-host-account"
    #|      printf 'fixture\n' ;;
    #|    *) exit 2 ;;
    #|  esac
    #|  exit
    #|fi
    #|case "$*" in
    #|  'auth token --hostname github.com')
    #|    if test -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}"; then exit 0; fi
    #|    test -f "$GH_CONFIG_DIR/hosts.yml"
    #|    grep -q oauth_token "$GH_CONFIG_DIR/hosts.yml" ;;
    #|  'config get user --host github.com')
    #|    test -f "$GH_CONFIG_DIR/hosts.yml"
    #|    grep -q 'user: manual' "$GH_CONFIG_DIR/hosts.yml" ;;
    #|  'config get users --host github.com')
    #|    test -f "$GH_CONFIG_DIR/hosts.yml"
    #|    grep -q 'fixture-inactive' "$GH_CONFIG_DIR/hosts.yml" ;;
    #|  auth*) touch "$FAKE_HOME/keyring-mutated"; exit 2 ;;
    #|  *) exit 2 ;;
    #|esac
  @fs.write_file(directory + "/bin/gh", script + "\n", permission=0o700)
  @fs.write_file(directory + "/host-gh-token", "fixture-gh-first\n")
}

///|
async test "gh addon uses saved settings on create resume and explicit reconnect in both modes" {
  for connection in ["ssh", "orca-server"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    fake_gh(directory)
    with_fake_tunnel(directory, async fn() {
      @fs.write_file(
        directory + "/orca.yaml",
        "devsy: {connection: " +
        connection +
        ", buildRef: refs/heads/main, addons: {ghAuth: true}}\nenvironmentRecipes: [{id: test}]\n",
      )
      let (code, output, errors) = invoke("create", env, directory)
      assert_eq(code, 0, msg=errors)
      let receipt = @json.parse(output)
      let state = field(receipt, "userData").unwrap()
      assert_eq(field(state, "ghAuth"), Some(Json::boolean(true)))
      let payload : Json = { "schemaVersion": 1, "recipeResult": receipt }
      defer ignore(invoke("destroy", env, directory, payload~))
      let path = directory + "/remote-gh/hosts.yml"
      assert_true(@fs.read_file(path).text().contains("fixture-gh-first"))
      @fs.write_file(directory + "/orca.yaml", "invalid: [")
      for mode in ["resume", "reconnect"] {
        @fs.write_file(
          directory + "/host-gh-token",
          "fixture-gh-" + mode + "\n",
        )
        let (code, _, errors) = invoke(mode, env, directory, payload~)
        assert_eq(code, 0, msg=errors)
        assert_true(@fs.read_file(path).text().contains("fixture-gh-" + mode))
      }
      @fs.write_file(directory + "/host-gh-token", "fixture-gh-bulk\n")
      let (code, output, errors) = invoke("reconnect", env, directory)
      assert_eq(code, 0, msg=errors)
      assert_eq(output, "")
      assert_true(@fs.read_file(path).text().contains("fixture-gh-bulk"))
      let logins = @fs.read_file(directory + "/remote-gh-logins").text()
      assert_eq(logins, "publish\n".repeat(4))
      // Normal worker transport recovery must not acquire fresh auth.
      if connection == "orca-server" {
        let before = @fs.read_file(directory + "/ssh-args")
          .text()
          .split("-L\n")
          .count()
        @fs.write_file(directory + "/drop-tunnel", "")
        @async.with_timeout(10000, async fn() {
          while @fs.read_file(directory + "/ssh-args")
                .text()
                .split("-L\n")
                .count() <=
                before {
            @async.sleep(25)
          }
        })
      }
      assert_eq(@fs.read_file(directory + "/remote-gh-logins").text(), logins)
      let diagnostics = @fs.read_file(
        directory + "/.local/state/orca-env-devsy/events.jsonl",
      ).text()
      for
        secret in [
          "fixture-gh-first", "fixture-gh-resume", "fixture-gh-reconnect", "fixture-gh-bulk",
        ] {
        assert_false(diagnostics.contains(secret))
        assert_false(receipt.stringify().contains(secret))
        assert_false(
          @fs.read_file(directory + "/ssh-args").text().contains(secret),
        )
      }
      assert_true(diagnostics.contains("gh-auth"))
      assert_true(diagnostics.contains("delivery"))
      assert_false(@fs.exists(directory + "/keyring-mutated"))
    })
  }
}

///|
async fn gh_script_run(
  directory : String,
  env : Map[String, String],
  truncate~ : Bool = false,
) -> Int32 {
  let (code, snapshot, errors) = @process.collect_output(
    "/bin/sh",
    ["-c", gh_snapshot_script()],
    extra_env=env,
    inherit_env=false,
  )
  assert_eq(errors.text(), "")
  if code != 0 {
    return code
  }
  let payload = gh_document(snapshot.text(), "fixture", "fixture-gh-delivery")
  @fs.write_file(
    directory + "/delivery-stdin",
    if truncate {
      payload[:payload.length() - 1].to_owned()
    } else {
      payload
    },
  )
  let (code, out, err) = @process.collect_output(
    "/bin/sh",
    ["-c", gh_delivery_script()],
    stdin=@process.redirect_from_file(directory + "/delivery-stdin"),
    extra_env=env,
    inherit_env=false,
  )
  assert_eq(out.text(), "")
  assert_eq(err.text(), "")
  code
}

///|
async test "gh delivery preserves environment manual auth modifications and failed publication without changing other settings" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  fake_gh(directory)
  let config = directory + "/remote-gh"
  env.set("FAKE_GH_REMOTE", "1")
  env.set("GH_CONFIG_DIR", config)
  @fs.mkdir(config)
  let hosts = config + "/hosts.yml"
  let other = "enterprise.example:\n    git_protocol: ssh\n"
  @fs.write_file(hosts, other)
  @fs.write_file(config + "/config.yml", "editor: custom-editor\n")
  for name in ["GH_TOKEN", "GITHUB_TOKEN"] {
    env.set(name, "fixture-manual-environment")
    assert_eq(
      gh_script_run(directory, env),
      if name == "GH_TOKEN" {
        10
      } else {
        13
      },
    )
    env.remove(name)
    assert_eq(@fs.read_file(hosts).text(), other)
  }
  for
    manual in [
      "github.com:\n    oauth_token: fixture-manual-token\n", "github.com:\n    user: manual\n",
      "github.com:\n    users:\n        fixture-inactive: {}\n",
    ] {
    @fs.write_file(hosts, manual)
    assert_eq(gh_script_run(directory, env), 11)
    assert_eq(@fs.read_file(hosts).text(), manual)
  }
  @fs.write_file(hosts, other)
  assert_eq(gh_script_run(directory, env, truncate=true), 23)
  assert_eq(@fs.read_file(hosts).text(), other)
  assert_false(@fs.exists(config + "/.orca-env-devsy-gh-auth"))
  @fs.write_file(
    directory + "/bin/mv",
    "#!/bin/sh\nif test -f \"$FAKE_HOME/fail-publish\"; then exit 1; fi\nexec /bin/mv \"$@\"\n",
    permission=0o700,
  )
  @fs.write_file(directory + "/fail-publish", "")
  assert_eq(gh_script_run(directory, env), 1)
  assert_eq(@fs.read_file(hosts).text(), other)
  assert_false(@fs.exists(config + "/.orca-env-devsy-gh-auth"))
  @fs.remove(directory + "/fail-publish")
  assert_eq(gh_script_run(directory, env), 0)
  let delivered = @fs.read_file(hosts).text()
  let merged = @json.parse(delivered)
  assert_eq(
    field(merged, "enterprise.example"),
    Some({ "git_protocol": "ssh" }),
  )
  assert_true(delivered.contains("fixture-gh-delivery"))
  assert_eq(
    @fs.read_file(config + "/config.yml").text(),
    "editor: custom-editor\n",
  )
  @fs.write_file(hosts, delivered + "# manual change\n")
  assert_eq(gh_script_run(directory, env), 12)
  assert_eq(@fs.read_file(hosts).text(), delivered + "# manual change\n")
  let files = @fs.readdir(config)
  assert_eq(files.length(), 3)
  for name in [".orca-env-devsy-gh-auth", "config.yml", "hosts.yml"] {
    assert_true(files.contains(name))
  }
}

///|
async test "gh addon is optional and authentication failure does not fail the lifecycle" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  fake_gh(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, output, errors) = invoke("create", env, directory)
  assert_eq(code, 0, msg=errors)
  let receipt = @json.parse(output)
  let state = field(receipt, "userData").unwrap()
  let payload : Json = { "schemaVersion": 1, "recipeResult": receipt }
  defer ignore(invoke("destroy", env, directory, payload~))
  assert_false(@fs.exists(directory + "/host-gh-reads"))
  set_field(state, "ghAuth", Json::boolean(true))
  @fs.write_file(directory + "/fail-host-gh", "")
  let (code, _, errors) = invoke("reconnect", env, directory, payload~)
  assert_eq(code, 0, msg=errors)
  assert_true(
    errors.contains("GitHub authentication addon failed at host-token"),
  )
  assert_false(@fs.exists(directory + "/remote-gh-logins"))
  @fs.remove(directory + "/fail-host-gh")
  @fs.write_file(directory + "/fail-host-account", "")
  let (code, _, errors) = invoke("reconnect", env, directory, payload~)
  assert_eq(code, 0, msg=errors)
  assert_true(
    errors.contains("GitHub authentication addon failed at host-account"),
  )
  assert_false(@fs.exists(directory + "/remote-gh/hosts.yml"))
  @fs.remove(directory + "/fail-host-account")
  @fs.write_file(directory + "/fail-remote-gh", "")
  let (code, _, errors) = invoke("reconnect", env, directory, payload~)
  assert_eq(code, 0, msg=errors)
  assert_true(errors.contains("GitHub authentication addon failed at delivery"))
  let events = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  assert_true(events.contains("host_auth_unavailable"))
  assert_true(events.contains("host_account_unavailable"))
  assert_true(events.contains("delivery_failed"))
  assert_false(events.contains("fixture-gh-first"))
}

///|
test "gh auth merge replaces only the managed github account and preserves other host values" {
  let previous : Json = {
    "github.com": {
      "git_protocol": "ssh",
      "api_host": "api.github.com",
      "user": "previous",
      "oauth_token": "fixture-old",
      "users": { "previous": { "oauth_token": "fixture-old" } },
    },
    "enterprise.example": {
      "oauth_token": "fixture-enterprise",
      "git_protocol": "ssh",
      "users": { "other": { "oauth_token": "fixture-enterprise" } },
    },
  }
  let payload = gh_document(
    "missing\u0000/config/gh\u0000update\u0000" + previous.stringify(),
    "next",
    "fixture-next",
  )
  let document = @json.parse(payload.split("\n").to_array()[2].to_owned())
  assert_eq(
    field(document, "enterprise.example"),
    field(previous, "enterprise.example"),
  )
  assert_eq(
    field(field(document, "github.com").unwrap(), "user"),
    Some(Json::string("next")),
  )
  assert_eq(
    field(field(document, "github.com").unwrap(), "git_protocol"),
    Some(Json::string("ssh")),
  )
  assert_eq(
    field(field(document, "github.com").unwrap(), "api_host"),
    Some(Json::string("api.github.com")),
  )
  assert_false(payload.contains("fixture-old"))
}

///|
async test "bulk gh auth diagnostics correlate concurrent success and failure to each workspace" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  fake_gh(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main, addons: {ghAuth: true}}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, output, errors) = invoke("create", env, directory)
  assert_eq(code, 0, msg=errors)
  let receipt = @json.parse(output)
  let state = field(receipt, "userData").unwrap()
  let payload : Json = { "schemaVersion": 1, "recipeResult": receipt }
  defer ignore(invoke("destroy", env, directory, payload~))
  let original = required(state, "tunnelDirectory")
  let second_dir = adapter_path_parent(original) + "/second"
  @fs.mkdir(second_dir)
  let second = @json.parse(@fs.read_file(original + "/state.json").text())
  set_field(second, "workspaceId", Json::string("second"))
  set_field(second, "socketDirectory", Json::string(@fs.tmpdir(prefix="oe")))
  @fs.write_file(second_dir + "/state.json", second.stringify())
  @fs.write_file(second_dir + "/enabled", "")
  @fs.write_file(
    directory + "/list-result",
    Json::array([
      { "id": "test-id", "uid": field(state, "workspaceUid").unwrap() },
      { "id": "second", "uid": field(state, "workspaceUid").unwrap() },
    ]).stringify(),
  )
  @fs.write_file(directory + "/fail-second-gh", "")
  @fs.write_file(directory + "/.local/state/orca-env-devsy/events.jsonl", "")
  let (code, _, errors) = invoke("reconnect", env, directory)
  assert_eq(code, 0, msg=errors)
  let events = @fs.read_file(
    directory + "/.local/state/orca-env-devsy/events.jsonl",
  ).text()
  let operations : Map[String, String] = Map([])
  let complete : Map[String, String] = Map([])
  for line in events.split("\n") {
    if line == "" {
      continue
    }
    let event = @json.parse(line.to_owned())
    if field(event, "stage") != Some(Json::string("gh-auth")) {
      continue
    }
    let id = required(event, "operationId")
    let target = required(event, "workspaceId")
    if operations.get(target) is Some(existing) {
      assert_eq(id, existing)
    } else {
      operations.set(target, id)
    }
    if field(event, "phase") == Some(Json::string("complete")) {
      complete.set(target, required(event, "status"))
    }
  }
  assert_eq(complete.get("test-id"), Some("success"))
  assert_eq(complete.get("second"), Some("warning"))
  assert_true(operations.get("test-id") != operations.get("second"))
  assert_false(events.contains("fixture-gh-first"))
}

///|
fn adapter_path_parent(path : String) -> String {
  let pieces = path.split("/").to_array()
  pieces[:pieces.length() - 1].map(piece => piece.to_owned()).join("/")
}

///|
test "gh addon setting follows common profile recipe precedence and rejects non booleans" {
  let document : Json = {
    "devsy": {
      "connection": "ssh",
      "addons": { "ghAuth": true },
      "profiles": { "selected": { "addons": { "ghAuth": false } } },
    },
    "environmentRecipes": [
      {
        "id": "test",
        "devsy": { "profile": "selected", "addons": { "ghAuth": true } },
      },
    ],
  }
  assert_true(resolve_settings(document, "test", _ => None).gh_auth)
  let recipes = match field(document, "environmentRecipes") {
    Some(Json::Array(items)) => items
    _ => []
  }
  set_field(field(recipes[0], "devsy").unwrap(), "addons", Json::empty_object())
  assert_false(resolve_settings(document, "test", _ => None).gh_auth)
  set_field(field(document, "devsy").unwrap(), "addons", { "ghAuth": "true" })
  try {
    ignore(resolve_settings(document, "test", _ => None))
    fail("invalid setting accepted")
  } catch {
    InvalidConfig(message) =>
      assert_eq(message, "devsy.addons.ghAuth must be a boolean")
    _ => fail("unexpected error")
  }
}
