///|
fn optional_text(value : Json, name : String) -> String {
  match field(value, name) {
    Some(Json::String(text)) => text
    _ => ""
  }
}

///|
let volume_environment_variables : Array[String] = [
  "PATH", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_TLS_VERIFY",
  "DOCKER_CERT_PATH", "CONTAINER_HOST", "CONTAINER_CONNECTION", "CONTAINERS_CONF",
  "CONTAINERS_STORAGE_CONF", "PODMAN_CONNECTIONS_CONF", "DBUS_SESSION_BUS_ADDRESS",
]

///|
fn volume_cleanup_plan(
  state : Json,
  current : Json,
  providers : Json,
) -> Json raise {
  let machine = field(current, "machine").unwrap_or(Json::empty_object())
  if field(machine, "autoDelete") == Some(Json::boolean(true)) &&
    optional_text(machine, "machineId") != "" {
    return { "mode": "machine", "machineId": required(machine, "machineId") }
  }
  guard optional_text(machine, "machineId") == "" else {
    raise AdapterError("shared machine volume cleanup is unsupported")
  }
  let provider = field(current, "provider").unwrap_or(Json::empty_object())
  let name = required(provider, "name")
  let entry = field(providers, name).unwrap_or(Json::empty_object())
  let config = field(entry, "config").unwrap_or(Json::empty_object())
  let agent = field(config, "agent").unwrap_or(Json::empty_object())
  let configured = field(
    field(entry, "state").unwrap_or(Json::empty_object()),
    "options",
  ).unwrap_or(Json::empty_object())
  let overrides = field(provider, "options").unwrap_or(Json::empty_object())
  let resolve = fn(value : String) raise {
    volume_configuration_value(value, configured, overrides)
  }
  guard field(agent, "local") == Some(Json::boolean(true)) ||
    resolve(optional_text(agent, "local")) == "true" else {
    raise AdapterError("nonlocal provider volume cleanup is unsupported")
  }
  let driver = resolve(optional_text(agent, "driver"))
  let runtime = if driver == "apple" {
    "apple"
  } else {
    guard driver == "" || driver == "docker" else {
      raise AdapterError("unsupported runtime driver: " + driver)
    }
    let docker = field(agent, "docker").unwrap_or(Json::empty_object())
    let kind = optional_text(docker, "runtime")
    guard kind == "" || kind == "docker" || kind == "podman" else {
      raise AdapterError("unsupported container runtime: " + kind)
    }
    if kind == "podman" {
      "podman"
    } else {
      "docker"
    }
  }
  let settings = field(
    agent,
    if runtime == "apple" {
      "apple"
    } else {
      "docker"
    },
  ).unwrap_or(Json::empty_object())
  let path = resolve(optional_text(settings, "path"))
  let program = if path == "" {
    if runtime == "apple" {
      "container"
    } else {
      "docker"
    }
  } else {
    path
  }
  guard redact_credentials(program) == program else {
    raise AdapterError("runtime executable contains credentials")
  }
  let elevation = resolve(optional_text(settings, "elevation"))
  guard ["", "none", "sudo", "doas", "pkexec"].contains(elevation) else {
    raise AdapterError("unsupported privilege elevation")
  }
  let environment = Json::empty_object()
  for variable in location_variables {
    if field(field(state, "devsyEnv").unwrap(), variable)
      is Some(Json::String(value)) {
      set_field(environment, variable, Json::string(value))
    }
  }
  for variable in volume_environment_variables {
    if @env.get_env_var(variable) is Some(value) {
      set_field(environment, variable, Json::string(value))
    }
  }
  let forwarded = Json::empty_object()
  if field(settings, "env") is Some(Json::Object(values)) {
    for key, value in values {
      guard !credential_field(key) &&
        key != "DOCKER_AUTH_CONFIG" &&
        value is Json::String(text) else {
        raise AdapterError("Invalid runtime environment")
      }
      let resolved = resolve(text)
      if resolved != "" {
        set_field(environment, key, Json::string(resolved))
        set_field(forwarded, key, Json::string(resolved))
      }
    }
  }
  if environment is Json::Object(values) {
    for _, value in values {
      guard value is Json::String(text) && redact_credentials(text) == text else {
        raise AdapterError(
          "runtime configuration contains credentials; skipping volume cleanup",
        )
      }
    }
  }
  {
    "mode": "local",
    "provider": name,
    "runtime": runtime,
    "program": program,
    "environment": environment,
    "elevation": elevation,
    "forwardedEnvironment": forwarded,
  }
}

