///|
fn orca_storage_args(state : Json) -> Array[String] {
  match field(state, "orcaVolume") {
    Some(Json::String(volume)) =>
      ["--mount", "type=volume,source=" + volume + ",target=/worktrees"]
    _ => []
  }
}

///|
async fn prepare_orca_storage(state : Json) -> Unit {
  guard field(state, "orcaVolume") is Some(Json::String(volume)) else { return }
  save_diagnostic(
    "orca-storage",
    "started",
    source=Storage(volume, required(state, "projectRoot")),
    recording=workspace_recording(state),
  )
  let user = required(state, "user")
  let uid = required(state, "workspaceUid")
  let script = "set -eu; root=/worktrees; " +
    "grep -q ' /worktrees ' /proc/self/mountinfo || { echo 'Orca storage mount is missing' >&2; exit 1; }; " +
    "if test -f \"$root/.owner\"; then test \"$(cat \"$root/.owner\")\" = " +
    quote(uid) +
    "; else test -z \"$(find \"$root\" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)\" || { echo 'Orca storage has unowned contents' >&2; exit 1; }; printf '%s' " +
    quote(uid) +
    " > \"$root/.owner\"; fi; " +
    "chown \"$(id -u " +
    quote(user) +
    "):\"\"$(id -g " +
    quote(user) +
    ")\" \"$root\"; chmod 700 \"$root\""
  ignore(
    devsy(
      state,
      [
        "workspace",
        "ssh",
        required(state, "workspaceId"),
        "--start-services=false",
        "--agent-forwarding=false",
        "--user",
        "root",
        "--command",
        script,
      ],
      "orca-storage",
    ),
  )
  save_diagnostic(
    "orca-storage",
    "success",
    source=Storage(volume, required(state, "projectRoot")),
    recording=workspace_recording(state),
  )
}

///|
fn remote_orca_cli(state : Json) -> String {
  (if field(state, "orcaVolume") is Some(_) {
    "ORCA_USER_DATA_PATH=/worktrees/.orca "
  } else {
    ""
  }) +
  "ELECTRON_RUN_AS_NODE=1 \"$HOME/.local/share/orca-env-devsy/orca/current/orca-ide\" \"$HOME/.local/share/orca-env-devsy/orca/current/resources/app.asar/out/cli/index.js\" "
}

///|
async fn configure_orca_project(state : Json) -> Unit {
  guard field(state, "orcaVolume") is Some(Json::String(volume)) else { return }
  let cli = remote_orca_cli(state)
  let root = required(state, "projectRoot")
  ignore(
    remote(
      state,
      cli + "repo add --json --path " + quote(root),
      "orca-project-register",
    ),
  )
  let result = @json.parse(
    remote(
      state,
      cli + "project setups --host local --json",
      "orca-project-setups",
    ),
  )
  guard field(result, "ok") == Some(Json::boolean(true)) &&
    field(field(result, "result").unwrap(), "setups")
    is Some(Json::Array(setups)) else {
    raise AdapterError("Orca returned no project setups")
  }
  let matches = setups.filter(setup => {
    field(setup, "path") == Some(Json::string(root))
  })
  guard matches.length() == 1 else {
    raise AdapterError("Orca project setup is not unique")
  }
  let updated = @json.parse(
    remote(
      state,
      cli +
      "project setup-update --json --host local --setup " +
      quote(required(matches[0], "id")) +
      " --worktree-base-path /worktrees",
      "orca-project-configure",
    ),
  )
  guard field(updated, "ok") == Some(Json::boolean(true)) &&
    field(
      field(
        field(field(updated, "result").unwrap(), "result").unwrap(),
        "setup",
      ).unwrap(),
      "worktreeBasePath",
    ) ==
    Some(Json::string("/worktrees")) else {
    raise AdapterError("Orca did not retain the worktree base path")
  }
  save_diagnostic(
    "orca-project-configure",
    "success",
    source=Storage(volume, required(state, "projectRoot")),
    recording=workspace_recording(state),
  )
}
