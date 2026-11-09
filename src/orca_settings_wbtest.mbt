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
    assert_true(
      @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl")
      .text()
      .contains("\"phase\":\"legacy\""),
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

///|
async test "settings transfer uses the relocated Orca settings module" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  with_fake_tunnel(directory, async fn() {
    @fs.write_file(
      directory + "/orca.yaml",
      "devsy: {connection: orca-server, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
    )
    settings_fixture(directory, env)
    let shared = directory + "/orca-host/resources/app.asar.unpacked/out/shared"
    let relocated = shared + "/source-control/ai/settings"
    @fs.mkdir(relocated, recursive=true)
    assert_eq(
      @process.run("mv", [
        shared + "/source-control-ai-settings.js",
        relocated + "/source-control-ai-settings.js",
      ]),
      0,
    )
    let (status, _, errors) = invoke("create", env, directory)
    assert_eq(status, 0, msg=errors)
    let settings = @json.parse(
      @fs.read_file(directory + "/delivered-settings").text(),
    )
    assert_eq(field(settings, "defaultTuiAgent"), Some(Json::string("codex")))
    assert_true(
      @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl")
      .text()
      .contains("\"phase\":\"relocated\""),
    )
  })
}

///|
async test "settings import preserves SQLite state and rejects unsupported schemas" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  env.set("HOME", @env.get_env_var("HOME").unwrap())
  let bun = "bun"
  let resources = directory + "/resources"
  let root = resources + "/app.asar.unpacked/out"
  let user_data = directory + "/profile"
  @fs.mkdir(root + "/main/persistence/profile-state", recursive=true)
  @fs.mkdir(root + "/main/orca-profiles", recursive=true)
  @fs.mkdir(root + "/shared", recursive=true)
  @fs.mkdir(user_data, recursive=true)
  @fs.write_file(
    root + "/main/persistence/profile-state/profile-state-access.js",
    "exports.acquireProfileStateMaintenance=()=>({release(){}})",
  )
  @fs.write_file(
    root + "/main/orca-profiles/profile-index-store.js",
    "exports.ensureActiveOrcaProfile=u=>({dataFile:u+'/legacy.json',stateDatabaseFile:u+'/state.db',profile:{id:'fixture'}})",
  )
  @fs.write_file(
    root + "/shared/constants.js",
    "exports.getDefaultPersistedState=()=>({settings:{agentStatusHooksEnabled:true,sourceControlAi:{actions:{branchName:{agentId:null},conversationName:{agentId:null}}}}})",
  )
  @fs.write_file(
    root + "/main/persistence/profile-state/profile-state-domain-reader.js",
    "const {DatabaseSync}=require('node:sqlite');const crypto=require('node:crypto');function read(db){const row=db.prepare(\"SELECT payload,content_hash FROM profile_state_documents WHERE domain='settings'\").get();if(row&&crypto.createHash('sha256').update(row.payload).digest('hex')!==row.content_hash)return {kind:'unreadable'};return {kind:'values',revision:Number(db.prepare(\"SELECT value FROM profile_state_meta WHERE key='revision'\").get().value),values:new Map(row?[[\"settings\",JSON.parse(row.payload)]]:[])}}exports.readProfileStateDomains=(file)=>{const db=new DatabaseSync(file);try{db.prepare('SELECT * FROM required_table').all();return read(db)}catch{return {kind:'unreadable'}}finally{db.close()}}",
  )
  let setup = "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1]);db.exec(\"PRAGMA user_version=3;CREATE TABLE required_table(id INTEGER);CREATE TABLE profile_state_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);CREATE TABLE profile_state_documents(domain TEXT PRIMARY KEY,payload TEXT NOT NULL,domain_version INTEGER NOT NULL,revision INTEGER NOT NULL,updated_at INTEGER NOT NULL,content_hash TEXT NOT NULL);INSERT INTO profile_state_meta VALUES('profile_id','fixture'),('revision','0')\");db.close()"
  let db = user_data + "/state.db"
  let (setup_status, _, setup_error) = @process.collect_output("bun", [
    "-e", setup, db,
  ])
  assert_eq(setup_status, 0, msg=setup_error.text())
  let payload = "{\"defaultTuiAgent\":\"codex\",\"sourceControlAi\":{\"actions\":{\"branchName\":{\"agentId\":\"codex\"}}}}"
  ignore(
    settings_process(
      bun,
      ["-e", orca_settings_script(), "--", "import", resources, user_data],
      environment=env,
      input=payload,
    ),
  )
  let inspect = "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1]);const r=db.prepare(\"SELECT payload,revision,domain_version FROM profile_state_documents WHERE domain='settings'\").get();console.log(JSON.stringify({settings:JSON.parse(r.payload),revision:r.revision,version:r.domain_version}));db.exec('PRAGMA user_version=99');db.close()"
  let (inspect_status, result, inspect_error) = @process.collect_output("bun", [
    "-e", inspect, db,
  ])
  assert_eq(inspect_status, 0, msg=inspect_error.text())
  let saved = @json.parse(result.text())
  assert_eq(field(saved, "revision"), Some(Json::number(1)))
  assert_eq(field(saved, "version"), Some(Json::number(1)))
  assert_eq(
    field(field(saved, "settings").unwrap(), "defaultTuiAgent"),
    Some(Json::string("codex")),
  )
  try {
    ignore(
      settings_process(
        bun,
        ["-e", orca_settings_script(), "--", "import", resources, user_data],
        environment=env,
        input=payload,
      ),
    )
    fail("unsupported schema must fail")
  } catch {
    SettingsProcessError(phase, code, _) => {
      assert_eq(phase, "profile")
      assert_eq(code, "INCOMPATIBLE")
    }
    _ => fail("unexpected error")
  }
  let corrupt = "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1]);db.exec('PRAGMA user_version=3;DROP TABLE required_table');db.close()"
  let (corrupt_status, _, _) = @process.collect_output("bun", [
    "-e", corrupt, db,
  ])
  assert_eq(corrupt_status, 0)
  try {
    ignore(
      settings_process(
        bun,
        ["-e", orca_settings_script(), "--", "import", resources, user_data],
        environment=env,
        input=payload,
      ),
    )
    fail("invalid database must fail before writing")
  } catch {
    SettingsProcessError(phase, code, _) => {
      assert_eq(phase, "profile")
      assert_eq(code, "INVALID")
    }
    _ => fail("unexpected error")
  }
  let check = "const {DatabaseSync}=require('node:sqlite');const db=new DatabaseSync(process.argv[1]);console.log(db.prepare(\"SELECT value FROM profile_state_meta WHERE key='revision'\").get().value);db.close()"
  let (check_status, revision, _) = @process.collect_output("bun", [
    "-e", check, db,
  ])
  assert_eq(check_status, 0)
  assert_eq(revision.text().trim(), "1")
}
