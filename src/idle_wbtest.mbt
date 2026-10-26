///|
test "idle durations are positive exact values and follow selected layers" {
  let doc : Json = {
    "devsy": {
      "connection": "ssh",
      "idleTimeout": "1h",
      "profiles": { "p": { "idleTimeout": "20m" } },
    },
    "environmentRecipes": [
      { "id": "x", "devsy": { "profile": "p", "idleTimeout": "30s" } },
    ],
  }
  assert_eq(resolve_settings(doc, "x", _ => None).idle_timeout_ms, Some(30000L))
  assert_eq(parse_idle_timeout("30m"), 1800000L)
  assert_eq(parse_idle_timeout("2d"), 172800000L)
  for
    invalid in ["", "0m", "-1s", "1.5m", "30", "1ms", "999999999999999999999h"] {
    let failed = try {
      ignore(parse_idle_timeout(invalid))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
  let common : Json = {
    "devsy": {
      "connection": "ssh",
      "idleTimeout": "1h",
      "profile": "p",
      "profiles": { "p": { "idleTimeout": "20m" } },
    },
    "environmentRecipes": [{ "id": "x" }],
  }
  assert_eq(
    resolve_settings(common, "x", _ => None).idle_timeout_ms,
    Some(1200000L),
  )
  let absent : Json = {
    "devsy": { "connection": "ssh" },
    "environmentRecipes": [{ "id": "x" }],
  }
  assert_eq(resolve_settings(absent, "x", _ => None).idle_timeout_ms, None)
}

///|
test "idle time counts unknown only after idle and retains accumulated time across worker restarts" {
  let timer : IdleTimer = { elapsed: 0, seen: false, previous: None, epoch: 0, }
  timer.advance("unknown", 100)
  timer.advance("unknown", 200)
  assert_eq(timer.elapsed, 0)
  timer.advance("idle", 300)
  timer.advance("unknown", 400)
  assert_eq(timer.elapsed, 100)
  timer.previous = None
  timer.advance("unknown", 999999)
  assert_eq(timer.elapsed, 100)
  timer.advance("idle", 1000099)
  assert_eq(timer.elapsed, 200)
  timer.advance("active", 1000199)
  assert_eq(timer.elapsed, 0)
  assert_false(timer.seen)
  timer.advance("unknown", 1000299)
  assert_eq(timer.elapsed, 0)
  assert_true(@async.now() >= 0)
}

///|
async fn idle_fixture(timeout : Int32) -> (String, Map[String, String], Json) {
  let (directory, env) = fixture()
  let saved = directory + "/.local/state/orca-env-devsy/tunnels/vm"
  @fs.mkdir(saved, recursive=true)
  @fs.write_file(saved + "/enabled", "")
  @fs.write_file(saved + "/idle-enabled", "")
  @fs.write_file(saved + "/pairing-code", "fixture-pairing")
  @fs.write_file(directory + "/created", "")
  @fs.write_file(directory + "/uid", "idle-uid")
  @fs.write_file(directory + "/workspace-id", "idle-vm")
  env.set("ORCA_ENV_DEVSY_TEST_IDLE_POLL_MS", "20")
  let state : Json = {
    "workspaceId": "idle-vm",
    "workspaceUid": "idle-uid",
    "user": "developer",
    "context": "fixture-context",
    "connection": "ssh",
    "projectRoot": "/workspace/repo",
    "command": [directory + "/bin/devsy"],
    "devsyEnv": {
      "PATH": env.get("PATH").unwrap(),
      "HOME": directory,
      "XDG_STATE_HOME": directory + "/.local/state",
    },
    "socketDirectory": directory + "/socket",
    "tunnelDirectory": saved,
    "idleTimeoutMs": timeout,
    "idleProvider": "fixture-provider",
  }
  @fs.write_file(saved + "/state.json", state.stringify())
  (directory, env, state)
}

///|
async fn idle_wait_for(predicate : async () -> Bool) -> Unit {
  @async.with_timeout(10000, async fn() {
    while !predicate() {
      @async.sleep(10)
    }
  })
}

///|
async test "worker stops only its idle VM with completed one-shot mux observations" {
  let (directory, env, state) = idle_fixture(120)
  defer cleanup_fixture(directory)
  let saved = required(state, "tunnelDirectory")
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        saved,
      ],
      extra_env=env,
      no_wait=true,
    )
    idle_wait_for(async fn() { @fs.exists(directory + "/stopped") })
    let starts = @fs.read_file(directory + "/idle-starts").text()
    assert_true(starts.split("\n").count() > 3)
    assert_eq(
      @fs.read_file(directory + "/idle-closed").text().split("\n").count(),
      starts.split("\n").count(),
    )
    assert_true(
      @fs.read_file(directory + "/idle-requests").text().split("\n").count() > 3,
    )
    idle_wait_for(async fn() { @fs.exists(directory + "/idle-closed") })
    idle_wait_for(async fn() {
      field(idle_status(state), "reason") ==
      Some(Json::string("workspace_stopped"))
    })
    let status = idle_status(state)
    assert_eq(field(status, "elapsedMs"), Some(Json::number(0)))
    @fs.remove(saved + "/enabled")
    assert_eq(child.wait(), 0)
  })
}

