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
  save_fixture_environment(first_saved, env)
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
    let original_master = @fs.read_file(first + "/master-pid").text()
    let socket_directory = required(first_state, "socketDirectory")
    @fs.rmdir(socket_directory, recursive=true)
    idle_wait_for(async fn() {
      @fs.exists(socket_directory + "/socket") &&
      @fs.read_file(first + "/master-pid").text() != original_master
    })
    @fs.rename(old_second, second_saved)
    save_fixture_environment(second_saved, second_env)
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
    assert_true(
      @fs.read_file(second_saved + "/environment.json")
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
    let recovered_pid = supervisor_pid(root)
    assert_eq(@fs.read_file(first + "/master-pid").text(), old_master)
    env.set("WORKSPACE_PRIVATE_TOKEN", "fixture-env-private-value")
    let (code, _, errors) = invoke("restart", env, first)
    assert_eq(code, 0, msg=errors)
    assert_false(supervisor_pid(root) == recovered_pid)
    assert_false(@fs.read_file(first + "/master-pid").text() == old_master)
    close_tunnel(first_state)
    assert_true(worker_alive(second_saved))
    second_env.set("ORCA_ENV_DEVSY_RECORDING", "0")
    let (code, _, errors) = invoke("restart", second_env, second)
    assert_eq(code, 0, msg=errors)
    let before = @fs.read_file(second + "/master-pid").text()
    assert_eq(
      @process.collect_output("kill", ["-TERM", before.trim().to_owned()]).0,
      0,
    )
    idle_wait_for(async fn() {
      @fs.read_file(second + "/master-pid").text() != before
    })
    let saved_environment = @json.parse(
      @fs.read_file(second_saved + "/environment.json").text(),
    )
    assert_false(
      field(saved_environment, "ORCA_ENV_DEVSY_RECORDING") ==
      Some(Json::string("0")),
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
      let (code, _, errors) = request.wait()
      assert_eq(code, 0, msg=errors.text())
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
          "exec 3<&0; \"$1\" --ssh-proxy \"$HOME/primary-proxy.lock\" \"$2\" <&3 3<&- & wait $!",
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
async test "bulk restart terminates active transport and replaces supervisor" {
  for condition in ["running", "crashed", "corrupt"] {
    let (directory, env) = fixture()
    defer cleanup_fixture(directory)
    let workspace = if condition == "corrupt" {
      @fs.write_file(
        directory + "/orca.yaml",
        "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
      )
      let (code, output, errors) = invoke("create", env, directory)
      assert_eq(code, 0, msg=errors)
      Some(field(@json.parse(output), "userData").unwrap())
    } else {
      None
    }
    @fs.write_file(
      directory + "/transport",
      "#!/bin/sh\ntrap '' TERM\ncat\n",
      permission=0o700,
    )
    @async.with_timeout(20000, async fn() {
      @async.with_task_group(async fn(group) {
        let (input, writer) = @process.write_to_process()
        defer writer.close()
        let (reader, output) = @process.read_from_process()
        defer reader.close()
        let proxy = @process.spawn(
          group,
          integration_binary(),
          ["--ssh-proxy", "", directory + "/transport"],
          extra_env=env,
          stdin=input,
          stdout=output,
          no_wait=true,
        )
        writer.write(b"before")
        assert_eq(reader.read_exactly(6), b"before")
        let root = env.get("XDG_STATE_HOME").unwrap() + "/orca-env-devsy"
        let previous = supervisor_pid(root)
        if condition == "crashed" {
          assert_eq(
            @process.collect_output("kill", [
              "-KILL",
              previous.trim().to_owned(),
            ]).0,
            0,
          )
          idle_wait_for(async fn() { !supervisor_alive(root) })
        }
        if condition == "corrupt" {
          let invalid = root + "/transports/invalid"
          @fs.mkdir(invalid)
          @fs.write_file(invalid + "/state.json", "{}")
        }
        let (code, _, errors) = invoke("restart", env, directory)
        if condition == "corrupt" {
          assert_true(code != 0)
          assert_true(errors.contains("SSH transport cleanup failed"))
        } else {
          let cleanup_diagnostics = fixture_events(directory)
            .filter(event => {
              field(event, "stage") ==
              Some(Json::string("supervisor-transport")) &&
              field(event, "status") == Some(Json::string("failed"))
            })
            .map(event => {
              "errorType=" +
              field(event, "errorType")
              .map(value => value.stringify())
              .unwrap_or("unknown") +
              " errorMessage=" +
              field(event, "errorMessage")
              .map(value => value.stringify())
              .unwrap_or("missing")
            })
            .join("\n")
          let group_members = if cleanup_diagnostics.contains(
              "Cannot inspect transport process group",
            ) {
            let (ps_status, ps_output, _) = @process.collect_output("ps", [
              "-Ao", "pid=,ppid=,pgid=,state=,uid=",
            ])
            if ps_status == 0 {
              let group_ids = @fs.readdir(root + "/transports")
                .filter(name => name.contains("."))
                .map(name => name.split(".").to_array()[0])
              let group_members = ps_output
                .text()
                .split("\n")
                .filter(line => {
                  let columns = line
                    .trim()
                    .split(" ")
                    .filter(value => value != "")
                    .to_array()
                  columns.length() >= 5 && group_ids.contains(columns[2])
                })
                .join("\n")
              "transport group IDs examined: " +
              group_ids.join(",") +
              (if group_members == "" {
                "\nno process rows matched the transport group IDs"
              } else {
                "\ntransport group members (pid ppid pgid state uid):\n" +
                group_members
              })
            } else {
              "ps failed with status " + ps_status.to_string()
            }
          } else {
            ""
          }
          assert_eq(
            code,
            0,
            msg=errors +
              (if cleanup_diagnostics == "" {
                "\nno supervisor-transport failure event was recorded"
              } else {
                "\n" + cleanup_diagnostics
              }) +
              (if group_members == "" { "" } else { "\n" + group_members }),
          )
        }
        assert_false(supervisor_pid(root) == previous)
        idle_wait_for(() => proxy.try_wait() is Some(_))
        assert_eq(reader.read_some(max_len=1), None)
        if condition == "corrupt" {
          @fs.rmdir(root + "/transports/invalid", recursive=true)
          let state = workspace.unwrap()
          let worker = required(state, "tunnelDirectory")
          assert_true(worker_alive(worker))
          assert_eq(
            field(
              @json.parse(@fs.read_file(worker + "/status.json").text()),
              "status",
            ),
            Some(Json::string("connected")),
          )
          close_tunnel(state)
        }
      })
    })
  }
}

///|
async test "supervisor reconnects when the socket runtime directory disappears" {
  let (directory, env) = fixture()
  defer cleanup_fixture(directory)
  let runtime = directory + "/runtime"
  @fs.mkdir(runtime, permission=0o700)
  env.set("XDG_RUNTIME_DIR", runtime)
  @fs.write_file(
    directory + "/orca.yaml",
    "devsy: {connection: ssh, buildRef: refs/heads/main}\nenvironmentRecipes: [{id: test}]\n",
  )
  let (code, output, errors) = invoke("create", env, directory)
  assert_eq(code, 0, msg=errors)
  let result = @json.parse(output)
  let state = field(result, "userData").unwrap()
  let worker = required(state, "tunnelDirectory")
  let payload : Json = { "schemaVersion": 1, "recipeResult": result }
  defer ignore(invoke("destroy", env, directory, payload~))
  let old = @json.parse(@fs.read_file(worker + "/state.json").text())
  assert_true(
    required(old, "socketDirectory").has_prefix(runtime + "/orca-env-devsy."),
  )
  let master = @fs.read_file(directory + "/master-pid").text()
  @fs.rmdir(runtime, recursive=true)
  idle_wait_for(async fn() {
    let current = @json.parse(@fs.read_file(worker + "/state.json").text())
    let replacement = required(current, "socketDirectory")
    replacement != required(old, "socketDirectory") &&
    @fs.exists(replacement + "/socket") &&
    @fs.read_file(directory + "/master-pid").text() != master
  })
}

///|
async test "bulk recovery reads workspace environment after the operation lock" {
  let (directory, env, state) = idle_fixture(3600000)
  defer cleanup_fixture(directory)
  let worker = required(state, "tunnelDirectory")
  @fs.remove(worker + "/idle-enabled")
  let lock = @fs.open(
    worker + "/operation.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  assert_true(lock.try_lock(Exclusive))
  @async.with_timeout(20000, async fn() {
    @async.with_task_group(async fn(group) {
      let (reader, stderr) = @process.read_from_process()
      defer reader.close()
      let child = @process.spawn(
        group,
        integration_binary(),
        ["recover"],
        extra_env=env,
        stderr~,
      )
      let output = @buffer.Buffer()
      while !@utf8.decode(output.to_bytes()).contains("recover running") {
        let chunk = reader.read_some(max_len=4096).unwrap()
        output.write_bytes(chunk)
      }
      env.set("DOCKER_HOST", "fixture-new-environment")
      save_fixture_environment(worker, env)
      lock.unlock()
      assert_eq(child.wait(), 0)
      let saved = @json.parse(
        @fs.read_file(worker + "/environment.json").text(),
      )
      assert_eq(
        field(saved, "DOCKER_HOST"),
        Some(Json::string("fixture-new-environment")),
      )
    })
  })
  close_tunnel(state)
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
          "exec 3<&0; \"$1\" --ssh-proxy '' \"$2\" <&3 3<&- & while test ! -f \"$HOME/detach\"; do sleep 0.01; done",
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
