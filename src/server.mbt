///|
async fn server_connection(
  state : Json,
  install : Bool,
  deadline? : UInt64,
) -> Json {
  if install {
    let script = server_install_script()
    ignore(remote(state, script, "orca-install"))
    prepare_orca_storage(state)
    initialize_orca_settings(state)
  }
  let output = recover_server(state, connection_result=true)
  ensure_ssh_worker(state, Some(reserve_server_port(state)), deadline?)
  output
}

///|
async fn recover_server(
  state : Json,
  connection_result~ : Bool = false,
) -> Json {
  let directory = required(state, "tunnelDirectory")
  let lock = @fs.open(
    directory + "/server.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  @async.with_timeout(30000, async fn() {
    while !lock.try_lock(Exclusive) {
      @async.sleep(100)
    }
  })
  guard @fs.exists(directory + "/enabled") && !@fs.exists(directory + "/paused") else {
    raise AdapterError("Connection recovery cancelled")
  }
  let output = if !connection_result && server_is_running(state) {
    save_diagnostic(
      "recover-server",
      "reuse",
      tunnel_directory=directory,
      recording=workspace_recording(state),
    )
    Json::null()
  } else {
    save_diagnostic(
      "recover-server",
      "start",
      tunnel_directory=directory,
      recording=workspace_recording(state),
    )
    if field(state, "orcaVolume") is Some(_) {
      prepare_orca_storage(state)
      let installation = remote(
          state, "if test -x \"$HOME/.local/share/orca-env-devsy/orca/current/orca-ide\"; then printf installed; else printf missing; fi",
          "orca-install-probe",
        )
        .trim()
        .to_owned()
      match installation {
        "installed" => ()
        "missing" =>
          ignore(remote(state, server_install_script(), "orca-install"))
        _ => raise AdapterError("Invalid Orca installation probe result")
      }
    }
    let output = launch_server(state)
    configure_orca_project(state)
    output
  }
  @fs.write_file(directory + "/server-enabled", "", permission=0o600)
  output
}

///|
async fn launch_server(state : Json) -> Json {
  let root = required(state, "projectRoot")
  let port = reserve_server_port(state)
  let configured_env = field(state, "serverEnv").unwrap_or(Json::empty_object())
  let diagnostic_env = Json::empty_object()
  if configured_env is Json::Object(values) {
    for name, value in values {
      if value is Json::String(text) {
        set_field(diagnostic_env, name, Json::string(redact_credentials(text)))
      }
    }
  }
  let recording = workspace_recording(state)
  let script = (if field(state, "orcaVolume") is Some(_) {
      "export ORCA_USER_DATA_PATH=/workspaces/.orca/.profile; "
    } else {
      ""
    }) +
    server_launch_script(root, port, configured_env, recording~)
  let (status, raw_output, detail) = command_result(
    workspace_program(state, "ssh"),
    mux_ssh_args(state) + [script],
    "orca-serve",
    environment=workspace_environment(state),
    cwd?=workspace_directory(state).map(path => path[:]),
  )
  let mut output = raw_output
  if recording {
    let mut observed = None
    let mut truncated = Json::array([])
    let mut observation_error = false
    if raw_output.split_once("\n") is Some((first, remaining)) {
      let event = @json.parse(first.to_owned()) catch { _ => Json::null() }
      if field(event, "kind") == Some(Json::string("result")) &&
        field(event, "serverEnvironment") is Some(value) {
        observed = Some(value)
        truncated = field(event, "truncated").unwrap_or(Json::array([]))
        observation_error = field(event, "observationError") ==
          Some(Json::boolean(true))
        output = remaining.to_owned()
      }
    }
    let complete = (
        configured_env == Json::empty_object() || observed is Some(_)
      ) &&
      truncated == Json::array([]) &&
      !observation_error
    save_diagnostic(
      "server-environment",
      if complete {
        "observed"
      } else {
        "partial"
      },
      evidence={
        "templates": diagnostic_env,
        "references": observed.unwrap_or(Json::null()),
        "completeness": if complete {
          "complete"
        } else {
          "partial"
        },
        "missingReason": if complete {
          Json::null()
        } else if observed is None || observation_error {
          "observation_failed"
        } else {
          "value_truncated"
        },
        "truncatedReferences": truncated,
      },
      recording~,
    )
  }
  guard status == 0 else {
    raise AdapterError(command_failure("orca-serve", status, detail))
  }
  let result = @json.parse(output)
  let connection = match field(result, "connection") {
    Some(value) => value
    None => result
  }
  guard required(connection, "pairingCode") != "" else {
    raise AdapterError("Orca returned no pairing code")
  }
  @fs.write_file(
    required(state, "tunnelDirectory") + "/pairing-code",
    required(connection, "pairingCode"),
    permission=0o600,
  )
  let output : Json = {
    "type": "orca-server",
    "pairingCode": required(connection, "pairingCode"),
    "projectRoot": root,
  }
  output
}