///|
fn volume_configuration_value(
  value : String,
  configured : Json,
  overrides : Json,
) -> String raise {
  let output = StringBuilder()
  let mut remaining = value
  while remaining.split_once("${") is Some((prefix, expression)) {
    guard !prefix.contains("$") &&
      expression.split_once("}") is Some((variable, suffix)) &&
      variable.length() > 0 &&
      variable
      .iter()
      .all(c => (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') else {
      raise AdapterError("unsupported Devsy runtime variable expression")
    }
    let key = variable.to_owned()
    let option = match field(overrides, key) {
      Some(value) => value
      None =>
        match field(configured, key) {
          Some(value) => value
          None =>
            raise AdapterError("unresolved Devsy runtime variable: " + key)
        }
    }
    output.write_string(prefix.to_owned())
    output.write_string(optional_text(option, "value"))
    remaining = suffix.to_owned()
  }
  guard !remaining.contains("$") else {
    raise AdapterError("unsupported Devsy runtime variable expression")
  }
  output.write_string(remaining)
  output.to_string()
}

///|
async fn remember_volume_cleanup(state : Json, current : Json) -> Unit {
  guard field(state, "orcaVolume") is Some(_) else { return }
  let plan = @async.with_timeout(10000, async fn() {
    let machine = field(current, "machine").unwrap_or(Json::empty_object())
    let providers = if field(machine, "autoDelete") == Some(Json::boolean(true)) {
      Json::empty_object()
    } else {
      @json.parse(
        devsy(
          state,
          ["--result-format", "json", "provider", "list"],
          "orca-volume-provider",
        ),
      )
    }
    volume_cleanup_plan(state, current, providers)
  }) catch {
    error => {
      let reason = match error {
        AdapterError(message) | InvalidConfig(message) => message
        _ => error.to_string()
      }
      { "mode": "unsupported", "reason": redact_credentials(reason) }
    }
  }
  set_field(state, "orcaVolumeCleanup", plan)
  save_diagnostic(
    "orca-volume-target",
    "selected",
    source=VolumeCleanup(required(state, "orcaVolume"), plan),
  )
}

///|
async fn cleanup_orca_volume(state : Json) -> Unit {
  guard field(state, "orcaVolume") is Some(Json::String(volume)) else { return }
  let plan = field(state, "orcaVolumeCleanup").unwrap_or({
    "mode": "unsupported",
    "reason": "no saved runtime target",
  })
  try {
    guard volume == "orca-env-devsy-" + required(state, "workspaceUid") &&
      !volume.contains("/") &&
      !volume.contains("\n") else {
      raise AdapterError("volume does not match the saved workspace UID")
    }
    match optional_text(plan, "mode") {
      "machine" =>
        save_diagnostic(
          "orca-volume-cleanup",
          "machine-deleted",
          source=VolumeCleanup(volume, plan),
        )
      "local" =>
        @async.with_timeout(15000, async fn() {
          let environment = @env.get_env_vars()
          for variable in location_variables + volume_environment_variables {
            environment.remove(variable)
          }
          guard field(plan, "environment") is Some(Json::Object(values)) else {
            raise AdapterError("Missing saved runtime environment")
          }
          for key, value in values {
            guard value is Json::String(text) else {
              raise AdapterError("Invalid saved runtime environment")
            }
            environment.set(key, text)
          }
          let invocation = volume_invocation(plan)
          let program = invocation[0]
          let prefix = invocation[1:].to_owned()
          let (status, output, detail) = command_result(
            program,
            prefix + ["volume", "ls", "--format", "json"],
            "orca-volume-list",
            environment~,
          )
          guard status == 0 else {
            raise AdapterError(
              command_failure("orca-volume-list", status, detail),
            )
          }
          let items = if output.trim().has_prefix("[") {
            guard @json.parse(output) is Json::Array(items) else {
              raise AdapterError("Invalid runtime volume list")
            }
            items
          } else {
            let items = []
            for line in output.split("\n") {
              if line.trim() != "" {
                items.push(@json.parse(line.to_owned()))
              }
            }
            items
          }
          let mut exists = false
          for item in items {
            let name = if optional_text(plan, "runtime") == "apple" {
              required(
                field(item, "configuration").unwrap_or(Json::empty_object()),
                "name",
              )
            } else {
              required(item, "Name")
            }
            if name == volume {
              exists = true
            }
          }
          if exists {
            let (status, _, detail) = command_result(
              program,
              prefix + ["volume", "rm", volume],
              "orca-volume-remove",
              environment~,
            )
            guard status == 0 else {
              raise AdapterError(
                command_failure("orca-volume-remove", status, detail),
              )
            }
          }
          save_diagnostic(
            "orca-volume-cleanup",
            if exists {
              "removed"
            } else {
              "absent"
            },
            source=VolumeCleanup(volume, plan),
          )
        })
      _ => raise AdapterError(optional_text(plan, "reason"))
    }
  } catch {
    error => {
      let reason = redact_credentials(
        match error {
          AdapterError(message) | InvalidConfig(message) => message
          _ => error.to_string()
        },
      )
      save_diagnostic(
        "orca-volume-cleanup",
        "warning",
        source=VolumeCleanup(volume, plan),
        error_type="volume_cleanup",
        error_message=reason,
      )
      progress_message(
        "warning: Orca volume " + volume + " was not removed: " + reason,
      )
    }
  }
}

///|
fn volume_invocation(plan : Json) -> Array[String] raise {
  let program = required(plan, "program")
  let elevation = optional_text(plan, "elevation")
  if elevation == "" || elevation == "none" {
    return [program]
  }
  guard ["sudo", "doas", "pkexec"].contains(elevation) else {
    raise AdapterError("Invalid saved privilege elevation")
  }
  let command = [elevation, "env"]
  if field(plan, "forwardedEnvironment") is Some(Json::Object(values)) {
    for key, value in values {
      guard value is Json::String(text) else {
        raise AdapterError("Invalid runtime environment")
      }
      command.push(key + "=" + text)
    }
  }
  command.push(program)
  command
}
