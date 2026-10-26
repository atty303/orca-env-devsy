///|
test "volume targets resolve workspace overrides before provider options" {
  let state : Json = {
    "devsyEnv": {
      "HOME": "/saved/home",
      "DEVSY_HOME": null,
      "XDG_RUNTIME_DIR": null,
    },
  }
  let current : Json = {
    "provider": {
      "name": "renamed-provider",
      "options": {
        "BIN": { "value": "/custom path/podman" },
        "HOST": { "value": "" },
      },
    },
  }
  let providers : Json = {
    "renamed-provider": {
      "state": {
        "options": {
          "BIN": { "value": "/wrong/docker" },
          "HOST": { "value": "unix:///wrong/socket" },
        },
      },
      "config": {
        "agent": {
          "local": "true",
          "docker": {
            "path": "${BIN}",
            "runtime": "podman",
            "env": { "DOCKER_HOST": "${HOST}" },
          },
        },
      },
    },
  }
  let plan = volume_cleanup_plan(state, current, providers)
  assert_eq(required(plan, "program"), "/custom path/podman")
  assert_eq(
    field(field(plan, "environment").unwrap(), "DOCKER_HOST"),
    @env.get_env_var("DOCKER_HOST").map(value => Json::string(value)),
  )
  assert_eq(
    field(field(plan, "environment").unwrap(), "HOME"),
    Some(Json::string("/saved/home")),
  )
  let machine : Json = {
    "machine": { "machineId": "dedicated", "autoDelete": true },
  }
  assert_eq(volume_cleanup_plan(state, machine, Json::empty_object()), {
    "mode": "machine",
    "machineId": "dedicated",
  })
}

///|
test "volume cleanup does not adopt unsupported targets or credential configuration" {
  let state : Json = { "devsyEnv": {} }
  let current : Json = { "provider": { "name": "custom" } }
  let agent : Json = { "local": true, "driver": "microsandbox" }
  let providers : Json = { "custom": { "config": { "agent": agent } } }
  for driver in ["microsandbox", "kubernetes"] {
    set_field(agent, "driver", Json::string(driver))
    try {
      ignore(volume_cleanup_plan(state, current, providers))
      fail("unsupported runtime was adopted")
    } catch {
      AdapterError(message) => assert_true(message.contains("unsupported"))
      _ => fail("unexpected error")
    }
  }
  set_field(agent, "driver", Json::string("docker"))
  for key in ["API_TOKEN", "DOCKER_AUTH_CONFIG"] {
    let environment = Json::empty_object()
    set_field(environment, key, Json::string("opaque-secret"))
    set_field(agent, "docker", { "env": environment })
    try {
      ignore(volume_cleanup_plan(state, current, providers))
      fail("credential environment was saved")
    } catch {
      AdapterError(message) => assert_false(message.contains("opaque-secret"))
      _ => fail("unexpected error")
    }
  }
}

///|
test "unresolved runtime templates are skipped rather than rewritten to another endpoint" {
  let options : Json = { "BIN": { "value": "/custom/docker" } }
  assert_eq(
    volume_configuration_value("${BIN}", options, Json::empty_object()),
    "/custom/docker",
  )
  for
    value in [
      "$BIN", "${UNKNOWN}", "unix://${WORKSPACE_FOLDER}/docker.sock", "${BIN:-docker}",
    ] {
    try {
      ignore(volume_configuration_value(value, options, Json::empty_object()))
      fail("unresolved runtime template was adopted")
    } catch {
      AdapterError(_) => ()
      _ => fail("unexpected error")
    }
  }
}