///|
async test "worker fresh active check cancels an otherwise due stop" {
  let (directory, env, state) = idle_fixture(1)
  defer cleanup_fixture(directory)
  @fs.write_file(directory + "/idle-final-active", "")
  let saved = required(state, "tunnelDirectory")
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        saved,
      ],
      extra_env=env,
      no_wait=true,
    )
    idle_wait_for(async fn() {
      if !@fs.exists(directory + "/idle-requests") {
        return false
      }
      @fs.read_file(directory + "/idle-requests").text().split("\n").count() >=
      4
    })
    @fs.write_file(
      directory + "/activity",
      ({ "schemaVersion": 1, "activity": "active" } : Json).stringify(),
    )
    assert_false(@fs.exists(directory + "/stopped"))
    @fs.remove(saved + "/enabled")
    assert_eq(child.wait(), 0)
  })
}

///|
async test "idle persistence excludes restart gaps and reset fences older observers" {
  let (directory, _, state) = idle_fixture(100)
  defer cleanup_fixture(directory)
  let timer : IdleTimer = {
    elapsed: 0,
    seen: false,
    epoch: -1,
    previous: None,
  }
  idle_tick(state, timer, "idle", "monitoring", 0)
  idle_tick(state, timer, "unknown", "monitoring", 80)
  let restarted : IdleTimer = {
    elapsed: 0,
    seen: false,
    epoch: -1,
    previous: None,
  }
  idle_tick(state, restarted, "unknown", "monitoring", 9999999)
  assert_eq(restarted.elapsed, 80)
  idle_tick(state, restarted, "unknown", "monitoring", 10000029)
  assert_eq(
    field(idle_status(state), "reason"),
    Some(Json::string("awaiting_idle_confirmation")),
  )
  idle_reset(state, "workspace_resumed")
  idle_tick(state, timer, "unknown", "monitoring", 10000099)
  assert_eq(timer.elapsed, 0)
  assert_false(timer.seen)
  set_field(state, "workspaceUid", Json::string("replacement"))
  assert_eq(
    field(idle_status(state), "reason"),
    Some(Json::string("timer_unavailable")),
  )
}

