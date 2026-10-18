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
| `buildRef` | Remote ref supplying the complete build checkout; required for `orca-worktree`, optional for `provisioned-root` |
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

`orca-worktree` requires an explicit nonempty `buildRef` before provisioning.
`provisioned-root` can omit it: the supplied `ORCA_REPO_REF` and
`ORCA_REPO_REF_HEAD` then select the build source. An explicit `buildRef`
overrides the build source without changing Orca's task commit.

Build branches matching the remote's default branch use shallow clones.
Provisioned-root builds from Orca's supplied start branch also use shallow clones
when its tip matches the expected commit. Devsy resolves branch sources;
the adapter verifies the build checkout against its fetched remote-tracking ref.
A moved provisioned-root start ref or a missing shallow commit can retry with a
full clone of the required commit. Other build branches, tags and fixed commits
use full clones, keeping other remote branches available for Orca's later
worktree. Explicit native clone options in `upArgs` override the automatic choice.

The complete build checkout supplies Dockerfile, context and lifecycle commands.
For provisioned-root the adapter subsequently checks out Orca's task commit,
reusing it when present and fetching only a missing commit. For orca-worktree,
Orca creates the task worktree and controls its base. Neither operation rebuilds
the devcontainer. Orca's own remote refreshes are independent of clone strategy.

On FUSE filesystems (including virtiofs), creation sets the container user's default `core.createObject` to
`rename` when no global value is configured. This avoids transient missing-object
errors from hardlink-based object creation; an explicit Git setting is retained.

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
closed at suspend/destroy. `reconnect` restores every enabled tunnel in the current
adapter state directory, retaining each saved command, location environment, UID
and the Server forwarding port, where applicable. It emits no recipe JSON. `reconnect --receipt` accepts the saved
lifecycle payload and re-emits its connection offer after restoring that tunnel.
Neither path rereads YAML or installs/starts a Server. Workspace status is checked
before worker connections; stopped or busy workspaces are skipped by bulk recovery.
Devsy's SSH path can itself start a workspace, so a stop racing that status check
is not guaranteed to remain stopped.
A detached adapter worker owns the SSH master and reconnects after transient
transport failures with bounded exponential backoff. Server forwarding retains
the same local port. Transient adapter commands do not start credential services;
the persistent connection is established before checkout and addon commands.
It does not run workspace-up or register a boot service. Suspend/destroy
stop the workspace first; on failure the worker remains enabled. Successful
stop/delete disables and reaps the worker. Destroy also cleans up when the
workspace is already deleted, and may be repeated. Remote Server termination
follows Devsy's workspace/container lifecycle.

## Diagnostics and authentication

Both connection modes monitor Devsy's Git credential relay without requesting
credentials. Devsy owns relay recovery; loss of readiness does not disconnect
Orca or fail create/resume. `SSH_INJECT_GIT_CREDENTIALS=false` disables this
monitoring. The `git-relay` diagnostic status describes readiness, separately
from the `orca-tunnel` connection status; neither verifies credential retrieval.

Lifecycle stderr streams timestamped (UTC) stages and Devsy phase transitions,
with stage duration and total elapsed time on completion or failure. It also
shows VM, lifecycle-hook and installation messages, warnings/errors, and build
step names, completion and cache hits. Build command output and general
debug/trace logs are omitted; there is no periodic heartbeat. Credential-bearing
environment values and recognizable credential fields/URLs are redacted;
result/authentication responses, adapter command lines and arbitrary process exceptions
are not progress messages. Stdout remains the recipe result JSON.

Bounded local JSONL records contain stage, status, adapter version, run ID, timestamp,
process duration and exit code, fixed failure classifications, known Devsy phase
transitions, and tunnel retry attempt/delay in
`${XDG_STATE_HOME:-$HOME/.local/state}/orca-env-devsy/events.jsonl`, with private permissions.
Process records distinguish start, success, process API failure and nonzero exit.
Devsy phase records are written as transitions arrive. Unknown phases and
free-text messages are omitted from diagnostic records; detailed progress text
is not retained.
Create records share `runId` and carry `createAttempt` and `createPhase`.
`create-input` retains the workspace/recipe identity and the received
`ORCA_REPO_REF`, `ORCA_REPO_REF_HEAD`, and `ORCA_REPO_BRANCH` before defaults or
validation. Each value has an `unset`, `empty`, `valid`, or `invalid` state;
only values accepted by the bounded diagnostic allowlist have a `value`.
`create-configuration` distinguishes configured `buildRef` from `build-selection`;
`build-request` / `build-lookup` retain the chosen input and normalized lookup
before remote resolution.
`build-resolution` retains the preflight branch/commit, clone records retain the
selected source kind, allowlisted strategy, strategy source and fallback reason, and `build-checkout-head` /
`build-checkout` retain the acquired commit and comparison against the acquired
branch tip or pinned commit. These checks concern the build checkout. Orca's
later additional worktree is outside the adapter's observation boundary.
`create-attempt` ends in success, failure, or retry; a missing terminal event means
the attempt is incomplete. Existing file rotation can evict earlier events.
Invalid inputs and remote values are recorded without their raw content.

Command values are not recorded; inspect the saved `userData.command` locally
when checking the effective invocation. Recording failures do not affect workspace actions. `ORCA_ENV_DEVSY_RECORDING=0`
disables recording. The file is rotated at 256 KiB; remove it to delete records,
or copy it locally for diagnosis. Tunnel control state is stored privately in
`${XDG_STATE_HOME:-$HOME/.local/state}/orca-env-devsy/tunnels/`, with one private
directory per tunnel recorded as `userData.tunnelDirectory`. Existing state and
its enabled marker survive host restart; SSH control sockets use separate short
temporary paths. Successful suspend/destroy removes the owned state. Missing or
replaced workspace UIDs disable recovery; one failed target does not prevent
attempting the others. Existing temporary states become persistent on the next
resume or receipt-based reconnect; previously unregistered states cannot be
recovered in bulk after their temporary files have disappeared. There is no remote telemetry.

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
