# Configuration and contracts

## Settings

All settings below can appear in `devsy`, `devsy.profiles.<name>`, or
`environmentRecipes[].devsy`, except `profile` and `profiles` as noted.

| Field | Meaning |
| --- | --- |
| `connection` | Required explicit `orca-server` or `ssh` |
| `home` | Devsy state directory; omitted uses Devsy's default |
| `context` | Existing Devsy context; omitted uses Devsy's default |
| `buildRef` | Remote ref supplying the complete build checkout; default `HEAD` |
| `upArgs` | Array of native Devsy workspace-up arguments |
| `addons.codexAuth` | Optional file-backed Codex ChatGPT authentication handoff; default false |
| `profile` | Select one common profile; recipe selection overrides common selection |
| `profiles` | Named settings mappings, owned by the common `devsy` section |

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

New Server environments install the latest stable official Linux Orca and start
the Server with its public `serve --recipe-json --project-root` CLI. Resume reuses
the installed version. Updates are explicit user operations, separate from
resume; this version does not expose an update command. Compatibility follows Orca's
protocol/capability negotiation.

Pairing data belongs to the connection result; it is never duplicated in
`userData`. Local SSH control sockets belong to the adapter's tunnels and are
closed at suspend/destroy. Reconnect reuses the saved connection offer and port.
Remote Server termination follows Devsy's workspace/container lifecycle.

## Diagnostics and authentication

Stderr reports fixed operation stages and safe failure categories. Raw Devsy,
SSH, Orca, authentication responses and arbitrary subprocess exceptions are not
printed. Bounded local JSONL records contain only stage, status, run ID and timestamp in
`$HOME/.local/state/orca-env-devsy/events.jsonl`, with private permissions.
Recording failures do not affect workspace actions. `ORCA_ENV_DEVSY_RECORDING=0`
disables recording. The file is rotated at 256 KiB; remove it to delete records,
or copy it locally for diagnosis. There is no remote telemetry.

The Codex addon reads `$CODEX_HOME/auth.json` (default `$HOME/.codex/auth.json`),
requires an unexpired ChatGPT JWT, and sends only access/account data through
SSH stdin to the remote Codex home. It does not support API keys, keyring-only
credentials, or token refresh. The remote file uses external-token mode, without
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
