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
  let resources = host + "/resources/app.asar.unpacked/out"
  @fs.mkdir(resources + "/main/persistence/profile-state", recursive=true)
  @fs.mkdir(resources + "/shared", recursive=true)
  let modules = [
    (
      "main/persistence/profile-state/profile-state-active-location.js", "exports.getActiveProfileStateLocation = userData => ({databaseFile:userData + '/settings.json',profileId:'fixture'});",
    ),
    (
      "main/persistence/profile-state/profile-state-domain-reader.js", "exports.readProfileStateDomains = file => ({kind:'values',values:new Map([['settings',JSON.parse(require('node:fs').readFileSync(file,'utf8'))]])});",
    ),
    (
      "shared/source-control-ai-settings.js", "exports.normalizeSourceControlAiSettings = source => {const result={agentId:null,actions:{branchName:{commandInputTemplate:'{basePrompt}'},conversationName:{commandInputTemplate:'{basePrompt}'}},...source};if(typeof result.actions.branchName.agentArgs==='string')result.actions={...result.actions,branchName:{...result.actions.branchName,agentArgs:result.actions.branchName.agentArgs.trim()}};return result;};",
    ),
    (
      "shared/auto-rename-branch-from-work-settings.js", "exports.normalizeAutoRenameBranchFromWorkDefaultOn = source => ({autoRenameBranchFromWork:source.autoRenameBranchFromWork??true,autoRenameBranchFromWorkDefaultedOn:true});",
    ),
  ]
  for (name, content) in modules {
    @fs.write_file(resources + "/" + name, content)
  }
  @fs.write_file(
    host + "/settings.json",
    "{\"defaultTuiAgent\":\"codex\",\"disabledTuiAgents\":[\"claude\"]}",
  )
  let (_, bun, _) = @process.collect_output("sh", ["-c", "command -v bun"])
  assert_eq(
    @process.run("cp", [@fs.realpath(bun.text().trim()), host + "/orca-ide"]),
    0,
  )
  let (status, pid, errors) = @process.collect_output("sh", [
    "-c",
    quote(host + "/orca-ide") +
    " -e 'setInterval(() => {}, 1000)' </dev/null >/dev/null 2>&1 & echo $!",
  ])
  assert_eq(status, 0, msg=errors.text())
  @fs.write_file(
    host + "/orca-runtime.json",
    "{\"pid\":" + pid.text().trim().to_owned() + "}",
  )
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
    @fs.write_file(directory + "/orca-host/settings.json", source.stringify())
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
      Some(Json::string("--opaque " + secret)),
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
