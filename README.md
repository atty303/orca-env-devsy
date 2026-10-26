# orca-env-devsy

Use a Devsy devcontainer as an Orca per-workspace environment. Orca owns the
worktree and agent; Devsy owns provisioning and providers. This adapter connects
their recipe and lifecycle contracts.

## Install

```sh
mise use github:atty303/orca-env-devsy
```

## Prerequisites

| Where | Required commands |
| --- | --- |
| Host | Devsy 1.23.2+ (`devsy`), Git (`git`), OpenSSH (`ssh`), a POSIX shell and `env` supporting `-u` |
| Devcontainer, both connections | Git, `stat` supporting `-f -c %T`, `sleep`, and a POSIX-compatible SSH command shell |
| Devcontainer, Server connection | Linux x86_64/arm64; `curl`, `uname`, `mkdir`, `mktemp`, `chmod`, `mv`, `rm`; [official Orca Linux runtime libraries](https://github.com/stablyai/orca/blob/v1.4.224/config/docker/cli-launch-contract/Dockerfile) |
| Host, Codex addon refresh | Codex (`codex`) with managed ChatGPT file authentication |
| Devcontainer, Codex addon enabled | `grep`, `cat`, `sha256sum`, `mkdir`, `mktemp`, `mv`, `rm` |

Host binaries support macOS 13+ on Apple Silicon and Linux with glibc 2.31+
on x86_64/arm64.

Prepare your Devsy provider and context before using the recipe. The adapter
installs Orca on the Server target; it does not install system packages or
register providers. SSH connections use the Devsy-generated SSH configuration
for host-key and agent-forwarding options.

## Configure

Add settings to the repository's original `orca.yaml`:

```yaml
devsy:
  connection: orca-server
  profile: cloud
  profiles:
    cloud:
      context: "${DEVSY_CONTEXT?}"
      upArgs: ["--provider", "example-provider"]
    local:
      upArgs: ["--provider", "docker"]

environmentRecipes:
  - id: cloud-server
    name: Cloud Server
    checkoutMode: orca-worktree
    devsy:
      buildRef: main
    create: orca-env-devsy create
    resume: orca-env-devsy resume
    suspend: orca-env-devsy suspend
    destroy: orca-env-devsy destroy
  - id: local-ssh
    name: Local SSH
    checkoutMode: provisioned-root
    devsy:
      profile: local
      connection: ssh
    create: orca-env-devsy create
    resume: orca-env-devsy resume
    suspend: orca-env-devsy suspend
    destroy: orca-env-devsy destroy
```

Settings apply in common → one selected profile → recipe order. `upArgs` append
in that order without splitting their elements. `${VAR}` expands to empty when
undefined; `${VAR?}` requires the variable to be defined, allowing an empty
value. There is no shell evaluation.

`buildRef` selects the entire build checkout, including lifecycle commands. It is
required for `orca-worktree`; choose the branch used as Orca's usual base, such
as `main`. For devcontainer development, select the build branch independently
of Orca's worktree base. `provisioned-root` may omit it to build directly from
Orca's supplied start ref and commit. The resulting `userData.buildRef` and
`userData.buildCommit` identify the build source. Lifecycle operations use saved
settings; editing YAML affects new workspaces only.

See `orca-env-devsy --help` for recovery commands.

Enable the optional Codex credential handoff with `devsy.addons.codexAuth: true`.
At create/resume it refreshes file-backed ChatGPT authentication through the host
Codex CLI when less than seven days remain, then transfers only access/account
data. Refresh failure warns and allows a still-valid token to be forwarded;
expired or unavailable authentication warns and continues without delivery.
Remote manually managed authentication is preserved. There is no ongoing
background authentication synchronization.

See [configuration and contracts](docs/contracts.md) for the supported fields,
connection constraints and local diagnostic controls.
