///|
async fn server_connection(state : Json, install : Bool) -> Json {
  let root = required(state, "projectRoot")
  if install {
    notify("orca-install")
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
    ignore(remote(state, script, "orca-install"))
  }
  let port = match field(state, "localPort") {
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
  notify("orca-serve")
  let script = server_launch_script(root, port)
  let result = @json.parse(remote(state, script, "orca-serve"))
  let connection = match field(result, "connection") {
    Some(value) => value
    None => result
  }
  guard required(connection, "pairingCode") != "" else {
    raise AdapterError("Orca returned no pairing code")
  }
  ensure_tunnel(state, port)
  let output : Json = {
    "type": "orca-server",
    "pairingCode": required(connection, "pairingCode"),
    "projectRoot": root,
  }
  output
}

///|
async fn ensure_tunnel(state : Json, port : Int32) -> Unit {
  let old_directory = match field(state, "tunnelDirectory") {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
  if old_directory is Some(directory) {
    let (status, _, _) = @process.collect_output(
      "ssh",
      ssh_args(state) + ["-S", directory + "/socket", "-O", "check"],
    )
    if status == 0 {
      return
    }
  }
  let directory = @fs.tmpdir(prefix="oe")
  set_field(state, "tunnelDirectory", Json::string(directory))
  let args = ssh_args(state) +
    [
      "-M",
      "-S",
      directory + "/socket",
      "-f",
      "-N",
      "-o",
      "ExitOnForwardFailure=yes",
      "-o",
      "ServerAliveInterval=30",
      "-o",
      "ServerAliveCountMax=3",
      "-L",
      "127.0.0.1:\{port}:127.0.0.1:47121",
    ]
  errdefer close_tunnel(state)
  ignore(command("ssh", args, "orca-tunnel"))
  @async.with_timeout(5000, async fn() {
    let socket = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}"))
    socket.close()
  })
}

///|
async fn close_tunnel(state : Json) -> Unit {
  if field(state, "tunnelDirectory") is Some(Json::String(directory)) {
    let (status, _, _) = @process.collect_output(
      "ssh",
      ssh_args(state) + ["-S", directory + "/socket", "-O", "exit"],
    )
    if status == 0 {
      @fs.rmdir(directory) catch {
        _ => ()
      }
    }
  }
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
