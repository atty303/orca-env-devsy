///|
async fn server_connection(
  state : Json,
  install : Bool,
  deadline? : UInt64,
) -> Json {
  if install {
    let script = server_install_script()
    ignore(remote(state, script, "orca-install"))
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
    save_diagnostic("recover-server", "reuse", tunnel_directory=directory)
    Json::null()
  } else {
    save_diagnostic("recover-server", "start", tunnel_directory=directory)
    launch_server(state)
  }
  @fs.write_file(directory + "/server-enabled", "", permission=0o600)
  output
}

///|
async fn launch_server(state : Json) -> Json {
  let root = required(state, "projectRoot")
  let port = reserve_server_port(state)
  let script = server_launch_script(root, port)
  let result = @json.parse(remote(state, script, "orca-serve"))
  let connection = match field(result, "connection") {
    Some(value) => value
    None => result
  }
  guard required(connection, "pairingCode") != "" else {
    raise AdapterError("Orca returned no pairing code")
  }
  let output : Json = {
    "type": "orca-server",
    "pairingCode": required(connection, "pairingCode"),
    "projectRoot": root,
  }
  output
}

///|
fn server_launch_script(root : String, port : Int32) -> String {
  // The Linux wrapper in 1.4.224 resolves the app root inside app.asar.unpacked.
  // Invoke the package-declared CLI entry so Orca prepares its bundled orcad.
  "ELECTRON_RUN_AS_NODE=1 exec \"$HOME/.local/share/orca-env-devsy/orca/current/orca-ide\" \"$HOME/.local/share/orca-env-devsy/orca/current/resources/app.asar/out/cli/index.js\" serve --recipe-json --project-root " +
  quote(root) +
  " --port 47121 --pairing-address " +
  quote("ws://127.0.0.1:\{port}") +
  // A detached server must not retain the SSH channel's stderr pipe.
  " 2>/dev/null"
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
