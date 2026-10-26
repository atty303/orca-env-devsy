///|
async fn supervisor_pid(directory : String) -> String {
  @fs.read_file(directory + "/supervisor.pid").text()
}

///|
async test "one supervisor isolates workspace environments, failures, recovery and restart" {
  let (first, env, first_state) = idle_fixture(3600000)
  defer cleanup_fixture(first)
  let (second, second_env, second_state) = idle_fixture(3600000)
  defer cleanup_fixture(second)
  let root = env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy"
  let first_saved = required(first_state, "tunnelDirectory")
  let old_second = required(second_state, "tunnelDirectory")
  let second_saved = root + "/tunnels/peer"
  @fs.remove(first_saved + "/idle-enabled")
  @fs.remove(old_second + "/idle-enabled")
  env.set("DOCKER_HOST", "fixture-first-host")
  second_env.set("DOCKER_HOST", "fixture-second-host")
  second_env.set("WORKSPACE_PRIVATE_TOKEN", "fixture-env-private-value")
  second_env.set("XDG_STATE_HOME", env.get("XDG_STATE_HOME").unwrap())
  @async.with_task_group(async fn(group) {
    let launches = []
    for _ in 0..<4 {
      launches.push(
        group.spawn(async fn() {
          @process.collect_output(
            integration_binary(),
            ["recover"],
            extra_env=env,
          )
        }),
      )
    }
    for launch in launches {
      assert_eq(launch.wait().0, 0)
    }
    let pid = supervisor_pid(root)
    @fs.rename(old_second, second_saved)
    set_field(second_state, "tunnelDirectory", Json::string(second_saved))
    set_field(second_state, "workspaceId", Json::string("peer-vm"))
    set_field(second_state, "workspaceUid", Json::string("peer-uid"))
    set_field(second_state, "context", Json::string("peer-context"))
    set_field(
      field(second_state, "devsyEnv").unwrap(),
      "XDG_STATE_HOME",
      Json::string(env.get("XDG_STATE_HOME").unwrap()),
    )
    @fs.write_file(second + "/workspace-id", "peer-vm")
    @fs.write_file(second + "/uid", "peer-uid")
    @fs.write_file(second_saved + "/state.json", second_state.stringify())
    @fs.rename(second + "/bin/ssh", second + "/bin/ssh-original")
    @fs.write_file(
      second + "/bin/ssh",
      "#!/bin/sh\ncase \"$*\" in *-N*) test \"$WORKSPACE_PRIVATE_TOKEN\" = fixture-env-private-value || exit 78; printf '%s' \"$DOCKER_HOST\" > \"$HOME/selected-ssh\" ;; esac\nexec \"$HOME/bin/ssh-original\" \"$@\"\n",
      permission=0o700,
    )
    let (code, _, errors) = invoke("recover", second_env, second)
    assert_eq(code, 0, msg=errors)
    assert_eq(supervisor_pid(root), pid)
    assert_eq(
      @fs.read_file(second + "/selected-ssh").text(),
      "fixture-second-host",
    )
    assert_false(
      @fs.read_file(second_saved + "/state.json")
      .text()
      .contains("fixture-env-private-value"),
    )
    assert_false(
      @fs.read_file(root + "/events.jsonl")
      .text()
      .contains("fixture-env-private-value"),
    )
    assert_true(@fs.read_file(second + "/args").text().contains("peer-context"))
    assert_false(@fs.read_file(first + "/args").text().contains("peer-context"))
    @fs.rename(second + "/bin/devsy", second + "/bin/devsy-original")
    @fs.write_file(
      second + "/bin/devsy",
      "#!/bin/sh\ncase \"$*\" in *'workspace status'*) if test -f \"$HOME/fail-status\"; then printf 'request rejected: %s\\n' \"$WORKSPACE_PRIVATE_TOKEN\" >&2; exit 78; fi ;; esac\nexec \"$HOME/bin/devsy-original\" \"$@\"\n",
      permission=0o700,
    )
    @fs.write_file(second + "/fail-status", "")
    let second_master = @fs.read_file(second + "/master-pid")
      .text()
      .trim()
      .to_owned()
    assert_eq(@process.collect_output("kill", ["-TERM", second_master]).0, 0)
    idle_wait_for(async fn() {
      @fs.read_file(root + "/events.jsonl")
      .text()
      .contains("workspace_query_failed")
    })
    let failures = @fs.read_file(root + "/events.jsonl").text()
    assert_true(failures.contains("request rejected: [redacted]"))
    assert_false(failures.contains("fixture-env-private-value"))
    assert_true(worker_alive(first_saved))
    assert_eq(supervisor_pid(root), pid)
    @fs.remove(second + "/fail-status")
    @fs.write_file(second_saved + "/probe-request", "")
    idle_wait_for(async fn() {
      @fs.exists(second_saved + "/status.json") &&
      field(
        @json.parse(@fs.read_file(second_saved + "/status.json").text()),
        "status",
      ) ==
      Some(Json::string("connected"))
    })
    let (_, processes, _) = @process.collect_output("ps", [
      "-ww", "-axo", "command=",
    ])
    let expected = root + "/ssh-proxy-adapter --supervisor " + root
    assert_eq(
      processes
      .text()
      .split("\n")
      .filter(line => {
        line.trim() == expected || line.trim().has_prefix(expected + " ")
      })
      .count(),
      1,
    )
    let old_master = @fs.read_file(first + "/master-pid").text()
    assert_eq(@process.collect_output("kill", ["-KILL", pid]).0, 0)
    idle_wait_for(async fn() { !supervisor_alive(root) })
    let (code, _, errors) = invoke("recover", env, first)
    assert_eq(code, 0, msg=errors)
    assert_false(supervisor_pid(root) == pid)
    assert_eq(@fs.read_file(first + "/master-pid").text(), old_master)
    env.set("WORKSPACE_PRIVATE_TOKEN", "fixture-env-private-value")
    let (code, _, errors) = invoke("restart", env, first)
    assert_eq(code, 0, msg=errors)
    assert_false(@fs.read_file(first + "/master-pid").text() == old_master)
    close_tunnel(first_state)
    assert_true(worker_alive(second_saved))
    second_env.set("ORCA_ENV_DEVSY_RECORDING", "0")
    let (code, _, errors) = invoke("restart", second_env, second)
    assert_eq(code, 0, msg=errors)
    let records = @fs.read_file(root + "/events.jsonl").text()
    let before = @fs.read_file(second + "/master-pid").text()
    assert_eq(
      @process.collect_output("kill", ["-TERM", before.trim().to_owned()]).0,
      0,
    )
    idle_wait_for(async fn() {
      @fs.read_file(second + "/master-pid").text() != before
    })
    assert_true(
      @fs.read_file(root + "/events.jsonl").text() == records,
      msg="recording-disabled task appended diagnostic events",
    )
    close_tunnel(second_state)
  })
}