///|
fn server_launch_script(
  root : String,
  port : Int32,
  server_env : Json,
  recording~ : Bool = false,
) -> String raise {
  let names : Map[String, Bool] = Map([])
  guard server_env is Json::Object(values) else {
    raise AdapterError("Invalid saved server environment")
  }
  for target, value in values {
    guard valid_env_name(target) &&
      value is Json::String(text) &&
      !text.contains("\u0000") else {
      raise AdapterError("Invalid saved server environment")
    }
    ignore(
      interpolate(
        text,
        name => {
          names.set(
            name,
            names.get(name).unwrap_or(false) || credential_field(target),
          )
          Some("")
        },
        "server environment",
      ),
    )
  }
  if server_env == Json::empty_object() {
    return "ELECTRON_RUN_AS_NODE=1 exec \"$HOME/.local/share/orca-env-devsy/orca/current/orca-ide\" \"$HOME/.local/share/orca-env-devsy/orca/current/resources/app.asar/out/cli/index.js\" serve --recipe-json --project-root " +
      quote(root) +
      " --port 47121 --pairing-address " +
      quote("ws://127.0.0.1:\{port}") +
      " 2>/dev/null"
  }
  let fields : Array[Json] = []
  let inputs = StringBuilder()
  for name, secret in names {
    fields.push({ "name": name, "secret": secret || credential_field(name) })
    if name == "DEVSY_REMOTE_WORKSPACE_FOLDER" {
      inputs.write_string(" " + quote("x") + " " + quote(root))
    } else {
      inputs.write_string(" \"${" + name + "+x}\" \"${" + name + "-}\"")
    }
  }
  let code =
    #|const names = JSON.parse(process.argv[1]);
    #|const values = require("fs").readFileSync(0).toString().split("\0");
    #|const protect = /(?:authorization|proxy_authorization|cookie|set_cookie|password|passwd|token|access_token|accesstoken|refresh_token|refreshtoken|id_token|api_key|apikey|x_api_key|credential|credentials|secret|client_secret|clientsecret|private_key|privatekey|aws_secret_access_key|docker_auth_config|signature|sig|x_amz_signature|x_amz_security_token|x_goog_signature|auth)/i;
    #|function redact(s) {
    #|  s = s.replace(/-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)/gi, "[redacted]");
    #|  s = s.replace(/([a-z][a-z0-9+.-]*:\/\/)[^\s/@]+@/gi, "$1[redacted]@");
    #|  s = s.replace(/\b(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|sk-|age-secret-key-)[^\s,;\]}'"]+/gi, "[redacted]");
    #|  s = s.replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+/g, "[redacted]");
    #|  s = s.replace(/\b(Bearer|Basic)\s+[^,;\s"'\}\]]+/gi, "$1 [redacted]");
    #|  s = s.replace(/([?&]([^=&\s]+)=)([^&#\s]*)/g, (m, prefix, name) => { let decoded; try { decoded = decodeURIComponent(name); } catch { decoded = name; } return protect.test(decoded) || decoded.toLowerCase() === "key" ? prefix + "[redacted]" : m; });
    #|  s = s.replace(/((?:[\w-]*)(?:authorization|cookie|password|passwd|token|secret|api[_-]?key|private[_-]?key|credential|signature|auth)[\w-]*["']?\s*[:=]\s*)(?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|(?:Bearer|Basic)\s+[^,;\s]+|[^,;\s&}\]]+)/gi, "$1[redacted]");
    #|  return s;
    #|}
    #|const templates = JSON.parse(process.argv[2]);
    #|const recording = process.argv[3] === "1";
    #|const references = Object.create(null);
    #|for (let i = 0; i < names.length; i++) references[names[i].name] = values[i * 2] === "" ? undefined : values[i * 2 + 1];
    #|const result = Object.create(null);
    #|const truncated = [];
    #|let budget = 24000;
    #|if (recording) try {
    #|for (let i = 0; i < names.length; i++) {
    #|  const {name, secret} = names[i];
    #|  const value = references[name];
    #|  const state = value === undefined ? "unset" : value === "" ? "empty" : "set";
    #|  const item = {state};
    #|  if (state === "set") {
    #|    if (secret) { item.value = "[redacted]"; }
    #|    else if (value.length > budget) { item.truncated = true; truncated.push(name); }
    #|    else { item.value = redact(value); budget -= value.length; }
    #|  }
    #|  result[name] = item;
    #|}
    #|process.stdout.write(JSON.stringify({kind:"result",serverEnvironment:result,truncated}) + "\n");
    #|} catch (_) { try { process.stdout.write(JSON.stringify({kind:"result",serverEnvironment:{},truncated:names.map(x => x.name),observationError:true}) + "\n"); } catch (_) {} }
    #|const environment = Object.assign(Object.create(null), process.env, {ELECTRON_RUN_AS_NODE: "1"});
    #|let missing;
    #|for (const [name, template] of Object.entries(templates)) {
    #|  environment[name] = template.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(\?)?\}/g, (_, ref, required) => {
    #|    if (references[ref] === undefined && required) missing = ref;
    #|    return references[ref] === undefined ? "" : references[ref];
    #|  });
    #|}
    #|if (missing) { process.stderr.write("Required remote environment variable " + missing + " is not defined\n"); process.exit(1); }
    #|const cp = require("child_process");
    #|const cli = process.env.HOME + "/.local/share/orca-env-devsy/orca/current/resources/app.asar/out/cli/index.js";
    #|const child = cp.spawnSync(process.execPath, [cli, "serve", "--recipe-json", "--project-root", process.argv[4], "--port", "47121", "--pairing-address", process.argv[5]], {env: environment, stdio: ["ignore", "inherit", "ignore"]});
    #|if (child.error) process.exit(1);
    #|process.exit(child.status === null ? 1 : child.status);
  (if names.is_empty() {
    "printf '\\0'"
  } else {
    "printf '%s\\0'" + inputs.to_string()
  }) +
  " | ELECTRON_RUN_AS_NODE=1 \"$HOME/.local/share/orca-env-devsy/orca/current/orca-ide\" -e " +
  quote(code) +
  " " +
  quote(Json::array(fields).stringify()) +
  " " +
  quote(server_env.stringify()) +
  " " +
  quote(if recording { "1" } else { "0" }) +
  " " +
  quote(root) +
  " " +
  quote("ws://127.0.0.1:\{port}")
}