///|
async test "unknown after idle reaches the deadline but cannot authorize stopping" {
  let (directory, env, state) = idle_fixture(120)
  defer cleanup_fixture(directory)
  let saved = required(state, "tunnelDirectory")
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        saved,
      ],
      extra_env=env,
      no_wait=true,
    )
    idle_wait_for(async fn() {
      let value = idle_status(state)
      field(value, "activity") == Some(Json::string("idle"))
    })
    for code in ["unsupported_native_capabilities", "unverifiable_process"] {
      let observation : Json = {
        "schemaVersion": 1,
        "activity": "unknown",
        "errors": [{ "code": code }],
      }
      @fs.write_file(directory + "/activity", observation.stringify())
      idle_wait_for(async fn() {
        let events = @fs.read_file(
          directory + "/.local/state/orca-env-devsy/events.jsonl",
        ).text()
        events
        .split("\n")
        .any(line => {
          if line == "" {
            return false
          }
          let event = @json.parse(line)
          match field(event, "evidence") {
            Some(evidence) =>
              field(evidence, "observation") == Some(observation)
            None => false
          }
        })
      })
    }
    idle_wait_for(async fn() {
      field(idle_status(state), "reason") ==
      Some(Json::string("awaiting_idle_confirmation"))
    })
    assert_false(@fs.exists(directory + "/stopped"))
    assert_eq(
      field(idle_status(state), "activity"),
      Some(Json::string("unknown")),
    )
    @fs.write_file(
      directory + "/activity",
      ({ "schemaVersion": 1, "activity": "idle" } : Json).stringify(),
    )
    idle_wait_for(async fn() { @fs.exists(directory + "/stopped") })
    @fs.remove(saved + "/enabled")
    assert_eq(child.wait(), 0)
  })
}

///|
async test "observer reconnect backs off and later recovers without leaking sessions" {
  let (directory, env, state) = idle_fixture(120)
  defer cleanup_fixture(directory)
  let saved = required(state, "tunnelDirectory")
  @fs.write_file(directory + "/fail-idle-connect", "")
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        saved,
      ],
      extra_env=env,
      no_wait=true,
    )
    idle_wait_for(async fn() {
      if !@fs.exists(directory + "/idle-starts") {
        return false
      }
      @fs.read_file(directory + "/idle-starts").text().split("\n").count() >= 4
    })
    assert_false(@fs.exists(directory + "/stopped"))
    @fs.remove(directory + "/fail-idle-connect")
    idle_wait_for(async fn() { @fs.exists(directory + "/stopped") })
    let events = @fs.read_file(
      directory + "/.local/state/orca-env-devsy/events.jsonl",
    ).text()
    assert_true(events.contains("\"retryDelayMs\":20"))
    assert_true(events.contains("\"retryDelayMs\":40"))
    assert_true(@fs.exists(directory + "/idle-closed"))
    @fs.remove(saved + "/enabled")
    assert_eq(child.wait(), 0)
  })
}

///|
async test "unconfigured existing worker never starts an idle observer" {
  let (directory, env, state) = idle_fixture(1)
  defer cleanup_fixture(directory)
  let saved = required(state, "tunnelDirectory")
  if state is Json::Object(fields) {
    fields.remove("idleTimeoutMs")
  }
  @fs.write_file(saved + "/state.json", state.stringify())
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        saved,
      ],
      extra_env=env,
      no_wait=true,
    )
    idle_wait_for(async fn() {
      if !@fs.exists(saved + "/status.json") {
        return false
      }
      field(@json.parse(@fs.read_file(saved + "/status.json").text()), "status") ==
      Some(Json::string("connected"))
    })
    @async.sleep(150)
    assert_false(@fs.exists(directory + "/idle-starts"))
    assert_false(@fs.exists(directory + "/stopped"))
    assert_eq(field(idle_status(state), "enabled"), Some(Json::boolean(false)))
    @fs.remove(saved + "/enabled")
    assert_eq(child.wait(), 0)
  })
}

///|
async test "new configured VM saves policy and enables monitoring after creation" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: main, idleTimeout: 1h}\nenvironmentRecipes: [{id: test}]\n",
  )
  env.set("ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS", "5000")
  let (code, out, err) = invoke("create", env, directory)
  assert_eq(
    code,
    0,
    msg=err +
      @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl").text(),
  )
  let receipt = @json.parse(out)
  let state = field(receipt, "userData").unwrap()
  assert_eq(field(state, "idleTimeoutMs"), Some(Json::number(3600000)))
  let saved = required(state, "tunnelDirectory")
  assert_true(@fs.exists(saved + "/idle-enabled"))
  let saved_state = @json.parse(@fs.read_file(saved + "/state.json").text())
  assert_eq(
    field(saved_state, "idleProvider"),
    Some(Json::string("fixture-provider")),
  )
  let payload : Json = { "schemaVersion": 1, "recipeResult": receipt }
  let (code, _, err) = invoke("destroy", env, directory, payload~)
  assert_eq(code, 0, msg=err)
  assert_false(@fs.exists(saved))
}

