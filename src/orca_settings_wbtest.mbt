///|
async fn settings_fixture(
  directory : String,
  env : Map[String, String],
) -> Unit {
  let host = directory + "/orca-host"
  env.set("ORCA_USER_DATA_PATH", host)
  if @fs.exists(host + "/orca-runtime.json") {
    return
  }
  @fs.mkdir(host + "/resources/app.asar", recursive=true)
  @fs.mkdir(host + "/profiles/fixture", recursive=true)
  @fs.write_file(
    host + "/orca-profile-index.json",
    "{\"activeProfileId\":\"fixture\",\"profiles\":[{\"id\":\"fixture\"}]}",
  )
  let setup = "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1]);db.exec(\"CREATE TABLE profile_state_documents (domain TEXT PRIMARY KEY,payload TEXT NOT NULL);INSERT INTO profile_state_documents VALUES ('settings','{}')\");db.close()"
  let (status, _, error) = @process.collect_output("bun", [
    "-e",
    setup,
    host + "/profiles/fixture/profile-state.db",
  ])
  assert_eq(status, 0, msg=error.text())
  write_fixture_settings(
    host,
    @json.parse(
      "{\"defaultTuiAgent\":\"codex\",\"disabledTuiAgents\":[\"claude\"],\"autoRenameBranchFromWorkDefaultedOn\":true,\"sourceControlAi\":{\"actions\":{}}}",
    ),
  )
  let (_, bun, _) = @process.collect_output("sh", ["-c", "command -v bun"])
  assert_eq(
    @process.run("cp", [@fs.realpath(bun.text().trim()), host + "/orca-ide"]),
    0,
  )
  let sink = @process.redirect_to_file("/dev/null", shared=true)
  defer sink.close()
  let pid = @process.spawn_orphan(
    host + "/orca-ide",
    ["-e", "setInterval(() => {}, 1000)"],
    extra_env=env,
    stdin=@process.redirect_from_file("/dev/null"),
    stdout=sink,
    stderr=sink,
  )
  let executable = settings_executable(pid)
  assert_eq(executable, @fs.realpath(host + "/orca-ide"))
  @fs.write_file(
    host + "/orca-runtime.json",
    "{\"pid\":" + pid.to_string() + "}",
  )
}

///|
async fn write_fixture_settings(host : String, settings : Json) -> Unit {
  let script = "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1]);db.prepare(\"UPDATE profile_state_documents SET payload=? WHERE domain='settings'\").run(process.argv[2]);db.close()"
  let (status, _, error) = @process.collect_output("bun", [
    "-e",
    script,
    host + "/profiles/fixture/profile-state.db",
    settings.stringify(),
  ])
  assert_eq(status, 0, msg=error.text())
}

///|
async test "server initialization reports the child exit code" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  settings_fixture(directory, env)
  let host = directory + "/orca-host"
  let cli = host + "/resources/app.asar/out/cli"
  @fs.mkdir(cli, recursive=true)
  @fs.write_file(cli + "/index.js", "process.exit(17)")
  @fs.write_file(directory + "/input", "{}")
  let (status, _, errors) = @process.collect_output(
    host + "/orca-ide",
    ["-e", orca_settings_script(), "--", "import", host, directory],
    extra_env=env,
    stdin=@process.redirect_from_file(directory + "/input"),
  )
  assert_eq(status, 1)
  assert_eq(
    field(@json.parse(errors.text()), "code"),
    Some(Json::string("SERVER_EXIT_17")),
  )
}

///|
async test "settings export waits for the host to save its migrated settings" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  settings_fixture(directory, env)
  let host = directory + "/orca-host"
  write_fixture_settings(host, { "autoRenameBranchFromWork": false })
  @async.with_task_group(async fn(group) {
    let saved = group.spawn(async fn() {
      @async.sleep(300)
      write_fixture_settings(host, {
        "autoRenameBranchFromWork": true,
        "autoRenameBranchFromWorkDefaultedOn": true,
        "sourceControlAi": { "actions": {} },
      })
    })
    let (status, output, errors) = @process.collect_output(
      host + "/orca-ide",
      ["-e", orca_settings_script(), "--", "export", host],
      extra_env=env,
    )
    saved.wait()
    assert_eq(status, 0, msg=errors.text())
    assert_eq(
      field(@json.parse(output.text()), "autoRenameBranchFromWork"),
      Some(Json::boolean(true)),
    )
  })
}

