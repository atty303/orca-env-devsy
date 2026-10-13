///|
async fn codex_addon(state : Json) -> Unit {
  if field(state, "codexAuth") != Some(Json::boolean(true)) {
    return
  }
  let mut stage = "read"
  try {
    @async.with_timeout(45000, async fn() {
      let home = @env.get_env_var("CODEX_HOME").unwrap_or(
        environment("HOME") + "/.codex",
      )
      guard @fs.file_size(home + "/auth.json") <= 65536L else {
        raise AdapterError("Invalid Codex auth size")
      }
      let source = @fs.read_file(home + "/auth.json")
      guard source.binary().length() <= 65536 else {
        raise AdapterError("Invalid Codex auth size")
      }
      stage = "parse"
      let auth = @json.parse(source.text())
      guard field(auth, "OPENAI_API_KEY") == None ||
        field(auth, "OPENAI_API_KEY") == Some(Json::null()) else {
        raise AdapterError("Unsupported Codex auth mode")
      }
      let tokens = match field(auth, "tokens") {
        Some(value) => value
        None => raise AdapterError("Missing Codex tokens")
      }
      let access = required(tokens, "access_token")
      let segments = access.split(".").to_array()
      guard segments.length() == 3 else {
        raise AdapterError("Invalid access token")
      }
      stage = "claims"
      let encoded = segments[1]
        .to_owned()
        .replace_all(old="-", new="+")
        .replace_all(old="_", new="/")
      let padding = (4 - encoded.length() % 4) % 4
      let claims = @json.parse(
        @utf8.decode(@base64.decode(encoded + "=".repeat(padding))),
      )
      guard field(claims, "exp") is Some(Json::Number(expiry, ..)) &&
        expiry > @env.now().to_double() / 1000 else {
        raise AdapterError("Expired access token")
      }
      let payload : Json = {
        "auth_mode": "chatgptAuthTokens",
        "tokens": {
          "id_token": access,
          "access_token": access,
          "refresh_token": "",
          "account_id": required(tokens, "account_id"),
        },
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
  } catch {
    _ => {
      @stdio.stderr.write(
        "orca-env-devsy: warning: Codex authentication addon failed at " +
        stage +
        "; continuing\n",
      )
      save_diagnostic("codex-auth", "warning")
    }
  }
}
