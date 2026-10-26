///|
async fn bulk_fixture_run(
  args : Array[String],
  env : Map[String, String],
) -> (Int32, Json, String) {
  let (code, out, err) = @process.collect_output(
    integration_binary(),
    args,
    extra_env=env,
  )
  (code, @json.parse(out.text()), err.text())
}

///|
fn bulk_first(output : Json) -> Json {
  match field(output, "workspaces") {
    Some(Json::Array([first, ..])) => first
    _ => abort("No workspace result")
  }
}

///|
async test "bulk status selects saved provider identities and emits pretty evidence" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, created, err) = invoke("create", env, directory)
  assert_eq(code, 0, msg=err)
  let payload : Json = {
    "schemaVersion": 1,
    "recipeResult": @json.parse(created),
  }
  defer ignore(invoke("destroy", env, directory, payload~))
  let (code, out, err) = @process.collect_output(
    integration_binary(),
    ["status", "--provider", "fixture-provider"],
    extra_env=env,
  )
  assert_eq(code, 0, msg=err.text())
  assert_true(out.text().contains("\n  \""))
  let row = bulk_first(@json.parse(out.text()))
  assert_eq(field(row, "vmStatus"), Some(Json::string("Running")))
  assert_eq(field(row, "activity"), Some(Json::string("idle")))
  assert_eq(field(row, "identityVerified"), Some(Json::boolean(true)))
  assert_true(field(row, "evidence") is Some(_))
  let (_, wrong, _) = bulk_fixture_run(["status", "--provider", "other"], env)
  assert_eq(field(wrong, "workspaces"), Some(Json::array([])))
}

///|
async test "bulk stop protects active and unknown work and force overrides only activity" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, created, err) = invoke("create", env, directory)
  assert_eq(code, 0, msg=err)
  let payload : Json = {
    "schemaVersion": 1,
    "recipeResult": @json.parse(created),
  }
  defer ignore(invoke("destroy", env, directory, payload~))
  for activity in ["active", "unknown"] {
    @fs.write_file(
      directory + "/activity",
      ({ "schemaVersion": 1, "activity": activity } : Json).stringify(),
    )
    let (code, result, err) = bulk_fixture_run(
      ["stop", "--provider", "fixture-provider"],
      env,
    )
    assert_eq(code, 0, msg=err)
    assert_eq(
      field(bulk_first(result), "outcome"),
      Some(Json::string("skipped")),
    )
    assert_false(@fs.exists(directory + "/stopped"))
  }
  let (code, result, err) = bulk_fixture_run(
    ["stop", "--force", "--provider", "fixture-provider"],
    env,
  )
  assert_eq(code, 0, msg=err)
  assert_eq(field(bulk_first(result), "outcome"), Some(Json::string("success")))
  assert_true(@fs.exists(directory + "/stopped"))
  @fs.remove(directory + "/stopped")
  @fs.write_file(directory + "/uid", "replacement-uid")
  let (code, result, err) = bulk_fixture_run(
    ["stop", "--force", "--provider", "fixture-provider"],
    env,
  )
  assert_eq(code, 0, msg=err)
  assert_eq(
    field(bulk_first(result), "identityVerified"),
    Some(Json::boolean(false)),
  )
  assert_false(@fs.exists(directory + "/stopped"))
}