///|
async test "state directories own independent supervisors" {
  let (first, env1, state1) = idle_fixture(3600000)
  defer cleanup_fixture(first)
  let (second, env2, state2) = idle_fixture(3600000)
  defer cleanup_fixture(second)
  @async.with_task_group(async fn(group) {
    let requests = [env1, env2].map(env => {
      group.spawn(async fn() {
        @process.collect_output(
          integration_binary(),
          ["recover"],
          extra_env=env,
        )
      })
    })
    for request in requests {
      assert_eq(request.wait().0, 0)
    }
    let pid1 = supervisor_pid(
      env1.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
    )
    let pid2 = supervisor_pid(
      env2.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
    )
    assert_false(pid1 == pid2)
    close_tunnel(state1)
    assert_true(worker_alive(required(state2, "tunnelDirectory")))
    close_tunnel(state2)
  })
}

///|
async test "supervisor crash preserves transport streams and recover resumes cleanup" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/transport",
    "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > \"$HOME/transport-pid\"\ncat\nwhile :; do :; done\n",
    permission=0o700,
  )
  @async.with_timeout(10000, async fn() {
    @async.with_task_group(async fn(group) {
      let (input, writer) = @process.write_to_process()
      defer writer.close()
      let (reader, output) = @process.read_from_process()
      defer reader.close()
      let proxy = @process.spawn(
        group,
        "/bin/sh",
        [
          "-c",
          "\"$1\" --ssh-proxy \"$HOME/primary-proxy.lock\" \"$2\" <&0 & wait $!",
          "sh",
          integration_binary(),
          directory + "/transport",
        ],
        extra_env=env,
        stdin=input,
        stdout=output,
      )
      writer.write(b"before")
      assert_eq(reader.read_exactly(6), b"before")
      let root = env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy"
      let pid = supervisor_pid(root)
      assert_eq(@process.collect_output("kill", ["-KILL", pid]).0, 0)
      idle_wait_for(async fn() { !supervisor_alive(root) })
      writer.write(b"after")
      assert_eq(reader.read_exactly(5), b"after")
      let (code, _, errors) = invoke("recover", env, directory)
      assert_eq(code, 0, msg=errors)
      assert_false(supervisor_pid(root) == pid)
      let transport = @fs.read_file(directory + "/transport-pid").text()
      assert_eq(
        @process.collect_output("kill", ["-TERM", proxy.pid.to_string()]).0,
        0,
      )
      assert_eq(proxy.wait(), -15)
      writer.close()
      assert_eq(reader.read_some(max_len=1), None)
      idle_wait_for(() => process_start(@string.parse_int(transport)) == 0)
    })
  })
}