///|
fn server_install_script() -> String {
  let script =
    #|set -eu
    #|case "$(uname -s)-$(uname -m)" in
    #|  Linux-x86_64) asset=orca-linux.AppImage ;;
    #|  Linux-aarch64) asset=orca-linux-arm64.AppImage ;;
    #|  *) printf 'Unsupported remote Orca platform\n' >&2; exit 1 ;;
    #|esac
    #|base="$HOME/.local/share/orca-env-devsy/orca"
    #|umask 077
    #|mkdir -p "$base"
    #|if test -e "$base/current"; then
    #|  test -d "$base/current" && test ! -L "$base/current"
    #|  test -x "$base/current/orca-ide"
    #|  ELECTRON_RUN_AS_NODE=1 "$base/current/orca-ide" "$base/current/resources/app.asar/out/cli/index.js" --version >/dev/null
    #|  exit 0
    #|fi
    #|work=$(mktemp -d "$base/install.XXXXXX")
    #|trap 'rm -rf "$work"' EXIT
    #|curl -fLsS "https://github.com/stablyai/orca/releases/latest/download/$asset" -o "$work/orca.AppImage"
    #|chmod +x "$work/orca.AppImage"
    #|cd "$work"
    #|./orca.AppImage --appimage-extract >/dev/null
    #|test -x squashfs-root/orca-ide
    #|ELECTRON_RUN_AS_NODE=1 ./squashfs-root/orca-ide ./squashfs-root/resources/app.asar/out/cli/index.js --version >/dev/null
    #|test ! -e "$base/current"
    #|mv squashfs-root "$base/current"
  script
}

///|
async fn server_is_running(state : Json) -> Bool {
  let script = server_probe_script()
  let running = remote(state, script, "orca-server-probe").trim() == "101"
  save_diagnostic(
    "orca-server-probe",
    if running {
      "ready"
    } else {
      "not-running"
    },
    recording=workspace_recording(state),
  )
  running
}

///|
fn server_probe_script() -> String {
  let script =
    #|curl --disable --noproxy '*' --silent --head --request GET --max-time 2 --output /dev/null --write-out '%{http_code}' \
    #|  --header 'Connection: Upgrade' --header 'Upgrade: websocket' \
    #|  --header 'Sec-WebSocket-Version: 13' \
    #|  --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    #|  http://127.0.0.1:47121/ || true
  script
}

///|
async fn reserve_server_port(state : Json) -> Int32 {
  match field(state, "localPort") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => {
      let listener = @socket.TcpServer::TcpServer(
        @socket.Addr::parse("127.0.0.1:0"),
      )
      let port = listener.addr.port()
      listener.close()
      set_field(state, "localPort", Json::number(port.to_double()))
      port
    }
  }
}