///|
async test "bulk idle stop and resume restore the connection without duplicate up" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, created, err) = invoke("create", env, directory)
  assert_eq(code, 0, msg=err)
  let payload : Json = {
    "schemaVersion": 1,
    "recipeResult": @json.parse(created),
  }
  defer ignore(invoke("destroy", env, directory, payload~))
  let (code, _, err) = bulk_fixture_run(
    ["stop", "--provider", "fixture-provider"],
    env,
  )
  assert_eq(code, 0, msg=err)
  assert_true(@fs.exists(directory + "/stopped"))
  let (code, result, err) = bulk_fixture_run(
    ["resume", "--provider", "fixture-provider"],
    env,
  )
  assert_eq(code, 0, msg=err)
  assert_eq(field(bulk_first(result), "outcome"), Some(Json::string("success")))
  assert_false(@fs.exists(directory + "/stopped"))
  @fs.write_file(directory + "/args", "")
  let (code, result, err) = bulk_fixture_run(
    ["resume", "--provider", "fixture-provider"],
    env,
  )
  assert_eq(code, 0, msg=err)
  assert_eq(
    field(bulk_first(result), "reason"),
    Some(Json::string("already_running")),
  )
  assert_false(@fs.read_file(directory + "/args").text().contains("\nup\n"))
}

///|
async test "bulk operation failure preserves JSON while failing the process" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, created, err) = invoke("create", env, directory)
  assert_eq(code, 0, msg=err)
  let payload : Json = {
    "schemaVersion": 1,
    "recipeResult": @json.parse(created),
  }
  defer ignore(invoke("destroy", env, directory, payload~))
  @fs.write_file(directory + "/fail-stop", "")
  let (code, result, _) = bulk_fixture_run(
    ["stop", "--force", "--provider", "fixture-provider"],
    env,
  )
  assert_true(code != 0)
  assert_eq(field(result, "failed"), Some(Json::number(1)))
  assert_eq(field(bulk_first(result), "outcome"), Some(Json::string("failed")))
}

///|
async test "bulk continues other saved VMs after an operation failure" {
  let (first, env) = fixture()
  defer cleanup_fixture(first)
  let (second, _) = fixture()
  defer cleanup_fixture(second)
  for pair in [(first, "first-vm"), (second, "second-vm")] {
    let (directory, id) = pair
    @fs.write_file(directory + "/created", "")
    @fs.write_file(directory + "/workspace-id", id)
    @fs.write_file(directory + "/uid", id + "-uid")
    let saved = first + "/.local/state/orca-env-devsy/tunnels/" + id
    @fs.mkdir(saved, recursive=true)
    @fs.write_file(saved + "/enabled", "")
    let state : Json = {
      "command": [
        "/usr/bin/env",
        "FAKE_HOME=" + directory,
        directory + "/bin/devsy",
      ],
      "workspaceId": id,
      "workspaceUid": id + "-uid",
      "context": "fixture-context",
      "user": "developer",
      "connection": "ssh",
      "projectRoot": "/workspace/repo",
      "devsyEnv": { "HOME": directory },
    }
    @fs.write_file(saved + "/state.json", state.stringify())
  }
  @fs.write_file(first + "/fail-stop", "")
  let invalid = first + "/.local/state/orca-env-devsy/tunnels/invalid"
  @fs.mkdir(invalid)
  @fs.write_file(invalid + "/enabled", "")
  @fs.write_file(
    invalid + "/state.json",
    (
      {
        "workspaceId": "invalid",
        "workspaceUid": "invalid-uid",
        "context": "fixture-context",
        "user": "developer",
      } : Json).stringify(),
  )
  let (code, result, _) = bulk_fixture_run(
    ["stop", "--force", "--provider", "fixture-provider", "--jobs", "1"],
    env,
  )
  assert_true(code != 0)
  assert_eq(field(result, "failed"), Some(Json::number(1)))
  guard field(result, "discoveryErrors") is Some(Json::Array(errors)) else {
    abort("Missing discovery errors")
  }
  assert_eq(errors.length(), 1)
  assert_false(@fs.exists(first + "/stopped"))
  assert_true(@fs.exists(second + "/stopped"))
  guard field(result, "workspaces") is Some(Json::Array(rows)) else {
    abort("Missing workspace results")
  }
  assert_eq(rows.length(), 2)
  assert_eq(field(rows[0], "outcome"), Some(Json::string("failed")))
  assert_eq(field(rows[1], "outcome"), Some(Json::string("success")))
}