///|
async test "transport cleanup terminates descendants after their launcher exits without inherited locks" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let (code, output, errors) = @async.with_timeout(5000, async fn() {
    @process.collect_output(
      integration_binary(),
      [
        "--ssh-proxy", "", "/bin/sh", "-c", "sleep 30 & printf '%s' \"$!\"; exit 37",
      ],
      extra_env=env,
      stdin=@process.redirect_from_file("/dev/null"),
    )
  })
  assert_eq(code, 37, msg=errors.text())
  let child = output.text()
  assert_true(@string.parse_int(child) > 1)
  idle_wait_for(() => process_start(@string.parse_int(child)) == 0)
  idle_wait_for(async fn() {
    @fs.read_file(directory + "/.local/state/orca-env-devsy/events.jsonl")
    .text()
    .contains("transport_exited")
  })
}

///|
async test "workspace registration deletion cannot stop a peer supervisor task" {
  let (directory, env, state) = idle_fixture(3600000)
  defer cleanup_fixture(directory)
  assert_eq(invoke("recover", env, directory).0, 0)
  let root = env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy"
  let pid = supervisor_pid(root)
  for index in 0..<100 {
    let pending = root + "/tunnels/pending-" + index.to_string()
    @fs.mkdir(pending)
    @fs.write_file(pending + "/state.json", "{}")
    @fs.write_file(pending + "/enabled", "")
    @fs.write_file(pending + "/request", "")
    @fs.rmdir(pending, recursive=true)
  }
  assert_eq(supervisor_pid(root), pid)
  assert_true(worker_alive(required(state, "tunnelDirectory")))
  close_tunnel(state)
}

///|
async test "direct exec preserves PID and transport ownership until group cleanup completes" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/transport",
    "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > \"$HOME/transport-pid\"\ncat\nwhile :; do :; done\n",
    permission=0o700,
  )
  @async.with_timeout(10000, async fn() {
    @async.with_task_group(async fn(group) {
      let (input, writer) = @process.write_to_process()
      defer writer.close()
      let (reader, output) = @process.read_from_process()
      defer reader.close()
      let proxy = @process.spawn(
        group,
        integration_binary(),
        [
          "--ssh-proxy",
          directory + "/primary-proxy.lock",
          directory + "/transport",
        ],
        extra_env=env,
        stdin=input,
        stdout=output,
      )
      writer.write(b"ready")
      assert_eq(reader.read_exactly(5), b"ready")
      let transport = @fs.read_file(directory + "/transport-pid").text()
      assert_eq(transport, proxy.pid.to_string())
      let pending = owned_transports(
        env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy",
        @fs.realpath(directory + "/primary-proxy.lock"),
      )
      assert_false(pending.is_empty())
      assert_eq(
        @process.collect_output("kill", ["-KILL", proxy.pid.to_string()]).0,
        0,
      )
      assert_eq(proxy.wait(), -9)
      wait_transport_cleanup(pending)
      assert_true(process_start(@string.parse_int(transport)) == 0)
      assert_eq(reader.read_some(max_len=1), None)
    })
  })
}