///|
async test "failed automatic stop keeps monitoring and can recover on the next attempt" {
  let (directory, env, state) = idle_fixture(50)
  defer cleanup_fixture(directory)
  let saved = required(state, "tunnelDirectory")
  @fs.write_file(directory + "/fail-stop", "")
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        saved,
      ],
      extra_env=env,
      no_wait=true,
    )
    idle_wait_for(async fn() {
      if !@fs.exists(directory + "/.local/state/orca-env-devsy/events.jsonl") {
        return false
      }
      @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl")
      .text()
      .contains("workspace_stop_failed")
    })
    assert_false(@fs.exists(directory + "/stopped"))
    @fs.remove(directory + "/fail-stop")
    idle_wait_for(async fn() { @fs.exists(directory + "/stopped") })
    @fs.remove(saved + "/enabled")
    assert_eq(child.wait(), 0)
  })
}

///|
test "wall clock sleep duration remains part of idle elapsed time" {
  let timer : IdleTimer = { elapsed: 0, seen: false, previous: None, epoch: 0, }
  timer.advance("idle", 100000)
  timer.advance("idle", 21700000)
  assert_eq(timer.elapsed, 21600000)
}

///|
async test "one VM observer failure does not block another VM from stopping" {
  let (first, first_env, first_state) = idle_fixture(50)
  defer cleanup_fixture(first)
  let (second, second_env, second_state) = idle_fixture(50)
  defer cleanup_fixture(second)
  let first_saved = required(first_state, "tunnelDirectory")
  let second_saved = required(second_state, "tunnelDirectory")
  @fs.write_file(first + "/fail-idle-connect", "")
  @async.with_task_group(async fn(group) {
    let failed = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        first_env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        first_saved,
      ],
      extra_env=first_env,
      no_wait=true,
    )
    let healthy = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        second_env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        second_saved,
      ],
      extra_env=second_env,
      no_wait=true,
    )
    idle_wait_for(async fn() {
      @fs.exists(second + "/stopped") && @fs.exists(first + "/idle-starts")
    })
    assert_false(@fs.exists(first + "/stopped"))
    assert_eq(failed.try_wait(), None)
    @fs.remove(first_saved + "/enabled")
    @fs.remove(second_saved + "/enabled")
    assert_eq(failed.wait(), 0)
    assert_eq(healthy.wait(), 0)
  })
}

///|
async test "failed one-shot observations retain distinct native causes without authorizing idle stop" {
  let (directory, env, state) = idle_fixture(1)
  defer cleanup_fixture(directory)
  @fs.write_file(directory + "/activity-exit", "1")
  let saved = required(state, "tunnelDirectory")
  let write = async fn(code : String) {
    @fs.write_file(
      directory + "/activity.tmp",
      (
        {
          "schemaVersion": 1,
          "activity": "unknown",
          "errors": [{ "source": "observer", "code": code }],
        } : Json).stringify(),
    )
    @fs.rename(
      directory + "/activity.tmp",
      directory + "/activity",
      replace=true,
    )
  }
  write("missing_native_access")
  @async.with_task_group(async fn(group) {
    let child = @process.spawn(
      group,
      integration_binary(),
      [
        "--supervisor",
        env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        saved,
      ],
      extra_env=env,
      no_wait=true,
    )
    for code in ["missing_native_access", "native_restoration_unconfirmed"] {
      write(code)
      idle_wait_for(async fn() {
        let path = env.get("XDG_STATE_HOME").unwrap() +
          "/orca-env-devsy/events.jsonl"
        @fs.exists(path) && @fs.read_file(path).text().contains(code)
      })
      assert_false(@fs.exists(directory + "/stopped"))
    }
    @fs.remove(saved + "/enabled")
    assert_eq(child.wait(), 0)
  })
}
