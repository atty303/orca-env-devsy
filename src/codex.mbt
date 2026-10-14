///|
fn codex_timestamp(milliseconds : UInt64) -> String raise {
  let utc = @time.PlainDateTime::from_unix_second(
    (milliseconds / 1000).reinterpret_as_int64(),
    0,
    @time.utc_offset,
  )
  let fraction = (milliseconds % 1000).to_string()
  utc.to_string() + "." + "0".repeat(3 - fraction.length()) + fraction + "Z"
}

///|
async fn codex_addon(state : Json) -> Unit {
  if field(state, "codexAuth") != Some(Json::boolean(true)) {
    return
  }
  let started = @env.now()
  progress_message("codex-auth: running…")
  let mut stage = "read"
  try {
    @async.with_timeout(45000, async fn() {
      let home = @env.get_env_var("CODEX_HOME").unwrap_or(
        environment("HOME") + "/.codex",
      )
      guard @fs.file_size(home + "/auth.json") <= 65536L else {
        raise AdapterError("Invalid Codex auth size")
      }
      stage = "refresh"
      let auth = codex_credentials(home)
      let access = auth.access
      let payload : Json = {
        "auth_mode": "chatgptAuthTokens",
        "tokens": {
          "id_token": access,
          "access_token": access,
          "refresh_token": "",
          "account_id": auth.account,
        },
        "last_refresh": codex_timestamp(@env.now()),
      }
      let script =
        #|set -eu
        #|home="${CODEX_HOME:-$HOME/.codex}"
        #|test -z "${OPENAI_API_KEY:-}${CODEX_ACCESS_TOKEN:-}"
        #|if test -f "$home/config.toml"; then
        #|  ! grep -Eq '^[[:space:]]*cli_auth_credentials_store[[:space:]]*=[[:space:]]*"(auto|keyring)"' "$home/config.toml"
        #|fi
        #|umask 077
        #|mkdir -p "$home"
        #|test ! -L "$home/auth.json"
        #|if test -f "$home/auth.json"; then
        #|  test -f "$home/.orca-env-devsy-auth"
        #|  test "$(sha256sum < "$home/auth.json")" = "$(cat "$home/.orca-env-devsy-auth")"
        #|fi
        #|temporary=$(mktemp "$home/auth.XXXXXX")
        #|trap 'rm -f "$temporary"' EXIT
        #|cat > "$temporary"
        #|mv "$temporary" "$home/auth.json"
        #|sha256sum < "$home/auth.json" > "$home/.orca-env-devsy-auth"
      stage = "deliver"
      let sink = @process.redirect_to_file("/dev/null", shared=true)
      defer sink.close()
      stage = "pipe"
      let (input, writer) = @process.write_to_process()
      @async.with_task_group(async fn(group) {
        stage = "spawn"
        let process = @process.spawn(
          group,
          "ssh",
          ssh_args(state) + [script],
          stdin=input,
          stdout=sink,
          stderr=sink,
        )
        stage = "write"
        writer.write(payload.stringify() + "\n")
        writer.close()
        stage = "wait"
        guard process.wait() == 0 else {
          raise AdapterError("Codex auth delivery failed")
        }
      })
    })
    save_diagnostic("codex-auth", "success")
    progress_message("codex-auth: done (" + progress_timing(started) + ")")
  } catch {
    _ => {
      progress_message(
        "warning: Codex authentication addon failed at " +
        stage +
        "; continuing (" +
        progress_timing(started) +
        ")",
      )
      save_diagnostic("codex-auth", "warning")
    }
  }
}

///|
priv struct CodexAuth {
  access : String
  account : String
  expiry : Double
}

