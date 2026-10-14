#!/usr/bin/env bash
# Run against a supplied host binary; DEVSY_AGENT_URL may serve its Linux build.
set -euo pipefail
devsy=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
if [[ $(uname -s) = Linux ]]; then export RELAY_AGENT_BINARY="$devsy"; fi
adapter=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
root=$(mktemp -d "${RELAY_TMPDIR:-/tmp}/cr.XXXXXX")
sockets=$(mktemp -d /tmp/cs.XXXXXX)
credential_port=${RELAY_CREDENTIAL_PORT:-12049}
case "$credential_port" in ''|*[!0-9]*) exit 1 ;; esac
[[ "$credential_port" -ge 1 && "$credential_port" -le 65535 ]]
id="relay-$(basename "$root" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
owner= second=
sshbase=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
cleanup() {
  if [[ -n ${RELAY_ARTIFACT_DIR:-} ]]; then
    mkdir -p "$RELAY_ARTIFACT_DIR"
    docker exec "$id" sh -c 'cat /tmp/git-credentials-error.log 2>/dev/null || true' > "$root/guest.log" 2>/dev/null || true
    cp "$root/"*.log "$RELAY_ARTIFACT_DIR/" 2>/dev/null || true
    cp "${worker:-$root/worker}/git-status" "$RELAY_ARTIFACT_DIR/" 2>/dev/null || true
    cp "$root/home/state/orca-env-devsy/events.jsonl" "$RELAY_ARTIFACT_DIR/" 2>/dev/null || true
  fi
  rm -f "${worker:-$root/worker}/enabled"
  for socket in "$sockets/a.socket" "$sockets/orca/socket" "$sockets/orca/credential-socket"; do
    ssh "${sshbase[@]}" -S "$socket" -O exit root@devsy-workspace >/dev/null 2>&1 || true
  done
  for pid in "$owner" "$second"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
  "$devsy" --home "$root/devsy" workspace delete "$id" --force --ignore-not-found > /dev/null 2>&1 || true
  # This exact name belongs only to this invocation.
  docker rm -f "$id" >/dev/null 2>&1 || true
  rm -rf "$root" "$sockets"
}
trap cleanup EXIT
mkdir -p "$root/home" "$root/workspace/.devcontainer"
export HOME="$root/home" XDG_CONFIG_HOME="$root/home/config" XDG_STATE_HOME="$root/home/state"
export XDG_DATA_HOME="$root/home/data" XDG_CACHE_HOME="$root/home/cache" XDG_RUNTIME_DIR="$root/home/run" DEVSY_HOME="$root/devsy"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$root/home/gitconfig" GIT_TERMINAL_PROMPT=0
export RELAY_HELPER_CALLS="$root/helper-calls"
unset GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS DEVSY_GIT_HELPER_PORT SSH_AUTH_SOCK DEVSY_CONTEXT DEVSY_PROVIDER
cd "$root/home"
cat > "$root/helper" <<'HELPER'
#!/bin/sh
cat >/dev/null
if test "$1" = get; then printf 'get\n' >> "$RELAY_HELPER_CALLS"; printf 'username=relay-test\npassword=relay-test-dummy\n'; fi
HELPER
chmod 700 "$root/helper"
git config --global credential.helper "$root/helper"
git config --global user.name 'Relay Test'
git config --global user.email 'relay@example.invalid'
printf 'protocol=https\nhost=relay.example.invalid\n\n' | git credential fill | grep -qx 'password=relay-test-dummy'
echo 'PASS isolated host Git helper'
cat > "$root/workspace/.devcontainer/devcontainer.json" <<CONFIG
{"image":"mcr.microsoft.com/devcontainers/base:ubuntu","remoteUser":"root","containerEnv":{"DEVSY_CREDENTIALS_SERVER_PORT":"$credential_port"},"runArgs":["--name","$id"]}
CONFIG
run() { "$devsy" --home "$root/devsy" "$@"; }
guest() { docker exec "$id" sh -c "$1"; }
eventually() {
  for ((i=0; i<100; i++)); do if "$@"; then return; fi; sleep .2; done
  echo "Timed out at credential relay assertion: $1" >&2; return 1
}
ready() { guest "curl --noproxy '*' -fsS --max-time 2 http://localhost:$credential_port/ >/dev/null" 2>/dev/null; }
fill() {
  guest 'printf "protocol=https\nhost=relay.example.invalid\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null' |
    grep -qx 'password=relay-test-dummy'
}
run context set -o TELEMETRY=false >/dev/null
if [[ ${RELAY_DISABLE_GIT:-0} = 1 ]]; then run context set -o SSH_INJECT_GIT_CREDENTIALS=false >/dev/null; fi
run provider add docker >/dev/null
run provider use docker >/dev/null
run workspace up "$root/workspace" --id "$id" --uid "$id-uid" --ide-launch skip > "$root/up.log" 2>&1
if [[ -n ${RELAY_AGENT_BINARY:-} ]]; then
  if command -v sha256sum >/dev/null; then expected=$(sha256sum "$RELAY_AGENT_BINARY" | cut -d ' ' -f1); else expected=$(shasum -a 256 "$RELAY_AGENT_BINARY" | cut -d ' ' -f1); fi
  actual=$(guest 'sha256sum /usr/local/bin/devsy' | cut -d ' ' -f1)
  [[ "$actual" = "$expected" ]]
  echo 'PASS environment agent matches supplied build'
fi
proxy="'$devsy' --home '$root/devsy' --log-level debug workspace ssh '$id' --stdio --user root"
ssh "${sshbase[@]}" -o "ProxyCommand=$proxy" -M -S "$sockets/a.socket" -N root@devsy-workspace > "$root/a.log" 2>&1 & owner=$!
eventually ready
if [[ ${RELAY_DISABLE_GIT:-0} != 1 ]]; then
  eventually fill
  echo 'PASS A owns a working credential relay'