///|
test "workspace runtime options do not inherit another task's timeout or recording setting" {
  let first : Json = {
    "executionEnvironment": {
      "ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS": "50",
      "ORCA_ENV_DEVSY_RECORDING": "0",
    },
  }
  let second : Json = {
    "executionEnvironment": {
      "ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS": "5000",
      "ORCA_ENV_DEVSY_RECORDING": "1",
    },
  }
  assert_eq(connection_timeout_ms(state=first), 50)
  assert_eq(connection_timeout_ms(state=second), 5000)
  assert_false(workspace_recording(first))
  assert_true(workspace_recording(second))
}

///|
async test "short SSH operations wait for the owned master and never launch an independent transport" {
  let (directory, _, state) = idle_fixture(3600000)
  defer cleanup_fixture(directory)
  set_field(state, "executionEnvironment", {
    "ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS": "50",
    "ORCA_ENV_DEVSY_RECORDING": "0",
  })
  let failed = try {
    ignore(remote(state, "printf connected", "mux-test"))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_false(@fs.exists(directory + "/ssh-args"))
  @fs.rename(directory + "/bin/ssh", directory + "/bin/ssh-original")
  @fs.write_file(
    directory + "/bin/ssh",
    "#!/bin/sh\ntest \"$WORKSPACE_PRIVATE_TOKEN\" = fixture-secret || exit 78\nexec \"$HOME/bin/ssh-original\" \"$@\"\n",
    permission=0o700,
  )
  set_field(state, "executionEnvironment", {
    "ORCA_ENV_DEVSY_CONNECTION_TIMEOUT_MS": "2000",
    "ORCA_ENV_DEVSY_RECORDING": "0",
    "WORKSPACE_PRIVATE_TOKEN": "fixture-secret",
  })
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      @async.sleep(50)
      @fs.mkdir(required(state, "socketDirectory"))
      @fs.write_file(
        control_socket(state, required(state, "tunnelDirectory")),
        "",
      )
    })
    ignore(remote(state, "printf connected", "mux-test"))
  })
  let args = @fs.read_file(directory + "/ssh-args").text()
  assert_true(args.contains("ProxyCommand=false"))
  assert_true(args.contains("ControlMaster=no"))
  assert_true(
    args.contains(
      "-S\n" + control_socket(state, required(state, "tunnelDirectory")),
    ),
  )
  assert_false(args.contains("--ssh-proxy"))
}

///|
async test "detached SSH ownership retains transport until its final input writer closes" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  @fs.write_file(
    directory + "/transport",
    "#!/bin/sh\ntrap '' TERM\ncat\nwhile :; do :; done\n",
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
          "\"$1\" --ssh-proxy '' \"$2\" <&0 & while test ! -f \"$HOME/detach\"; do sleep 0.01; done",
          "sh",
          integration_binary(),
          directory + "/transport",
        ],
        extra_env=env,
        stdin=input,
        stdout=output,
      )
      writer.write(b"before")
      assert_eq(reader.read_exactly(6), b"before")
      @fs.write_file(directory + "/detach", "")
      assert_eq(owner.wait(), 0)
      @async.sleep(800)
      writer.write(b"after")
      assert_eq(reader.read_exactly(5), b"after")
      let root = env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy"
      let receipts = @fs.readdir(root + "/transports")
      assert_eq(receipts.length(), 1)
      writer.close()
      assert_eq(reader.read_some(max_len=1), None)
      wait_transport_cleanup([root + "/transports/" + receipts[0]])
    })
  })
}