///|
async fn read_codex_auth(home : String) -> CodexAuth {
  guard @fs.file_size(home + "/auth.json") <= 65536L else {
    raise AdapterError("Invalid Codex auth size")
  }
  let source = @fs.read_file(home + "/auth.json")
  guard source.binary().length() <= 65536 else {
    raise AdapterError("Invalid Codex auth size")
  }
  let auth = @json.parse(source.text())
  guard (
      field(auth, "OPENAI_API_KEY") == None ||
      field(auth, "OPENAI_API_KEY") == Some(Json::null())
    ) &&
    (
      field(auth, "auth_mode") == None ||
      field(auth, "auth_mode") == Some(Json::string("chatgpt"))
    ) else {
    raise AdapterError("Unsupported Codex auth mode")
  }
  let tokens = field(auth, "tokens").unwrap()
  let access = required(tokens, "access_token")
  let segments = access.split(".").to_array()
  guard segments.length() == 3 else {
    raise AdapterError("Invalid access token")
  }
  let encoded = segments[1]
    .to_owned()
    .replace_all(old="-", new="+")
    .replace_all(old="_", new="/")
  let padding = (4 - encoded.length() % 4) % 4
  let claims = @json.parse(
    @utf8.decode(@base64.decode(encoded + "=".repeat(padding))),
  )
  guard field(claims, "exp") is Some(Json::Number(expiry, ..)) else {
    raise AdapterError("Invalid access token expiry")
  }
  { access, account: required(tokens, "account_id"), expiry, }
}

///|
async fn codex_rpc_response(
  reader : @process.ReadFromProcess,
  id : Int32,
) -> Unit {
  let bytes : Array[Byte] = []
  let mut total = 0
  while true {
    let byte = reader.read_exactly(1)[0]
    total += 1
    guard total <= 1048576 else {
      raise AdapterError("Codex refresh output limit")
    }
    if byte == b'\n' {
      let response = @json.parse(@utf8.decode(Bytes::from_array(bytes)))
      bytes.clear()
      if field(response, "id") == Some(Json::number(id.to_double())) {
        guard field(response, "error") == None &&
          field(response, "result") != None else {
          raise AdapterError("Codex refresh RPC failed")
        }
        return
      }
    } else {
      bytes.push(byte)
    }
  }
}

///|
async fn refresh_codex(home : String) -> Unit {
  let (reader, output) = @process.read_from_process()
  defer reader.close()
  let (input, writer) = @process.write_to_process()
  defer writer.close()
  let sink = @process.redirect_to_file("/dev/null", shared=true)
  defer sink.close()
  @async.with_task_group(async fn(group) {
    ignore(
      @process.spawn(
        group,
        "codex",
        ["app-server", "--stdio"],
        extra_env={ "CODEX_HOME": home },
        stdin=input,
        stdout=output,
        stderr=sink,
        no_wait=true,
      ),
    )
    let initialize : Json = {
      "id": 1,
      "method": "initialize",
      "params": {
        "clientInfo": { "name": "orca-env-devsy", "version": version },
      },
    }
    writer.write(initialize.stringify() + "\n")
    codex_rpc_response(reader, 1)
    writer.write("{\"method\":\"initialized\"}\n")
    writer.write(
      "{\"id\":2,\"method\":\"account/read\",\"params\":{\"refreshToken\":true}}\n",
    )
    codex_rpc_response(reader, 2)
  })
}

///|
async fn codex_credentials(home : String) -> CodexAuth {
  let initial = read_codex_auth(home)
  if initial.expiry - @env.now().to_double() / 1000 >= 604800 {
    return initial
  }
  let lock = @fs.open(
    home + "/.orca-env-devsy-refresh.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  while !lock.try_lock(Exclusive) {
    @async.sleep(100)
  }
  let before = read_codex_auth(home)
  if before.expiry - @env.now().to_double() / 1000 >= 604800 {
    return before
  }
  try {
    refresh_codex(home)
    let after = read_codex_auth(home)
    guard after.access != before.access && after.expiry > before.expiry else {
      raise AdapterError("Codex refresh not persisted")
    }
    save_diagnostic("codex-refresh", "success")
  } catch {
    _ => {
      @stdio.stderr.write(
        "orca-env-devsy: warning: Codex refresh failed; checking remaining token lifetime\n",
      )
      save_diagnostic("codex-refresh", "warning")
    }
  }
  let current = read_codex_auth(home)
  guard current.expiry > @env.now().to_double() / 1000 else {
    raise AdapterError("Expired access token")
  }
  if current.expiry - @env.now().to_double() / 1000 < 604800 {
    @stdio.stderr.write(
      "orca-env-devsy: warning: Codex token has less than seven days remaining\n",
    )
  }
  current
}