///|
async test "settings apply before serving only on create and payload never enters diagnostics" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    settings_fixture(directory, env)
    let secret = "fixture-settings-private-argument"
    let source : Json = {
      "defaultTuiAgent": "codex",
      "disabledTuiAgents": ["claude"],
      "autoRenameBranchFromWork": false,
      "autoRenameBranchFromWorkDefaultedOn": true,
      "branchPrefix": "custom",
      "branchPrefixCustom": "team",
      "agentCmdOverrides": { "codex": "/host/private/bin/codex" },
      "agentDefaultEnv": { "codex": { "PRIVATE_VALUE": secret } },
      "sourceControlAi": {
        "agentId": "codex",
        "customAgentCommand": secret,
        "actions": {
          "branchName": {
            "agentId": "codex",
            "commandInputTemplate": "{basePrompt}",
            "agentArgs": "  --opaque " + secret + "  ",
          },
          "conversationName": {
            "agentId": null,
            "commandInputTemplate": "name: {firstPrompt}",
          },
          "commitMessage": { "agentId": "claude", "agentArgs": secret },
        },
        "selectedModelByAgent": { "codex": "gpt-5.4-mini" },
        "selectedModelByAgentByHost": {
          "local": { "codex": "gpt-5.5" },
          "runtime:other": { "claude": secret },
        },
        "selectedThinkingByModel": { "gpt-5.5": "high" },
        "discoveredModelsByAgent": { "codex": [secret] },
        "modelOverridesByOperation": {
          "branchName": { "selectedModelByAgent": { "codex": "gpt-5.4" } },
          "commitMessage": { "selectedModelByAgent": { "codex": secret } },
        },
      },
    }
    write_fixture_settings(directory + "/orca-host", source)
    let (status, output, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let receipt : Json = {
      "schemaVersion": 1,
      "recipeResult": @json.parse(output),
    }
    let delivered = @fs.read_file(directory + "/delivered-settings").text()
    let settings = @json.parse(delivered)
    assert_eq(
      field(settings, "defaultTuiAgent"),
      field(source, "defaultTuiAgent"),
    )
    assert_eq(
      field(settings, "autoRenameBranchFromWork"),
      Some(Json::boolean(false)),
    )
    assert_eq(field(settings, "agentCmdOverrides"), None)
    assert_eq(field(settings, "agentDefaultEnv"), None)
    let ai = field(settings, "sourceControlAi").unwrap()
    assert_eq(field(ai, "customAgentCommand"), None)
    assert_eq(field(ai, "discoveredModelsByAgent"), None)
    assert_eq(field(field(ai, "actions").unwrap(), "commitMessage"), None)
    assert_eq(
      field(field(ai, "selectedModelByAgentByHost").unwrap(), "runtime:other"),
      None,
    )
    assert_eq(
      field(field(ai, "modelOverridesByOperation").unwrap(), "commitMessage"),
      None,
    )
    assert_eq(
      field(
        field(field(ai, "actions").unwrap(), "branchName").unwrap(),
        "agentArgs",
      ),
      Some(Json::string("  --opaque " + secret + "  ")),
    )
    assert_true(delivered.contains(secret))
    assert_false(errors.contains(secret))
    assert_false(@fs.read_file(directory + "/ssh-args").text().contains(secret))
    assert_false(
      @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl")
      .text()
      .contains(secret),
    )
    assert_true(
      @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl")
      .text()
      .contains("\"stage\":\"orca-settings\",\"status\":\"success\""),
    )
    @fs.remove(directory + "/delivered-settings")
    let (status, _, errors) = invoke("suspend", env, directory, payload=receipt)
    assert_eq(status, 0, msg=errors)
    let (status, _, errors) = invoke("resume", env, directory, payload=receipt)
    assert_eq(status, 0, msg=errors)
    let (status, _, errors) = invoke("recover", env, directory, payload=receipt)
    assert_eq(status, 0, msg=errors)
    let (status, _, errors) = invoke("restart", env, directory, payload=receipt)
    assert_eq(status, 0, msg=errors)
    assert_false(@fs.exists(directory + "/delivered-settings"))
  })
}

///|
async test "settings transfer failure prevents serving and reclaims created workspace" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    @fs.write_file(directory + "/fail-settings", "")
    let (status, output, errors) = invoke("create", env, directory)
    assert_true(status != 0)
    assert_eq(output, "")
    assert_true(errors.contains("Orca settings transfer failed"), msg=errors)
    assert_false(@fs.exists(directory + "/served"))
    assert_false(@fs.exists(directory + "/created"))
    let events = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(events.contains("\"phase\":\"remote/write\""))
    assert_true(events.contains("\"errorType\":\"ENOSPC\""))
    assert_true(events.contains("\"exitCode\":1"))
  })
}
