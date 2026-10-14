# Configuration and contracts

## Settings

All settings below can appear in `devsy`, `devsy.profiles.<name>`, or
`environmentRecipes[].devsy`, except `profile` and `profiles` as noted.

| Field | Meaning |
| --- | --- |
| `connection` | Required explicit `orca-server` or `ssh` |
| `command` | Nonempty string array: executable then fixed arguments; default `["devsy"]` |
| `home` | Devsy state directory; omitted uses Devsy's default |
| `context` | Existing Devsy context; omitted uses Devsy's default |
| `buildRef` | Remote ref supplying the complete build checkout; default `HEAD` |
| `upArgs` | Array of native Devsy workspace-up arguments |
| `addons.codexAuth` | Optional file-backed Codex ChatGPT authentication handoff; default false |
| `profile` | Select one common profile; recipe selection overrides common selection |
| `profiles` | Named settings mappings, owned by the common `devsy` section |

`command` is replaced as a whole in common → selected profile → recipe order.
Each element supports `${VAR}` and `${VAR?}` expansion. The executable must be
nonempty after expansion; fixed arguments may be empty. NUL is rejected. Elements
are passed without splitting or shell evaluation, and the executable is not
resolved to an absolute path.

For example, `command: ["devsy-launcher", "--environment", "development"]` uses a
user-provided launcher for every Devsy operation and SSH ProxyCommand, including
Server tunnels. The command must work from Orca's later process environment and
working directory; a recipe-local PATH or relative working directory is not
saved. Use an explicit executable path when needed.

The expanded array is saved in `userData.command` at creation. Resume, suspend,
destroy and reconnect use that array without rereading YAML or expanding it again.
Saved states from releases without this field use `["devsy"]`. Do not put
credentials in command arguments or environment references used by this field;
use Devsy's credential configuration instead.

The adapter owns workspace identity, result format, context, state directory,
and IDE launch policy. `upArgs` cannot override `--id`, `--home`, `--context`,
`--uid`, `--result-format`, `--ide-launch`, or introduce `--`. Other repeated options retain
Devsy's native handling. Provider options, secrets and context preparation remain
Devsy/user responsibilities. Creation arguments are not copied into `userData`.

The source YAML is `ORCA_REPO_PATH/orca.yaml`; `ORCA_RECIPE_ID` selects the
recipe. `ORCA_REPO_URL` is the remote source and `ORCA_VM_INSTANCE_ID` is the
Devsy workspace ID. URLs must not carry credentials; use Git's credential/SSH
configuration. No host HEAD is consulted to infer Orca's task starting commit.

## Connection and checkout

| Checkout mode | SSH | Orca Server |
| --- | --- | --- |
| `orca-worktree` | Schema 1; Orca creates a linked worktree | Schema 1; Orca creates a linked worktree |
| `provisioned-root` | Schema 2; checkout supplied `ORCA_REPO_REF_HEAD` and `ORCA_REPO_BRANCH` | Rejected |

Branch build refs use shallow clones. If Devsy reports that the pinned commit is
missing during cloning, the adapter retries with a full clone while retaining
the same commit and workspace UID. Other failures are not retried. `HEAD`, tags
and commit refs use full clones; an explicit native clone option in `upArgs`
overrides the automatic choice. Branch names are validated by Git before use.

Build source and task source are separate: Devsy builds from `buildRef` first.
For provisioned-root the adapter then checks out Orca's task commit; it does not
rebuild the devcontainer. Dockerfile, context and lifecycle hooks belong to the
build checkout. Changing worktrees does not trigger reconstruction.

Create/resume emit exactly one recipe JSON on stdout. Suspend/destroy emit no
result. Lifecycle input is Orca's schema-1 payload with `recipeResult.userData`.
Creation also saves the effective Devsy context and its filesystem location
environment; later operations keep those selectors while obtaining live provider
credentials from the current environment. The saved Devsy workspace UID is
checked before later actions, preventing accidental targeting of a replacement
workspace with the same ID.

Server environments validate and reuse an existing Orca installation. When none
exists, they install the latest stable official Linux Orca. The public
`serve --recipe-json --project-root` CLI starts the Server. Resume reuses the
installed version, reusing a running Server and starting it when absent. Updates
are explicit user operations, separate from
resume; this version does not expose an update command. Compatibility follows Orca's
protocol/capability negotiation.

Pairing data belongs to the connection result; it is never duplicated in
`userData`. Local SSH control sockets belong to the adapter's tunnels and are
closed at suspend/destroy. Reconnect reuses the saved connection offer and port.
A detached adapter worker owns the SSH master and reconnects after transient
transport failures using the same local port with bounded exponential backoff.
It does not start stopped workspaces or register a boot service. Suspend/destroy
stop the workspace first; on failure the worker remains enabled. Successful
stop/delete disables and reaps the worker. Destroy also cleans up when the
workspace is already deleted, and may be repeated. Remote Server termination
follows Devsy's workspace/container lifecycle.

## Diagnostics and authentication

Stderr reports fixed operation stages and safe failure categories. Raw Devsy,
SSH, Orca, authentication responses and arbitrary subprocess exceptions are not
printed. Bounded local JSONL records contain stage, status, adapter version, run ID, timestamp,
process duration and exit code, fixed failure classifications, known Devsy phase
transitions, and tunnel retry attempt/delay in
`$HOME/.local/state/orca-env-devsy/events.jsonl`, with private permissions.
Process records distinguish start, success, process API failure and nonzero exit.
Devsy phase records are observed after process output completes; they are not live
backend timing measurements. Unknown phases and free-text errors are omitted.
Command values are not recorded; inspect the saved `userData.command` locally
when checking the effective invocation. Recording failures do not affect workspace actions. `ORCA_ENV_DEVSY_RECORDING=0`
disables recording. The file is rotated at 256 KiB; remove it to delete records,
or copy it locally for diagnosis. Tunnel control state is stored privately in
the directory recorded as `userData.tunnelDirectory`; successful shutdown removes
its owned files. There is no remote telemetry.

The Codex addon reads `$CODEX_HOME/auth.json` (default `$HOME/.codex/auth.json`),
refreshes managed ChatGPT credentials when fewer than seven days remain using
`codex app-server` and `account/read` with `refreshToken: true`. A per-home advisory
lock serializes adapter refreshes; renewed access data must be persisted before
forwarding. Refresh failure warns, rereads the file and forwards only if it is
still valid. The addon sends only access/account data through SSH stdin to the
remote Codex home. It does not support API keys or keyring-only credentials. The remote file uses external-token mode, without
refresh credentials. A private digest marker protects authentication subsequently
modified by the user. Delivery is bounded to 45 seconds and cannot fail core
create/resume. Tokens and pairing data are excluded from saved adapter settings,
recording, command arguments and public artifacts.

## Upstream contracts

- [Orca recipe schemas](https://github.com/stablyai/orca/blob/v1.4.224/src/shared/ephemeral-vm-recipes.ts)
- [Orca lifecycle payload](https://github.com/stablyai/orca/blob/v1.4.224/src/shared/ephemeral-vm-recipe-lifecycle-payload.ts)
- [Orca public serve CLI](https://github.com/stablyai/orca/blob/v1.4.224/src/cli/specs/serve.ts)
- [Orca Linux launcher contract](https://github.com/stablyai/orca/blob/v1.4.224/config/scripts/run-linux-cli-launch-contract-docker.mjs)
- [Codex external authentication](https://learn.chatgpt.com/docs/app-server#3c-log-in-with-externally-managed-chatgpt-tokens-chatgptauthtokens)