fi
worker="$XDG_STATE_HOME/orca-env-devsy/tunnels/$id"
mkdir -p "$worker" "$sockets/orca"
cat > "$worker/state.json" <<STATE
{"adapterVersion":1,"connection":"orca-server","projectRoot":"/workspaces/$id","workspaceId":"$id","workspaceUid":"$id-uid","user":"root","home":"$root/devsy","command":["$devsy"],"devsyEnv":{"HOME":"$HOME","XDG_CONFIG_HOME":"$XDG_CONFIG_HOME","XDG_STATE_HOME":"$XDG_STATE_HOME"},"socketDirectory":"$sockets/orca","tunnelDirectory":"$worker","localPort":18943}
STATE
touch "$worker/enabled"
"$adapter" --tunnel-worker "$worker" > "$root/b.log" 2>&1 & second=$!
eventually ssh "${sshbase[@]}" -o ProxyCommand=false -S "$sockets/orca/socket" root@devsy-workspace true
if [[ ${RELAY_DISABLE_GIT:-0} = 1 ]]; then
  eventually grep -qx disabled "$worker/git-status"
  [[ ! -S "$sockets/orca/credential-socket" ]]
  if fill; then echo 'Disabled forwarding unexpectedly returned credentials' >&2; exit 1; fi
  echo 'PASS disabled forwarding preserves Orca without management or credentials'
  exit
fi
eventually fill
# B has completed its services attempt before A ends, not a race on startup.
# The existing helper still belongs to A; wait for the worker's readiness
# observation, which must not itself start a new Devsy SSH connection.
eventually grep -qx ready "$worker/git-status"
before=$(ssh "${sshbase[@]}" -S "$sockets/orca/socket" -O check root@devsy-workspace 2>&1)
calls=$(wc -l < "$root/helper-calls")
sleep 3
[[ $(wc -l < "$root/helper-calls") = "$calls" ]]
echo 'PASS readiness monitoring does not invoke the host Git helper'
ssh "${sshbase[@]}" -S "$sockets/a.socket" -O exit root@devsy-workspace
wait "$owner" 2>/dev/null || true; owner=
kill -0 "$second"
eventually fill
kill -0 "$second"
after=$(ssh "${sshbase[@]}" -S "$sockets/orca/socket" -O check root@devsy-workspace 2>&1)
[[ "$before" = "$after" ]]
echo 'PASS credential recovery preserves the Orca SSH master PID'
[[ -S "$sockets/orca/credential-socket" ]]
echo 'PASS one managed authentication connection'
relay_pid() {
  guest "pgrep -o -f '[d]evsy internal agent container credentials-server --user root'"
}
relay_changed() {
  local current
  current=$(relay_pid) || return 1
  [[ "$current" != "$previous_relay" ]]
}
for round in 1 2; do
  previous_relay=$(relay_pid)
  case "$previous_relay" in ''|*[!0-9]*) exit 1 ;; esac
  guest "kill -TERM $previous_relay"
  eventually relay_changed
  eventually fill
  after=$(ssh "${sshbase[@]}" -S "$sockets/orca/socket" -O check root@devsy-workspace 2>&1)
  [[ "$before" = "$after" ]]
done
echo 'PASS repeated relay-owner termination recovers with the same Orca master'
ssh "${sshbase[@]}" -S "$sockets/orca/socket" -O exit root@devsy-workspace
master_changed() {
  local current
  current=$(ssh "${sshbase[@]}" -S "$sockets/orca/socket" -O check root@devsy-workspace 2>&1) || return 1
  [[ "$current" != "$before" ]]
}
eventually master_changed
eventually fill
echo 'PASS automatic Orca reconnect restores credential forwarding'
run workspace stop "$id" > "$root/stop.log" 2>&1
rm "$worker/enabled"
wait "$second"; second=
[[ ! -S "$sockets/orca/credential-socket" ]]
run workspace up "$id" --ide-launch skip >> "$root/up.log" 2>&1
touch "$worker/enabled"
"$adapter" --tunnel-worker "$worker" >> "$root/b.log" 2>&1 & second=$!
eventually fill
echo 'PASS suspend/resume restores credential forwarding and reaps management'
# Put A back in ownership before starting the worker's cold connection.
rm "$worker/enabled"
wait "$second"; second=
ssh "${sshbase[@]}" -o "ProxyCommand=$proxy" -M -S "$sockets/a.socket" -N root@devsy-workspace >> "$root/a.log" 2>&1 & owner=$!
eventually fill
touch "$worker/enabled"
"$adapter" --tunnel-worker "$worker" >> "$root/b.log" 2>&1 & second=$!
eventually ssh "${sshbase[@]}" -o ProxyCommand=false -S "$sockets/orca/socket" root@devsy-workspace true
eventually grep -qx ready "$worker/git-status"
ssh "${sshbase[@]}" -S "$sockets/a.socket" -O exit root@devsy-workspace
wait "$owner" 2>/dev/null || true; owner=
eventually fill
[[ -S "$sockets/orca/credential-socket" ]]
{ printf '{"schemaVersion":1,"recipeResult":{"userData":'; cat "$worker/state.json"; printf '}}'; } > "$root/receipt.json"
kill -KILL "$second"; wait "$second" 2>/dev/null || true; second=
"$adapter" reconnect >> "$root/b.log" 2>&1
[[ ! -S "$sockets/orca/credential-socket" ]]
eventually fill
"$adapter" destroy < "$root/receipt.json" >> "$root/b.log" 2>&1
[[ ! -d "$worker" ]]
echo 'PASS dead-worker recovery and destroy reap the old management connection'
